import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/constants/app_constants.dart';
import '../../../core/utils/logger.dart';
import '../domain/models/channel_model.dart';

final channelRepositoryProvider = Provider<ChannelRepository>((ref) {
  return ChannelRepository(firestore: FirebaseFirestore.instance);
});

class ChannelRepository {
  final FirebaseFirestore _firestore;

  ChannelRepository({required FirebaseFirestore firestore})
      : _firestore = firestore;

  CollectionReference<Map<String, dynamic>> get _channelsRef =>
      _firestore.collection(AppConstants.channelsCollection);

  Future<ChannelModel> createChannel({
    required String name,
    String? description,
    required String ownerId,
    bool isPrivate = false,
    String? imageUrl,
  }) async {
    try {
      final docRef = _channelsRef.doc();
      final channel = ChannelModel(
        id: docRef.id,
        name: name,
        description: description,
        ownerId: ownerId,
        isPrivate: isPrivate,
        imageUrl: imageUrl,
        memberCount: 1,
        memberIds: [ownerId],
        createdAt: DateTime.now(),
      );

      await docRef.set(channel.toFirestore());

      // Add owner as first member
      await _addMember(
        channelId: docRef.id,
        userId: ownerId,
        role: MemberRole.owner,
      );

      return channel;
    } catch (e) {
      Logger.e('Create channel error', error: e);
      rethrow;
    }
  }

  Future<void> updateChannel(ChannelModel channel) async {
    await _channelsRef.doc(channel.id).update(channel.toFirestore());
  }

  Future<void> deleteChannel(String channelId) async {
    // Delete all members first
    final membersSnapshot = await _channelsRef
        .doc(channelId)
        .collection('members')
        .get();

    final batch = _firestore.batch();
    for (final doc in membersSnapshot.docs) {
      batch.delete(doc.reference);
    }

    // Delete the channel
    batch.delete(_channelsRef.doc(channelId));

    await batch.commit();
  }

  Future<ChannelModel?> getChannelById(String channelId) async {
    final doc = await _channelsRef.doc(channelId).get();
    if (!doc.exists) return null;
    return ChannelModel.fromFirestore(doc);
  }

  /// Get user channels as a stream (use sparingly - causes continuous reads)
  Stream<List<ChannelModel>> getUserChannels(String userId) {
    return _channelsRef
        .where('memberIds', arrayContains: userId)
        .orderBy('updatedAt', descending: true)
        .limit(50) // Limit to reduce reads
        .snapshots()
        .map((snapshot) => snapshot.docs
            .map((doc) => ChannelModel.fromFirestore(doc))
            .toList());
  }

  /// Get user channels ONE TIME (preferred - saves reads)
  /// Call ref.invalidate(userChannelsProvider) to refresh
  Future<List<ChannelModel>> getUserChannelsOnce(String userId) async {
    final snapshot = await _channelsRef
        .where('memberIds', arrayContains: userId)
        .orderBy('updatedAt', descending: true)
        .limit(50)
        .get();
    return snapshot.docs
        .map((doc) => ChannelModel.fromFirestore(doc))
        .toList();
  }

  Stream<ChannelModel?> channelStream(String channelId) {
    return _channelsRef.doc(channelId).snapshots().map((doc) {
      if (!doc.exists) return null;
      return ChannelModel.fromFirestore(doc);
    });
  }

  Future<void> joinChannel(String channelId, String userId) async {
    await _firestore.runTransaction((transaction) async {
      final channelRef = _channelsRef.doc(channelId);
      final channelDoc = await transaction.get(channelRef);

      if (!channelDoc.exists) throw Exception('Channel not found');

      final memberIds =
          List<String>.from(channelDoc.data()?['memberIds'] ?? []);
      if (memberIds.contains(userId)) return; // Already a member

      memberIds.add(userId);
      transaction.update(channelRef, {
        'memberIds': memberIds,
        'memberCount': FieldValue.increment(1),
        'updatedAt': FieldValue.serverTimestamp(),
      });
    });

    await _addMember(
      channelId: channelId,
      userId: userId,
      role: MemberRole.member,
    );
  }

  Future<void> leaveChannel(String channelId, String userId) async {
    await _firestore.runTransaction((transaction) async {
      final channelRef = _channelsRef.doc(channelId);
      final channelDoc = await transaction.get(channelRef);

      if (!channelDoc.exists) throw Exception('Channel not found');

      final memberIds =
          List<String>.from(channelDoc.data()?['memberIds'] ?? []);
      if (!memberIds.contains(userId)) return; // Not a member

      memberIds.remove(userId);
      transaction.update(channelRef, {
        'memberIds': memberIds,
        'memberCount': FieldValue.increment(-1),
        'updatedAt': FieldValue.serverTimestamp(),
      });
    });

    await _removeMember(channelId, userId);
  }

  Future<void> _addMember({
    required String channelId,
    required String userId,
    required MemberRole role,
  }) async {
    final member = ChannelMember(
      id: userId,
      userId: userId,
      channelId: channelId,
      role: role,
      joinedAt: DateTime.now(),
    );

    await _channelsRef
        .doc(channelId)
        .collection('members')
        .doc(userId)
        .set(member.toFirestore());
  }

  Future<void> _removeMember(String channelId, String userId) async {
    await _channelsRef
        .doc(channelId)
        .collection('members')
        .doc(userId)
        .delete();
  }

  /// Get channel members with limit (reduces reads for large channels)
  Stream<List<ChannelMember>> getChannelMembers(String channelId) {
    return _channelsRef
        .doc(channelId)
        .collection('members')
        .orderBy('joinedAt', descending: true)
        .limit(100) // Limit to 100 members to reduce reads
        .snapshots()
        .map((snapshot) => snapshot.docs
            .map((doc) => ChannelMember.fromFirestore(doc))
            .toList());
  }

  /// Get channel members ONE TIME (preferred for member lists)
  Future<List<ChannelMember>> getChannelMembersOnce(String channelId) async {
    final snapshot = await _channelsRef
        .doc(channelId)
        .collection('members')
        .orderBy('joinedAt', descending: true)
        .limit(100)
        .get();
    return snapshot.docs
        .map((doc) => ChannelMember.fromFirestore(doc))
        .toList();
  }

  Future<List<ChannelModel>> searchChannels(String query) async {
    final snapshot = await _channelsRef
        .where('isPrivate', isEqualTo: false)
        .orderBy('name')
        .startAt([query])
        .endAt(['$query\uf8ff'])
        .limit(20)
        .get();

    return snapshot.docs.map((doc) => ChannelModel.fromFirestore(doc)).toList();
  }
}
