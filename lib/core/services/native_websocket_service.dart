import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Native WebSocket service that runs in Android foreground service.
/// This keeps the WebSocket connection alive even when the Flutter app is backgrounded.
class NativeWebSocketService {
  static const _methodChannel = MethodChannel('com.voicely.app/websocket');
  static const _eventChannel = EventChannel('com.voicely.app/websocket/events');

  static NativeWebSocketService? _instance;
  static NativeWebSocketService get instance {
    _instance ??= NativeWebSocketService._();
    return _instance!;
  }

  NativeWebSocketService._();

  StreamSubscription? _eventSubscription;
  final _connectionStateController = StreamController<bool>.broadcast();
  final _messageController = StreamController<Map<String, dynamic>>.broadcast();

  bool _isRunning = false;
  bool _isConnected = false;

  /// Stream of connection state changes
  Stream<bool> get connectionState => _connectionStateController.stream;

  /// Stream of received messages
  Stream<Map<String, dynamic>> get messages => _messageController.stream;

  /// Whether the native service is running
  bool get isRunning => _isRunning;

  /// Whether the WebSocket is connected
  bool get isConnected => _isConnected;

  /// Start the native WebSocket service
  Future<bool> startService({
    required String serverUrl,
    required String authToken,
    String? displayName,
    String? roomId,
  }) async {
    try {
      debugPrint('NativeWebSocket: Starting service...');

      // Start listening to events first
      _startEventListener();

      final result = await _methodChannel.invokeMethod<bool>('startService', {
        'serverUrl': serverUrl,
        'authToken': authToken,
        'displayName': displayName,
        'roomId': roomId,
      });

      _isRunning = result ?? false;
      debugPrint('NativeWebSocket: Service started: $_isRunning');
      return _isRunning;
    } catch (e) {
      debugPrint('NativeWebSocket: Failed to start service: $e');
      return false;
    }
  }

  /// Stop the native WebSocket service
  Future<void> stopService() async {
    try {
      debugPrint('NativeWebSocket: Stopping service...');
      await _methodChannel.invokeMethod('stopService');
      _isRunning = false;
      _isConnected = false;
      _stopEventListener();
      debugPrint('NativeWebSocket: Service stopped');
    } catch (e) {
      debugPrint('NativeWebSocket: Failed to stop service: $e');
    }
  }

  /// Check if the native service is running
  Future<bool> checkIsRunning() async {
    try {
      final result = await _methodChannel.invokeMethod<bool>('isRunning');
      _isRunning = result ?? false;
      return _isRunning;
    } catch (e) {
      debugPrint('NativeWebSocket: Failed to check isRunning: $e');
      return false;
    }
  }

  /// Update authentication credentials
  Future<bool> updateCredentials({
    required String authToken,
    String? displayName,
  }) async {
    try {
      final result = await _methodChannel.invokeMethod<bool>('updateCredentials', {
        'authToken': authToken,
        'displayName': displayName,
      });
      return result ?? false;
    } catch (e) {
      debugPrint('NativeWebSocket: Failed to update credentials: $e');
      return false;
    }
  }

  /// Join a room/channel
  Future<bool> joinRoom(String roomId) async {
    try {
      final result = await _methodChannel.invokeMethod<bool>('joinRoom', {
        'roomId': roomId,
      });
      return result ?? false;
    } catch (e) {
      debugPrint('NativeWebSocket: Failed to join room: $e');
      return false;
    }
  }

  /// Leave a room/channel
  Future<bool> leaveRoom(String roomId) async {
    try {
      final result = await _methodChannel.invokeMethod<bool>('leaveRoom', {
        'roomId': roomId,
      });
      return result ?? false;
    } catch (e) {
      debugPrint('NativeWebSocket: Failed to leave room: $e');
      return false;
    }
  }

  /// Send a raw message
  Future<bool> sendMessage(Map<String, dynamic> message) async {
    try {
      final result = await _methodChannel.invokeMethod<bool>('sendMessage', {
        'message': jsonEncode(message),
      });
      return result ?? false;
    } catch (e) {
      debugPrint('NativeWebSocket: Failed to send message: $e');
      return false;
    }
  }

  void _startEventListener() {
    _stopEventListener();

    _eventSubscription = _eventChannel.receiveBroadcastStream().listen(
      (event) {
        if (event is Map) {
          final type = event['type'] as String?;

          if (type == 'connectionState') {
            _isConnected = event['isConnected'] as bool? ?? false;
            debugPrint('NativeWebSocket: Connection state: $_isConnected');
            _connectionStateController.add(_isConnected);
          } else if (type == 'message') {
            final data = event['data'] as String?;
            if (data != null) {
              try {
                final json = jsonDecode(data) as Map<String, dynamic>;
                _messageController.add(json);
              } catch (e) {
                debugPrint('NativeWebSocket: Failed to parse message: $e');
              }
            }
          }
        }
      },
      onError: (error) {
        debugPrint('NativeWebSocket: Event stream error: $error');
      },
    );
  }

  void _stopEventListener() {
    _eventSubscription?.cancel();
    _eventSubscription = null;
  }

  /// Dispose resources
  void dispose() {
    _stopEventListener();
    _connectionStateController.close();
    _messageController.close();
  }
}
