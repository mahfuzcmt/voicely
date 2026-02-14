import 'dart:async';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:just_audio/just_audio.dart';
import 'package:audio_session/audio_session.dart';

/// Background audio service for playing voice messages
/// even when app is in background or screen is locked
class BackgroundAudioService {
  static final BackgroundAudioService _instance = BackgroundAudioService._internal();
  factory BackgroundAudioService() => _instance;
  BackgroundAudioService._internal();

  AudioPlayer? _audioPlayer;
  bool _isInitialized = false;

  /// Initialize the service
  Future<void> initialize() async {
    if (_isInitialized) return;

    // Initialize audio player
    _audioPlayer = AudioPlayer();

    // Configure audio session for playback even when screen is locked
    final session = await AudioSession.instance;
    await session.configure(const AudioSessionConfiguration(
      avAudioSessionCategory: AVAudioSessionCategory.playback,
      avAudioSessionCategoryOptions: AVAudioSessionCategoryOptions.mixWithOthers,
      avAudioSessionMode: AVAudioSessionMode.defaultMode,
      avAudioSessionRouteSharingPolicy: AVAudioSessionRouteSharingPolicy.defaultPolicy,
      avAudioSessionSetActiveOptions: AVAudioSessionSetActiveOptions.none,
      androidAudioAttributes: AndroidAudioAttributes(
        contentType: AndroidAudioContentType.speech,
        usage: AndroidAudioUsage.media,
        flags: AndroidAudioFlags.audibilityEnforced,
      ),
      androidAudioFocusGainType: AndroidAudioFocusGainType.gainTransientMayDuck,
      androidWillPauseWhenDucked: false,
    ));

    _isInitialized = true;
    debugPrint('BackgroundAudioService: Initialized');
  }

  /// Play audio from URL (works in background)
  Future<void> playAudio({
    required String audioUrl,
    required String senderName,
    required String channelName,
  }) async {
    if (!_isInitialized) await initialize();

    try {
      debugPrint('BackgroundAudioService: Playing audio from $audioUrl');

      // Play audio (no notification)
      await _audioPlayer?.stop();
      await _audioPlayer?.setUrl(audioUrl);
      await _audioPlayer?.play();
    } catch (e) {
      debugPrint('BackgroundAudioService: Error playing audio: $e');
    }
  }

  /// Stop playback
  Future<void> stop() async {
    await _audioPlayer?.stop();
  }

  /// Pause playback
  Future<void> pause() async {
    await _audioPlayer?.pause();
    debugPrint('BackgroundAudioService: Paused');
  }

  /// Resume playback
  Future<void> resume() async {
    await _audioPlayer?.play();
    debugPrint('BackgroundAudioService: Resumed');
  }

  /// Check if currently playing
  bool get isPlaying => _audioPlayer?.playing ?? false;

  /// Check if audio player has content loaded (paused or playing)
  bool get hasContent {
    final state = _audioPlayer?.processingState;
    return state == ProcessingState.ready ||
           state == ProcessingState.buffering ||
           (_audioPlayer?.playing ?? false);
  }

  /// Dispose resources
  Future<void> dispose() async {
    await _audioPlayer?.dispose();
    _audioPlayer = null;
    _isInitialized = false;
  }
}

/// FCM background message handler - must be top-level function
@pragma('vm:entry-point')
Future<void> firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  debugPrint('BackgroundAudioService: Handling background message: ${message.messageId}');

  final data = message.data;
  final audioUrl = data['audioUrl'];
  final senderName = data['senderName'] ?? 'Someone';
  final channelName = data['channelName'] ?? 'Channel';
  final autoPlay = data['autoPlay'] == 'true';

  if (audioUrl != null && autoPlay) {
    final service = BackgroundAudioService();
    await service.initialize();
    await service.playAudio(
      audioUrl: audioUrl,
      senderName: senderName,
      channelName: channelName,
    );
  }
}
