import 'package:audio_session/audio_session.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/utils/logger.dart';

/// Provider for audio session configuration
final audioSessionProvider = Provider<AudioSessionManager>((ref) {
  return AudioSessionManager();
});

class AudioSessionManager {
  AudioSession? _session;
  bool _isConfigured = false;

  /// Configure audio session for PTT communication
  Future<void> configureForPtt() async {
    if (_isConfigured) return;

    try {
      _session = await AudioSession.instance;

      await _session!.configure(AudioSessionConfiguration(
        avAudioSessionCategory: AVAudioSessionCategory.playAndRecord,
        avAudioSessionCategoryOptions: AVAudioSessionCategoryOptions.defaultToSpeaker |
            AVAudioSessionCategoryOptions.allowBluetooth,
        avAudioSessionMode: AVAudioSessionMode.voiceChat,
        avAudioSessionRouteSharingPolicy:
            AVAudioSessionRouteSharingPolicy.defaultPolicy,
        avAudioSessionSetActiveOptions: AVAudioSessionSetActiveOptions.none,
        androidAudioAttributes: const AndroidAudioAttributes(
          contentType: AndroidAudioContentType.speech,
          flags: AndroidAudioFlags.none,
          usage: AndroidAudioUsage.voiceCommunication,
        ),
        androidAudioFocusGainType: AndroidAudioFocusGainType.gain,
        androidWillPauseWhenDucked: true,
      ));

      _isConfigured = true;
      Logger.d('Audio session configured for PTT');
    } catch (e) {
      Logger.e('Failed to configure audio session', error: e);
    }
  }

  /// Configure audio session for receiving WebRTC audio
  /// Note: WebRTC requires playAndRecord mode for proper audio routing
  Future<void> configureForReceiving() async {
    try {
      _session ??= await AudioSession.instance;

      await _session!.configure(AudioSessionConfiguration(
        // WebRTC needs playAndRecord for proper audio routing on mobile
        avAudioSessionCategory: AVAudioSessionCategory.playAndRecord,
        avAudioSessionCategoryOptions: AVAudioSessionCategoryOptions.defaultToSpeaker |
            AVAudioSessionCategoryOptions.allowBluetooth,
        avAudioSessionMode: AVAudioSessionMode.voiceChat,
        avAudioSessionRouteSharingPolicy:
            AVAudioSessionRouteSharingPolicy.defaultPolicy,
        avAudioSessionSetActiveOptions: AVAudioSessionSetActiveOptions.none,
        androidAudioAttributes: const AndroidAudioAttributes(
          contentType: AndroidAudioContentType.speech,
          flags: AndroidAudioFlags.none,
          usage: AndroidAudioUsage.voiceCommunication,
        ),
        androidAudioFocusGainType: AndroidAudioFocusGainType.gain,
        androidWillPauseWhenDucked: false,
      ));

      Logger.d('Audio session configured for receiving (playAndRecord mode)');
    } catch (e) {
      Logger.e('Failed to configure audio session for receiving', error: e);
    }
  }

  /// Activate audio session
  Future<bool> activate() async {
    try {
      _session ??= await AudioSession.instance;
      return await _session!.setActive(true);
    } catch (e) {
      Logger.e('Failed to activate audio session', error: e);
      return false;
    }
  }

  /// Deactivate audio session
  Future<void> deactivate() async {
    try {
      _session ??= await AudioSession.instance;
      await _session!.setActive(false);
    } catch (e) {
      Logger.e('Failed to deactivate audio session', error: e);
    }
  }

  /// Listen for audio interruptions
  Stream<AudioInterruptionEvent> get interruptions {
    if (_session == null) {
      return const Stream.empty();
    }
    return _session!.interruptionEventStream;
  }

  /// Listen for becoming noisy events (headphones unplugged)
  Stream<void> get becomingNoisy {
    if (_session == null) {
      return const Stream.empty();
    }
    return _session!.becomingNoisyEventStream;
  }
}

/// Provider to manage PTT audio state based on session state
final pttAudioStateProvider =
    StateNotifierProvider.autoDispose<PttAudioStateNotifier, PttAudioState>(
        (ref) {
  final audioManager = ref.watch(audioSessionProvider);
  return PttAudioStateNotifier(audioManager);
});

enum PttAudioState {
  idle,
  transmitting,
  receiving,
}

class PttAudioStateNotifier extends StateNotifier<PttAudioState> {
  final AudioSessionManager _audioManager;

  PttAudioStateNotifier(this._audioManager) : super(PttAudioState.idle);

  Future<void> startTransmitting() async {
    await _audioManager.configureForPtt();
    await _audioManager.activate();
    state = PttAudioState.transmitting;
  }

  Future<void> startReceiving() async {
    await _audioManager.configureForReceiving();
    await _audioManager.activate();
    state = PttAudioState.receiving;
  }

  Future<void> stop() async {
    await _audioManager.deactivate();
    state = PttAudioState.idle;
  }
}
