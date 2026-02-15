import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Native audio service for direct Android AudioManager control
class NativeAudioService {
  static const MethodChannel _channel = MethodChannel('com.bitsoft.voicely/audio');

  /// Set speakerphone on/off using native Android AudioManager
  static Future<bool> setSpeakerOn(bool enabled) async {
    try {
      final result = await _channel.invokeMethod('setSpeakerOn', {'enabled': enabled});
      debugPrint('NativeAudio: setSpeakerOn($enabled) = $result');
      return result == true;
    } catch (e) {
      debugPrint('NativeAudio: Error setting speaker: $e');
      return false;
    }
  }

  /// Configure audio mode for voice chat (requests audio focus and sets mode)
  /// Also enables hardware noise suppression for cleaner audio in noisy environments
  static Future<bool> setAudioModeForVoiceChat() async {
    try {
      final result = await _channel.invokeMethod('setAudioModeForVoiceChat');
      debugPrint('NativeAudio: setAudioModeForVoiceChat = $result');

      // Enable hardware noise suppression (zero latency)
      final nsResult = await enableNoiseSuppression();
      debugPrint('NativeAudio: Hardware noise suppression: $nsResult');

      return result == true;
    } catch (e) {
      debugPrint('NativeAudio: Error setting audio mode: $e');
      return false;
    }
  }

  /// Get current audio state for debugging
  static Future<Map<String, dynamic>?> getAudioState() async {
    try {
      final result = await _channel.invokeMethod('getAudioState');
      debugPrint('NativeAudio: getAudioState = $result');
      return Map<String, dynamic>.from(result);
    } catch (e) {
      debugPrint('NativeAudio: Error getting audio state: $e');
      return null;
    }
  }

  /// Play a test tone to verify audio output is working
  static Future<bool> playTestTone() async {
    try {
      final result = await _channel.invokeMethod('playTestTone');
      debugPrint('NativeAudio: playTestTone = $result');
      return result == true;
    } catch (e) {
      debugPrint('NativeAudio: Error playing test tone: $e');
      return false;
    }
  }

  /// Reset audio mode to normal (releases audio focus and resets mode)
  /// Also disables hardware noise suppression
  static Future<bool> resetAudioMode() async {
    try {
      // Disable noise suppression first
      await disableNoiseSuppression();

      final result = await _channel.invokeMethod('resetAudioMode');
      debugPrint('NativeAudio: resetAudioMode = $result');
      return result == true;
    } catch (e) {
      debugPrint('NativeAudio: Error resetting audio mode: $e');
      return false;
    }
  }

  /// Check if battery optimization is disabled for the app
  static Future<bool> isBatteryOptimizationDisabled() async {
    try {
      final result = await _channel.invokeMethod('isBatteryOptimizationDisabled');
      debugPrint('NativeAudio: isBatteryOptimizationDisabled = $result');
      return result == true;
    } catch (e) {
      debugPrint('NativeAudio: Error checking battery optimization: $e');
      return true; // Assume disabled on error (e.g., iOS)
    }
  }

  /// Request the user to disable battery optimization for the app
  /// This is critical for keeping the WebSocket connection alive in background
  static Future<void> requestDisableBatteryOptimization() async {
    try {
      await _channel.invokeMethod('requestDisableBatteryOptimization');
      debugPrint('NativeAudio: Requested battery optimization exemption');
    } catch (e) {
      debugPrint('NativeAudio: Error requesting battery exemption: $e');
    }
  }

  /// Check if hardware noise suppression is available on this device
  static Future<Map<String, bool>> isNoiseSuppressionAvailable() async {
    try {
      final result = await _channel.invokeMethod('isNoiseSuppressionAvailable');
      debugPrint('NativeAudio: isNoiseSuppressionAvailable = $result');
      return Map<String, bool>.from(result);
    } catch (e) {
      debugPrint('NativeAudio: Error checking noise suppression: $e');
      return {'noiseSuppressor': false, 'echoCanceler': false};
    }
  }

  /// Enable hardware-accelerated noise suppression (zero latency)
  /// Pass audioSessionId 0 to attach to global audio session
  static Future<Map<String, bool>> enableNoiseSuppression({int audioSessionId = 0}) async {
    try {
      final result = await _channel.invokeMethod(
        'enableNoiseSuppression',
        {'audioSessionId': audioSessionId},
      );
      debugPrint('NativeAudio: enableNoiseSuppression = $result');
      return Map<String, bool>.from(result);
    } catch (e) {
      debugPrint('NativeAudio: Error enabling noise suppression: $e');
      return {'noiseSuppressorEnabled': false, 'echoCancelerEnabled': false};
    }
  }

  /// Disable hardware noise suppression
  static Future<bool> disableNoiseSuppression() async {
    try {
      final result = await _channel.invokeMethod('disableNoiseSuppression');
      debugPrint('NativeAudio: disableNoiseSuppression = $result');
      return result == true;
    } catch (e) {
      debugPrint('NativeAudio: Error disabling noise suppression: $e');
      return false;
    }
  }
}
