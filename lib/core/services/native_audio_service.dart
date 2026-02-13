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
  static Future<bool> setAudioModeForVoiceChat() async {
    try {
      final result = await _channel.invokeMethod('setAudioModeForVoiceChat');
      debugPrint('NativeAudio: setAudioModeForVoiceChat = $result');
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
  static Future<bool> resetAudioMode() async {
    try {
      final result = await _channel.invokeMethod('resetAudioMode');
      debugPrint('NativeAudio: resetAudioMode = $result');
      return result == true;
    } catch (e) {
      debugPrint('NativeAudio: Error resetting audio mode: $e');
      return false;
    }
  }
}
