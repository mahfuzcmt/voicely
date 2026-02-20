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

  /// Get messages stream for a channel (use sparingly - continuous reads)
  Stream<List<MessageModel>> getChannelMessages(String channelId) {
    debugPrint('MessageRepo: Fetching messages for channel $channelId');
    return _messagesRef
        .where('channelId', isEqualTo: channelId)
        .orderBy('timestamp', descending: true)
        .limit(20) // Reduced from 50 to save reads
        .snapshots()
        .map((snapshot) {
          debugPrint('MessageRepo: Got ${snapshot.docs.length} messages');
          return snapshot.docs.map((doc) => MessageModel.fromFirestore(doc)).toList();
        });
  }

  /// Get the LAST audio message only - ONE TIME fetch (saves reads)
  /// Use this for auto-play feature instead of streaming
  /// Only fetches 3 messages to minimize Firestore reads
  Future<MessageModel?> getLastAudioMessage(String channelId) async {
    try {
      // Get only last 3 messages - most recent is usually audio in PTT app
      final snapshot = await _messagesRef
          .where('channelId', isEqualTo: channelId)
          .orderBy('timestamp', descending: true)
          .limit(3) // Minimal fetch - save Firestore reads
          .get();

      if (snapshot.docs.isEmpty) {
        debugPrint('MessageRepo: No messages found in channel $channelId');
        return null;
      }

      // Find the first audio message
      for (final doc in snapshot.docs) {
        final message = MessageModel.fromFirestore(doc);
        if (message.type == MessageType.audio && message.audioUrl != null) {
          debugPrint('MessageRepo: Found last audio message ${message.id}');
          return message;
        }
      }

      debugPrint('MessageRepo: No audio messages in last 3 messages');
      return null;
    } catch (e) {
      debugPrint('MessageRepo: Error getting last audio message: $e');
      rethrow;
    }
  }

  /// Get recent audio messages ONE TIME (not a stream - saves reads)
  Future<List<MessageModel>> getRecentAudioMessagesOnce(String channelId, {int limit = 10}) async {
    try {
      // Get recent messages and filter for audio type in code
      // This avoids needing a composite Firestore index
      final snapshot = await _messagesRef
          .where('channelId', isEqualTo: channelId)
          .orderBy('timestamp', descending: true)
          .limit(limit * 2) // Get more to ensure we have enough audio messages
          .get();

      final audioMessages = snapshot.docs
          .map((doc) => MessageModel.fromFirestore(doc))
          .where((m) => m.type == MessageType.audio && m.audioUrl != null)
          .take(limit)
          .toList();

      debugPrint('MessageRepo: Found ${audioMessages.length} audio messages');
      return audioMessages;
    } catch (e) {
      debugPrint('MessageRepo: Error getting recent audio messages: $e');
      rethrow;
    }
  }

  /// Get recent audio messages as stream (use sparingly)
  @Deprecated('Use getRecentAudioMessagesOnce or getLastAudioMessage instead to save reads')
  Stream<List<MessageModel>> getRecentAudioMessages(String channelId) {
    return _messagesRef
        .where('channelId', isEqualTo: channelId)
        .where('type', isEqualTo: MessageType.audio.name)
        .orderBy('timestamp', descending: true)
        .limit(10) // Reduced from 20
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
