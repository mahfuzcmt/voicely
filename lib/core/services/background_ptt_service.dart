import 'dart:async';
import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

/// Background PTT service for receiving voice messages when app is in background
class BackgroundPttService {
  static final BackgroundPttService _instance = BackgroundPttService._internal();
  factory BackgroundPttService() => _instance;
  BackgroundPttService._internal();

  static const String _notificationChannelId = 'voicely_ptt_channel';
  static const String _notificationChannelName = 'Voicely PTT';
  static const int _notificationId = 888;

  final FlutterBackgroundService _service = FlutterBackgroundService();
  bool _isInitialized = false;

  // Callback for WebSocket ping from background service
  Function()? _onBackgroundPing;

  /// Set callback for background ping (called from main isolate)
  void setOnBackgroundPing(Function() callback) {
    _onBackgroundPing = callback;
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

  // Enable wakelock to prevent CPU from sleeping
  await WakelockPlus.enable();

  // Track connection status
  bool isConnected = false;

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
      isConnected = event['connected'] as bool? ?? false;
      debugPrint('BackgroundPttService: Connection status updated: $isConnected');
    }
  });

  // Handle stop
  service.on('stop').listen((event) async {
    await WakelockPlus.disable();
    await service.stopSelf();
    debugPrint('BackgroundPttService: Service stopped');
  });

  // Heartbeat timer - ping WebSocket every 8 seconds to keep connection alive
  // More frequent pings help maintain connection in background
  // This runs even when the main isolate is suspended
  Timer.periodic(const Duration(seconds: 8), (timer) async {
    if (service is AndroidServiceInstance) {
      if (await service.isForegroundService()) {
        debugPrint('BackgroundPttService: Heartbeat - sending ping to main isolate');

        // Request main isolate to ping WebSocket
        // This wakes up the main isolate briefly to send the ping
        service.invoke('pingWebSocket');

        // If we detect the connection is lost, update notification
        if (!isConnected) {
          await service.setForegroundNotificationInfo(
            title: 'Voicely PTT',
            content: 'Reconnecting...',
          );
        }
      }
    }
  });

  // Secondary keepalive - ensure wakelock stays enabled
  Timer.periodic(const Duration(seconds: 30), (timer) async {
    try {
      final isEnabled = await WakelockPlus.enabled;
      if (!isEnabled) {
        debugPrint('BackgroundPttService: Re-enabling wakelock');
        await WakelockPlus.enable();
      }
    } catch (e) {
      debugPrint('BackgroundPttService: Wakelock check failed: $e');
    }
  });
}

/// iOS background handler
@pragma('vm:entry-point')
Future<bool> _onIosBackground(ServiceInstance service) async {
  debugPrint('BackgroundPttService: iOS background');

  // Enable wakelock
  await WakelockPlus.enable();

  // iOS has limited background execution, but VoIP mode helps
  // The app should stay alive as long as the background modes are set correctly

  return true;
}
