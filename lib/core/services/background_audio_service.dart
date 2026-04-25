import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:just_audio/just_audio.dart';
import 'package:audio_session/audio_session.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import 'native_audio_service.dart';

const String _lastAutoPlayedKey = 'last_auto_played_message_id';

/// Get the last auto-played message ID (persisted across isolates)
Future<String?> getLastAutoPlayedMessageId() async {
  final prefs = await SharedPreferences.getInstance();
  return prefs.getString(_lastAutoPlayedKey);
}

/// Set the last auto-played message ID (persisted across isolates)
Future<void> setLastAutoPlayedMessageId(String messageId) async {
  final prefs = await SharedPreferences.getInstance();
  await prefs.setString(_lastAutoPlayedKey, messageId);
}

/// Clear the last auto-played message ID
Future<void> clearLastAutoPlayedMessageId() async {
  final prefs = await SharedPreferences.getInstance();
  await prefs.remove(_lastAutoPlayedKey);
}

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

    // Configure audio session for EXCLUSIVE playback even when screen is locked
    // This ensures PTT voice messages are heard clearly without ducking
    final session = await AudioSession.instance;
    await session.configure(const AudioSessionConfiguration(
      avAudioSessionCategory: AVAudioSessionCategory.playback,
      avAudioSessionCategoryOptions: AVAudioSessionCategoryOptions.duckOthers,
      avAudioSessionMode: AVAudioSessionMode.spokenAudio, // Optimized for voice
      avAudioSessionRouteSharingPolicy: AVAudioSessionRouteSharingPolicy.defaultPolicy,
      avAudioSessionSetActiveOptions: AVAudioSessionSetActiveOptions.notifyOthersOnDeactivation,
      androidAudioAttributes: AndroidAudioAttributes(
        contentType: AndroidAudioContentType.speech,
        usage: AndroidAudioUsage.voiceCommunication, // Higher priority for PTT
        flags: AndroidAudioFlags.audibilityEnforced,
      ),
      androidAudioFocusGainType: AndroidAudioFocusGainType.gain, // Exclusive focus
      androidWillPauseWhenDucked: false,
    ));

    // Activate the session immediately
    await session.setActive(true);

    _isInitialized = true;
    debugPrint('BackgroundAudioService: Initialized');
  }

  /// Play audio from URL (works in background with screen off)
  Future<void> playAudio({
    required String audioUrl,
    required String senderName,
    required String channelName,
  }) async {
    if (!_isInitialized) await initialize();

    try {
      debugPrint('BackgroundAudioService: Playing audio from $audioUrl');

      // FIRST: Enable wakelock to keep CPU active during playback
      try {
        await WakelockPlus.enable();
        debugPrint('BackgroundAudioService: Wakelock enabled for playback');
      } catch (e) {
        debugPrint('BackgroundAudioService: Wakelock enable failed: $e');
      }

      // SECOND: Set audio mode BEFORE starting playback (critical for proper routing)
      if (Platform.isAndroid) {
        await NativeAudioService.setAudioModeForPlayback();
        // Delay to ensure audio mode change takes effect before playback
        await Future.delayed(const Duration(milliseconds: 150));
      }

      // THIRD: Stop any existing playback
      await _audioPlayer?.stop();

      // FOURTH: Load and play audio
      await _audioPlayer?.setUrl(audioUrl);
      await _audioPlayer?.play();

      // Listen for completion to release wakelock
      _audioPlayer?.playerStateStream.listen((state) {
        if (state.processingState == ProcessingState.completed ||
            state.processingState == ProcessingState.idle) {
          _releaseWakelock();
        }
      });

      debugPrint('BackgroundAudioService: Audio playback started');
    } catch (e) {
      debugPrint('BackgroundAudioService: Error playing audio: $e');
      _releaseWakelock();
    }
  }

  /// Release wakelock when playback completes
  Future<void> _releaseWakelock() async {
    try {
      await WakelockPlus.disable();
      debugPrint('BackgroundAudioService: Wakelock released');
    } catch (e) {
      debugPrint('BackgroundAudioService: Wakelock release failed: $e');
    }
  }

  /// Stop playback
  Future<void> stop() async {
    await _audioPlayer?.stop();
    await _releaseWakelock();
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
    await _releaseWakelock();
  }
}

// NOTE: The actual FCM background handler is in fcm_ptt_service.dart
// (handleFcmPttBackgroundMessage) which handles both PTT notifications
// and auto-play of voice messages.
