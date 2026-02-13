import 'package:flutter/services.dart';

/// Native audio service for controlling Android AudioManager
/// Uses method channel to communicate with Kotlin native code
class NativeAudioService {
  static const MethodChannel _channel =
      MethodChannel('com.bitsoft.voicely/audio');

  /// Set audio mode to MODE_IN_COMMUNICATION for voice chat
  static Future<bool> setAudioModeForVoiceChat() async {
    try {
      final result =
          await _channel.invokeMethod<bool>('setAudioModeForVoiceChat');
      return result ?? false;
    } on PlatformException catch (e) {
      // Fallback: return false but don't crash
      _log('setAudioModeForVoiceChat failed: $e');
      return false;
    } on MissingPluginException {
      // Platform not supported (iOS, web, etc.)
      return false;
    }
  }

  /// Enable or disable speakerphone
  static Future<bool> setSpeakerOn(bool enabled) async {
    try {
      final result =
          await _channel.invokeMethod<bool>('setSpeakerOn', {'enabled': enabled});
      return result ?? false;
    } on PlatformException catch (e) {
      _log('setSpeakerOn failed: $e');
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  /// Get current audio state for debugging
  static Future<Map<String, dynamic>> getAudioState() async {
    try {
      final result =
          await _channel.invokeMethod<Map>('getAudioState');
      if (result == null) return {};
      return Map<String, dynamic>.from(result);
    } on PlatformException catch (e) {
      _log('getAudioState failed: $e');
      return {'error': e.message};
    } on MissingPluginException {
      return {'error': 'Platform not supported'};
    }
  }

  /// Reset audio mode to normal
  static Future<bool> resetAudioMode() async {
    try {
      final result =
          await _channel.invokeMethod<bool>('resetAudioMode');
      return result ?? false;
    } on PlatformException catch (e) {
      _log('resetAudioMode failed: $e');
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  static void _log(String message) {
    // Use assert to only log in debug mode
    assert(() {
      // ignore: avoid_print
      print('NativeAudioService: $message');
      return true;
    }());
  }
}
