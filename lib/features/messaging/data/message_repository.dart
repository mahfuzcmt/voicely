import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/utils/logger.dart';
import '../domain/models/message_model.dart';

final messageRepositoryProvider = Provider<MessageRepository>((ref) {
  return MessageRepository(firestore: FirebaseFirestore.instance);
});

class MessageRepository {
  final FirebaseFirestore _firestore;

  MessageRepository({required FirebaseFirestore firestore})
      : _firestore = firestore;

  CollectionReference<Map<String, dynamic>> _messagesRef(String channelId) =>
      _firestore.collection('channels').doc(channelId).collection('messages');

  Stream<List<MessageModel>> getChannelMessages(String channelId) {
    return _messagesRef(channelId)
        .orderBy('timestamp', descending: true)
        .limit(100)
        .snapshots()
        .map((snapshot) => snapshot.docs
            .map((doc) => MessageModel.fromFirestore(doc))
            .toList());
  }

  Future<void> sendAudioMessage({
    required String channelId,
    required String senderId,
    required String senderName,
    String? senderPhotoUrl,
    required String audioUrl,
    required int durationSeconds,
  }) async {
    try {
      final message = MessageModel(
        id: '',
        channelId: channelId,
        senderId: senderId,
        senderName: senderName,
        senderPhotoUrl: senderPhotoUrl,
        type: MessageType.audio,
        audioUrl: audioUrl,
        audioDuration: durationSeconds,
      );

      await _messagesRef(channelId).add(message.toFirestore());
    } catch (e) {
      Logger.e('Send audio message error', error: e);
      rethrow;
    }
  }

  Future<void> deleteMessage(String channelId, String messageId) async {
    try {
      await _messagesRef(channelId).doc(messageId).delete();
    } catch (e) {
      Logger.e('Delete message error', error: e);
      rethrow;
    }
  }
}
