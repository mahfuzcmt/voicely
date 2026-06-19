import 'dart:async';
import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
// NOTE: wakelock_plus removed - screen wakelock is managed by PTT providers
// Background service uses PARTIAL_WAKE_LOCK for CPU only via native channel

/// Background PTT service for receiving voice messages when app is in background
class BackgroundPttService {
  static final BackgroundPttService _instance = BackgroundPttService._internal();
  factory BackgroundPttService() => _instance;
  BackgroundPttService._internal();

  static const String _notificationChannelId = 'voicely_ptt_channel';
  static const String _notificationChannelName = 'Voicely PTT';
  static const int _notificationId = 888;

  /// Method channel for native wake lock
  static const _channel = MethodChannel('com.voicely.app/wakelock');

  final FlutterBackgroundService _service = FlutterBackgroundService();
  bool _isInitialized = false;

  // Callback for WebSocket ping from background service
  Function()? _onBackgroundPing;

  // Callback for reconnection request from background service
  Future<void> Function()? _onReconnectRequest;

  /// Set callback for background ping (called from main isolate)
  void setOnBackgroundPing(Function() callback) {
    _onBackgroundPing = callback;
  }

  /// Set callback for reconnection request (called when connection is lost)
  void setOnReconnectRequest(Future<void> Function() callback) {
    _onReconnectRequest = callback;
  }

  /// Acquire a partial wake lock to keep CPU running
  static Future<bool> acquirePartialWakeLock() async {
    try {
      final result = await _channel.invokeMethod<bool>('acquirePartialWakeLock');
      debugPrint('BackgroundPttService: Partial wake lock acquired: $result');
      return result ?? false;
    } catch (e) {
      debugPrint('BackgroundPttService: Failed to acquire partial wake lock: $e');
      return false;
    }
  }

  /// Release the partial wake lock
  static Future<void> releasePartialWakeLock() async {
    try {
      await _channel.invokeMethod('releasePartialWakeLock');
      debugPrint('BackgroundPttService: Partial wake lock released');
    } catch (e) {
      debugPrint('BackgroundPttService: Failed to release partial wake lock: $e');
    }
  }

  /// Initialize the background service
  Future<void> initialize() async {
    if (_isInitialized) return;

    // Create notification channel
    final flutterLocalNotificationsPlugin = FlutterLocalNotificationsPlugin();

    const androidChannel = AndroidNotificationChannel(
      _notificationChannelId,
      _notificationChannelName,
      description: 'PTT voice communication service',
      importance: Importance.low,
      playSound: false,
      enableVibration: false,
    );

    await flutterLocalNotificationsPlugin
        .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>()
        ?.createNotificationChannel(androidChannel);

    // Configure the background service
    await _service.configure(
      androidConfiguration: AndroidConfiguration(
        onStart: _onStart,
        autoStart: false,
        autoStartOnBoot: false,
        isForegroundMode: true,
        notificationChannelId: _notificationChannelId,
        initialNotificationTitle: 'Voicely PTT',
        initialNotificationContent: 'Connected - Ready to receive voice messages',
        foregroundServiceNotificationId: _notificationId,
        foregroundServiceTypes: [
          AndroidForegroundType.microphone,
          AndroidForegroundType.mediaPlayback,
          AndroidForegroundType.dataSync,
        ],
      ),
      iosConfiguration: IosConfiguration(
        autoStart: false,
        onForeground: _onStart,
        onBackground: _onIosBackground,
      ),
    );

    // Listen for ping requests from background service
    _service.on('pingWebSocket').listen((event) {
      debugPrint('BackgroundPttService: Received ping request from background');
      _onBackgroundPing?.call();
    });

    // Listen for reconnect requests from background service
    _service.on('reconnectWebSocket').listen((event) {
      debugPrint('BackgroundPttService: Received reconnect request from background');
      _onReconnectRequest?.call();
    });

    // Listen for connection status updates to sync with background
    _service.on('getConnectionStatus').listen((event) {
      // This will be handled by the WebSocket service
    });

    _isInitialized = true;
    debugPrint('BackgroundPttService: Initialized');
  }

  /// Start the background service
  Future<void> start() async {
    if (!_isInitialized) await initialize();

    final isRunning = await _service.isRunning();
    if (!isRunning) {
      await _service.startService();
      debugPrint('BackgroundPttService: Started');
    }
  }

  /// Stop the background service
  Future<void> stop() async {
    try {
      final isRunning = await _service.isRunning();
      if (isRunning) {
        _service.invoke('stop');
        debugPrint('BackgroundPttService: Stopped');
      }
    } catch (e) {
      debugPrint('BackgroundPttService: Failed to stop service: $e');
    }
  }

  /// Check if service is running
  Future<bool> isRunning() => _service.isRunning();

