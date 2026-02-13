import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:just_audio/just_audio.dart';

/// Top-level FCM background handler - must be a top-level function
@pragma('vm:entry-point')
Future<void> firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  debugPrint('BackgroundAudio: Handling background FCM message: ${message.messageId}');
}

class BackgroundAudioService {
  AudioPlayer? _player;

  Future<void> initialize() async {
    _player ??= AudioPlayer();
  }

  Future<void> playAudio({
    required String audioUrl,
    required String senderName,
    required String channelName,
  }) async {
    try {
      _player ??= AudioPlayer();

      debugPrint('BackgroundAudio: Playing audio from $senderName in $channelName');
      await _player!.setUrl(audioUrl);
      await _player!.play();
    } catch (e) {
      debugPrint('BackgroundAudio: Failed to play audio: $e');
    }
  }

  Future<void> stop() async {
    try {
      await _player?.stop();
    } catch (e) {
      debugPrint('BackgroundAudio: Failed to stop: $e');
    }
  }

  Future<void> dispose() async {
    await _player?.dispose();
    _player = null;
  }
}
