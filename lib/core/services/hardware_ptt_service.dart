import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Hardware PTT button event types
enum PttEventType {
  down,
  up,
  longPress,
  sosDown,
  sosUp,
  sosLongPress,
  channelUp,
  channelDown,
}

/// Hardware PTT button event
class PttEvent {
  final PttEventType type;
  final int keyCode;
  final int timestamp;

  PttEvent({
    required this.type,
    required this.keyCode,
    required this.timestamp,
  });

  factory PttEvent.fromMap(Map<dynamic, dynamic> map) {
    final typeStr = map['type'] as String;
    PttEventType type;
    switch (typeStr) {
      case 'ptt_down':
        type = PttEventType.down;
        break;
      case 'ptt_up':
        type = PttEventType.up;
        break;
      case 'ptt_longpress':
        type = PttEventType.longPress;
        break;
      case 'sos_down':
        type = PttEventType.sosDown;
        break;
      case 'sos_up':
        type = PttEventType.sosUp;
        break;
      case 'sos_longpress':
      case 'sos_shortpress':
        type = PttEventType.sosLongPress;
        break;
      case 'channel_up':
        type = PttEventType.channelUp;
        break;
      case 'channel_down':
        type = PttEventType.channelDown;
        break;
      default:
        type = typeStr.contains('down') ? PttEventType.down : PttEventType.up;
    }
    return PttEvent(
      type: type,
      keyCode: map['keyCode'] as int,
      timestamp: map['timestamp'] as int,
    );
  }

  @override
  String toString() => 'PttEvent(type: $type, keyCode: $keyCode)';
}

/// Common hardware PTT key codes used by Chinese PTT devices
class PttKeyCodes {
  /// Standard headset button
  static const int headsethook = 79;

  /// Media play/pause button
  static const int mediaPlayPause = 85;

  /// Call button (some devices use this as PTT)
  static const int call = 5;

  /// Volume up (can be used as PTT)
  static const int volumeUp = 24;

  /// QMSTAR PTT key (from OS-360 spec)
  static const int qmstarPtt = 131;

  /// Inrico T310 PTT key
  static const int inricoT310Ptt = 141;

  /// Inrico T310 SOS key
  static const int inricoT310Sos = 142;

  /// UNIPRO Custom Key 1 (P2)
  static const int uniproP2 = 201;

  /// UNIPRO Custom Key 2 (P3)
  static const int uniproP3 = 202;

  /// Custom PTT key codes used by various Chinese manufacturers
  static const int custom293 = 293;
  static const int custom294 = 294;
  static const int custom295 = 295;
  static const int custom296 = 296;
  static const int custom297 = 297;
  static const int custom298 = 298;
  static const int custom299 = 299;
  static const int custom300 = 300;
  static const int custom301 = 301;

  /// F1/F2 keys used as PTT on some devices
  static const int f1 = 302;
  static const int f2 = 303;

  /// Motorola PTT devices
  static const int motorola500 = 500;
  static const int motorola501 = 501;
}

/// Service for handling hardware PTT button events from Chinese PTT devices
///
/// This service listens for hardware key events (typically from physical PTT buttons)
/// and notifies listeners when the button is pressed/released.
///
/// Usage:
/// ```dart
/// // Initialize the service
/// await HardwarePttService.init();
///
/// // Listen for PTT events
/// HardwarePttService.pttEvents.listen((event) {
///   if (event.type == PttEventType.down) {
///     // Start transmitting
///   } else {
///     // Stop transmitting
///   }
/// });
///
/// // Cleanup when done
/// HardwarePttService.dispose();
/// ```
class HardwarePttService {
  static const MethodChannel _channel = MethodChannel('com.voicely.app/ptt');
  static const EventChannel _eventChannel = EventChannel('com.voicely.app/ptt/events');

  static StreamSubscription? _eventSubscription;
  static final StreamController<PttEvent> _pttController = StreamController<PttEvent>.broadcast();

  /// Stream of PTT button events
  static Stream<PttEvent> get pttEvents => _pttController.stream;

  /// Callback for PTT button press (convenience method)
  static VoidCallback? onPttDown;

  /// Callback for PTT button release (convenience method)
  static VoidCallback? onPttUp;

  /// Callback for SOS button press
  static VoidCallback? onSosDown;

