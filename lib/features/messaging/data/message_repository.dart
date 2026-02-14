import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../domain/models/message_model.dart';

final messageRepositoryProvider = Provider<MessageRepository>((ref) {
  return MessageRepository(FirebaseFirestore.instance);
});

class MessageRepository {
  final FirebaseFirestore _firestore;

  MessageRepository(this._firestore);

  CollectionReference<Map<String, dynamic>> get _messagesRef =>
      _firestore.collection('messages');

  /// Send a new message
  Future<MessageModel> sendMessage({
    required String channelId,
    required String senderId,
    required String senderName,
    String? senderPhotoUrl,
    required MessageType type,
    String? content,
    String? audioUrl,
    int? audioDuration,
    GeoPoint? location,
  }) async {
    // Validate required inputs
    if (channelId.trim().isEmpty) {
      throw ArgumentError('channelId cannot be empty');
    }
    if (senderId.trim().isEmpty) {
      throw ArgumentError('senderId cannot be empty');
    }
    if (senderName.trim().isEmpty) {
      throw ArgumentError('senderName cannot be empty');
    }

    // Validate audio messages have audio URL
    if (type == MessageType.audio && (audioUrl == null || audioUrl.trim().isEmpty)) {
      throw ArgumentError('audioUrl is required for audio messages');
    }

    // Validate audio duration is positive
    if (audioDuration != null && audioDuration < 0) {
      throw ArgumentError('audioDuration cannot be negative');
    }

    debugPrint('MessageRepo: Creating message for channel $channelId');
    final docRef = _messagesRef.doc();
    final message = MessageModel(
      id: docRef.id,
      channelId: channelId,
      senderId: senderId,
      senderName: senderName,
      senderPhotoUrl: senderPhotoUrl,
      type: type,
      content: content,
      audioUrl: audioUrl,
      audioDuration: audioDuration,
      location: location,
      timestamp: DateTime.now(),
    );

    await docRef.set(message.toFirestore());
    debugPrint('MessageRepo: Message created with id ${docRef.id}');
    return message;
  }

  /// Send an audio message (PTT transmission record)
  Future<MessageModel> sendAudioMessage({
    required String channelId,
    required String senderId,
    required String senderName,
    String? senderPhotoUrl,
    required int durationSeconds,
    String? audioUrl,
  }) async {
    return sendMessage(
      channelId: channelId,
      senderId: senderId,
      senderName: senderName,
      senderPhotoUrl: senderPhotoUrl,
      type: MessageType.audio,
      audioDuration: durationSeconds,
      audioUrl: audioUrl,
    );
  }

  /// Get messages stream for a channel
  Stream<List<MessageModel>> getChannelMessages(String channelId) {
    debugPrint('MessageRepo: Fetching messages for channel $channelId');
    return _messagesRef
        .where('channelId', isEqualTo: channelId)
        .orderBy('timestamp', descending: true)
        .limit(50)
        .snapshots()
        .map((snapshot) {
          debugPrint('MessageRepo: Got ${snapshot.docs.length} messages');
          return snapshot.docs.map((doc) => MessageModel.fromFirestore(doc)).toList();
        });
  }

  /// Get recent audio messages for a channel
  Stream<List<MessageModel>> getRecentAudioMessages(String channelId) {
    return _messagesRef
        .where('channelId', isEqualTo: channelId)
        .where('type', isEqualTo: MessageType.audio.name)
        .orderBy('timestamp', descending: true)
        .limit(20)
        .snapshots()
        .map((snapshot) =>
            snapshot.docs.map((doc) => MessageModel.fromFirestore(doc)).toList());
  }

  /// Mark a message as read
  Future<void> markAsRead(String messageId) async {
    await _messagesRef.doc(messageId).update({'isRead': true});
  }

  /// Delete a message
  Future<void> deleteMessage(String messageId) async {
    await _messagesRef.doc(messageId).delete();
  }

  /// Get unread messages count for a channel
  Future<int> getUnreadCount(String channelId, String userId) async {
    final snapshot = await _messagesRef
        .where('channelId', isEqualTo: channelId)
        .where('senderId', isNotEqualTo: userId)
        .where('isRead', isEqualTo: false)
        .get();
    return snapshot.docs.length;
  }
}
