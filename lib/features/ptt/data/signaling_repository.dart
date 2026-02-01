import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/constants/app_constants.dart';
import '../../../core/utils/logger.dart';
import '../domain/models/signaling_model.dart';

final signalingRepositoryProvider = Provider<SignalingRepository>((ref) {
  return SignalingRepository(firestore: FirebaseFirestore.instance);
});

class SignalingRepository {
  final FirebaseFirestore _firestore;

  SignalingRepository({required FirebaseFirestore firestore})
      : _firestore = firestore;

  CollectionReference<Map<String, dynamic>> _signalingRef(String channelId) =>
      _firestore
          .collection(AppConstants.channelsCollection)
          .doc(channelId)
          .collection('signaling');

  CollectionReference<Map<String, dynamic>> _iceCandidatesRef(
          String channelId) =>
      _firestore
          .collection(AppConstants.channelsCollection)
          .doc(channelId)
          .collection('iceCandidates');

  /// Send SDP offer to a specific peer
  Future<void> sendOffer({
    required String channelId,
    required String fromUserId,
    required String toUserId,
    required String sdp,
  }) async {
    try {
      final signaling = SignalingModel(
        id: '',
        type: SignalingType.offer,
        fromUserId: fromUserId,
        toUserId: toUserId,
        sdp: sdp,
        createdAt: DateTime.now(),
      );

      await _signalingRef(channelId).add(signaling.toFirestore());
      Logger.d('Sent offer from $fromUserId to $toUserId');
    } catch (e) {
      Logger.e('Send offer error', error: e);
      rethrow;
    }
  }

  /// Send SDP answer to a specific peer
  Future<void> sendAnswer({
    required String channelId,
    required String fromUserId,
    required String toUserId,
    required String sdp,
  }) async {
    try {
      final signaling = SignalingModel(
        id: '',
        type: SignalingType.answer,
        fromUserId: fromUserId,
        toUserId: toUserId,
        sdp: sdp,
        createdAt: DateTime.now(),
      );

      await _signalingRef(channelId).add(signaling.toFirestore());
      Logger.d('Sent answer from $fromUserId to $toUserId');
    } catch (e) {
      Logger.e('Send answer error', error: e);
      rethrow;
    }
  }

  /// Send ICE candidate to a specific peer
  Future<void> sendIceCandidate({
    required String channelId,
    required String fromUserId,
    required String toUserId,
    required String candidate,
    required String sdpMid,
    required int sdpMLineIndex,
  }) async {
    try {
      final iceCandidate = IceCandidateModel(
        id: '',
        fromUserId: fromUserId,
        toUserId: toUserId,
        candidate: candidate,
        sdpMid: sdpMid,
        sdpMLineIndex: sdpMLineIndex,
        createdAt: DateTime.now(),
      );

      await _iceCandidatesRef(channelId).add(iceCandidate.toFirestore());
    } catch (e) {
      Logger.e('Send ICE candidate error', error: e);
      rethrow;
    }
  }

  /// Listen for signaling messages (offers/answers) directed to current user
  Stream<List<SignalingModel>> listenForSignaling({
    required String channelId,
    required String currentUserId,
  }) {
    return _signalingRef(channelId)
        .where('toUserId', isEqualTo: currentUserId)
        .orderBy('createdAt', descending: false)
        .snapshots()
        .map((snapshot) => snapshot.docs
            .map((doc) => SignalingModel.fromFirestore(doc))
            .toList());
  }

  /// Listen for ICE candidates directed to current user
  Stream<List<IceCandidateModel>> listenForIceCandidates({
    required String channelId,
    required String currentUserId,
  }) {
    return _iceCandidatesRef(channelId)
        .where('toUserId', isEqualTo: currentUserId)
        .orderBy('createdAt', descending: false)
        .snapshots()
        .map((snapshot) => snapshot.docs
            .map((doc) => IceCandidateModel.fromFirestore(doc))
            .toList());
  }

  /// Delete a signaling document after processing
  Future<void> deleteSignaling({
    required String channelId,
    required String signalingId,
  }) async {
    try {
      await _signalingRef(channelId).doc(signalingId).delete();
    } catch (e) {
      Logger.e('Delete signaling error', error: e);
    }
  }

  /// Delete an ICE candidate document after processing
  Future<void> deleteIceCandidate({
    required String channelId,
    required String candidateId,
  }) async {
    try {
      await _iceCandidatesRef(channelId).doc(candidateId).delete();
    } catch (e) {
      Logger.e('Delete ICE candidate error', error: e);
    }
  }

  /// Clean up all signaling data for a user in a channel
  Future<void> cleanupSignaling({
    required String channelId,
    required String userId,
  }) async {
    try {
      final batch = _firestore.batch();

      // Delete all signaling documents from/to this user
      final signalingFromUser = await _signalingRef(channelId)
          .where('fromUserId', isEqualTo: userId)
          .get();
      for (final doc in signalingFromUser.docs) {
        batch.delete(doc.reference);
      }

      final signalingToUser = await _signalingRef(channelId)
          .where('toUserId', isEqualTo: userId)
          .get();
      for (final doc in signalingToUser.docs) {
        batch.delete(doc.reference);
      }

      // Delete all ICE candidates from/to this user
      final iceCandidatesFromUser = await _iceCandidatesRef(channelId)
          .where('fromUserId', isEqualTo: userId)
          .get();
      for (final doc in iceCandidatesFromUser.docs) {
        batch.delete(doc.reference);
      }

      final iceCandidatesToUser = await _iceCandidatesRef(channelId)
          .where('toUserId', isEqualTo: userId)
          .get();
      for (final doc in iceCandidatesToUser.docs) {
        batch.delete(doc.reference);
      }

      await batch.commit();
      Logger.d('Cleaned up signaling for user $userId in channel $channelId');
    } catch (e) {
      Logger.e('Cleanup signaling error', error: e);
    }
  }

  /// Clean up all signaling data in a channel (for when floor is released)
  Future<void> cleanupAllSignaling(String channelId) async {
    try {
      final batch = _firestore.batch();

      final signalingDocs = await _signalingRef(channelId).get();
      for (final doc in signalingDocs.docs) {
        batch.delete(doc.reference);
      }

      final iceCandidateDocs = await _iceCandidatesRef(channelId).get();
      for (final doc in iceCandidateDocs.docs) {
        batch.delete(doc.reference);
      }

      await batch.commit();
      Logger.d('Cleaned up all signaling in channel $channelId');
    } catch (e) {
      Logger.e('Cleanup all signaling error', error: e);
    }
  }
}