  /// Callback for SOS button release
  static VoidCallback? onSosUp;

  /// Callback for channel up
  static VoidCallback? onChannelUp;

  /// Callback for channel down
  static VoidCallback? onChannelDown;

  /// Initialize the hardware PTT service
  /// Call this once when the app starts
  static Future<void> init() async {
    debugPrint('HardwarePTT: Initializing service');

    _eventSubscription = _eventChannel.receiveBroadcastStream().listen(
      (dynamic event) {
        try {
          if (event is Map) {
            final pttEvent = PttEvent.fromMap(event);
            debugPrint('HardwarePTT: Received event $pttEvent');

            // Notify stream listeners
            _pttController.add(pttEvent);

            // Call convenience callbacks
            switch (pttEvent.type) {
              case PttEventType.down:
                onPttDown?.call();
                break;
              case PttEventType.up:
                onPttUp?.call();
                break;
              case PttEventType.longPress:
                // Long press can be treated as down for PTT behavior
                onPttDown?.call();
                break;
              case PttEventType.sosDown:
                onSosDown?.call();
                break;
              case PttEventType.sosUp:
              case PttEventType.sosLongPress:
                onSosUp?.call();
                break;
              case PttEventType.channelUp:
                onChannelUp?.call();
                break;
              case PttEventType.channelDown:
                onChannelDown?.call();
                break;
            }
          }
        } catch (e) {
          debugPrint('HardwarePTT: Error processing event: $e');
        }
      },
      onError: (error) {
        debugPrint('HardwarePTT: Stream error: $error');
      },
    );

    debugPrint('HardwarePTT: Service initialized');
  }

  /// Dispose of the service
  static void dispose() {
    _eventSubscription?.cancel();
    _eventSubscription = null;
    onPttDown = null;
    onPttUp = null;
    onSosDown = null;
    onSosUp = null;
    onChannelUp = null;
    onChannelDown = null;
    debugPrint('HardwarePTT: Service disposed');
  }

  /// Check if PTT button is currently pressed
  static Future<bool> isPttButtonPressed() async {
    try {
      final result = await _channel.invokeMethod('isPttButtonPressed');
      return result == true;
    } catch (e) {
      debugPrint('HardwarePTT: Error checking button state: $e');
      return false;
    }
  }

  /// Enable a specific key code to be recognized as PTT button
  static Future<bool> enablePttKeyCode(int keyCode) async {
    try {
      final result = await _channel.invokeMethod('enablePttKeyCode', {'keyCode': keyCode});
      debugPrint('HardwarePTT: Enabled key code $keyCode');
      return result == true;
    } catch (e) {
      debugPrint('HardwarePTT: Error enabling key code: $e');
      return false;
    }
  }

  /// Disable a specific key code from being recognized as PTT button
  static Future<bool> disablePttKeyCode(int keyCode) async {
    try {
      final result = await _channel.invokeMethod('disablePttKeyCode', {'keyCode': keyCode});
      debugPrint('HardwarePTT: Disabled key code $keyCode');
      return result == true;
    } catch (e) {
      debugPrint('HardwarePTT: Error disabling key code: $e');
      return false;
    }
  }

  /// Get list of currently enabled PTT key codes
  static Future<List<int>> getEnabledPttKeyCodes() async {
    try {
      final result = await _channel.invokeMethod('getEnabledPttKeyCodes');
      if (result is List) {
        return result.cast<int>();
      }
      return [];
    } catch (e) {
      debugPrint('HardwarePTT: Error getting enabled key codes: $e');
      return [];
    }
  }

  /// Reset PTT key codes to default set
  static Future<bool> resetPttKeyCodes() async {
    try {
      final result = await _channel.invokeMethod('resetPttKeyCodes');
      debugPrint('HardwarePTT: Reset key codes to defaults');
      return result == true;
    } catch (e) {
      debugPrint('HardwarePTT: Error resetting key codes: $e');
      return false;
    }
  }

  /// Wake up the screen (turn on display)
  static Future<bool> wakeScreen() async {
    try {
      final result = await _channel.invokeMethod('wakeScreen');
      debugPrint('HardwarePTT: Wake screen result: $result');
      return result == true;
    } catch (e) {
      debugPrint('HardwarePTT: Error waking screen: $e');
      return false;
    }
  }
}