  /// Update notification when someone is speaking
  void updateNotification({
    required String title,
    required String content,
  }) {
    try {
      _service.invoke('updateNotification', {
        'title': title,
        'content': content,
      });
    } catch (e) {
      debugPrint('BackgroundPttService: Failed to update notification: $e');
    }
  }

  /// Update connection status in background service
  void updateConnectionStatus(bool isConnected) {
    try {
      _service.invoke('connectionStatus', {
        'connected': isConnected,
      });
    } catch (e) {
      debugPrint('BackgroundPttService: Failed to update connection status: $e');
    }
  }

  /// Notify that someone started speaking
  void notifySpeaking(String speakerName, String channelName) {
    updateNotification(
      title: '$speakerName is speaking',
      content: 'In $channelName',
    );
  }

  /// Notify idle state
  void notifyIdle() {
    updateNotification(
      title: 'Voicely PTT',
      content: 'Connected - Ready to receive voice messages',
    );
  }

  /// Notify disconnected state
  void notifyDisconnected() {
    updateNotification(
      title: 'Voicely PTT',
      content: 'Reconnecting...',
    );
  }
}

/// Background service entry point - must be top-level
@pragma('vm:entry-point')
void _onStart(ServiceInstance service) async {
  DartPluginRegistrant.ensureInitialized();

  debugPrint('BackgroundPttService: onStart called');

  // NOTE: Don't use WakelockPlus here - it keeps SCREEN on, not just CPU
  // The PARTIAL_WAKE_LOCK from Android native keeps CPU awake for WebSocket
  // Screen wakelock is managed by PTT providers based on broadcasting/listening state

  // Track connection status and disconnection time
  bool isConnected = false;
  DateTime? lastConnectedTime;
  int consecutiveDisconnects = 0;

  if (service is AndroidServiceInstance) {
    service.on('setAsForeground').listen((event) {
      service.setAsForegroundService();
    });

    service.on('setAsBackground').listen((event) {
      service.setAsBackgroundService();
    });
  }

  // Handle notification updates
  service.on('updateNotification').listen((event) async {
    if (event != null && service is AndroidServiceInstance) {
      final title = event['title'] as String? ?? 'Voicely PTT';
      final content = event['content'] as String? ?? 'Ready';

      await service.setForegroundNotificationInfo(
        title: title,
        content: content,
      );
    }
  });

  // Handle connection status updates from main isolate
  service.on('connectionStatus').listen((event) {
    if (event != null) {
      final wasConnected = isConnected;
      isConnected = event['connected'] as bool? ?? false;
      debugPrint('BackgroundPttService: Connection status updated: $isConnected');

      if (isConnected) {
        lastConnectedTime = DateTime.now();
        consecutiveDisconnects = 0;
      } else if (wasConnected && !isConnected) {
        consecutiveDisconnects++;
        debugPrint('BackgroundPttService: Disconnect detected (count: $consecutiveDisconnects)');
      }
    }
  });

  // Handle stop
  service.on('stop').listen((event) async {
    await service.stopSelf();
    debugPrint('BackgroundPttService: Service stopped');
  });

  // Primary heartbeat timer - ping WebSocket every 5 seconds (reduced from 8)
  // More frequent pings help maintain connection in background
  Timer.periodic(const Duration(seconds: 5), (timer) async {
    if (service is AndroidServiceInstance) {
      if (await service.isForegroundService()) {
        debugPrint('BackgroundPttService: Heartbeat - sending ping to main isolate (connected: $isConnected)');

        // Request main isolate to ping WebSocket
        service.invoke('pingWebSocket');

        // If disconnected for more than 10 seconds, request reconnection
        if (!isConnected) {
          await service.setForegroundNotificationInfo(
            title: 'Voicely PTT',
            content: 'Reconnecting...',
          );

          // Request reconnection after 2 failed pings (10 seconds)
          if (consecutiveDisconnects >= 2) {
            debugPrint('BackgroundPttService: Requesting reconnection');
            service.invoke('reconnectWebSocket');
            consecutiveDisconnects = 0; // Reset to avoid spam
          }
        }
      }
    }
  });

  // NOTE: Removed secondary keepalive for WakelockPlus
  // Screen wakelock is now managed by PTT providers based on state
  // This background service only keeps CPU alive via PARTIAL_WAKE_LOCK
}

/// iOS background handler
@pragma('vm:entry-point')
Future<bool> _onIosBackground(ServiceInstance service) async {
  debugPrint('BackgroundPttService: iOS background');

  // NOTE: Don't use WakelockPlus here - screen wakelock is managed by PTT providers
  // iOS has limited background execution, but VoIP mode helps
  // The app should stay alive as long as the background modes are set correctly

  return true;
}
