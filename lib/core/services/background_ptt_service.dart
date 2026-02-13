import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

/// Background PTT service for keeping the app alive during voice sessions.
/// Uses flutter_background_service to maintain a foreground notification
/// so Android doesn't kill the app while receiving/sending audio.
class BackgroundPttService {
  final FlutterBackgroundService _service = FlutterBackgroundService();
  final FlutterLocalNotificationsPlugin _notifications =
      FlutterLocalNotificationsPlugin();
  bool _initialized = false;

  static const String _notificationChannelId = 'voicely_ptt';
  static const String _notificationChannelName = 'Voicely PTT';
  static const int _notificationId = 888;

  /// Initialize the background service and notification channel
  Future<void> initialize() async {
    if (_initialized) return;

    // Create notification channel
    const androidChannel = AndroidNotificationChannel(
      _notificationChannelId,
      _notificationChannelName,
      description: 'Push-to-talk session active',
      importance: Importance.low,
      playSound: false,
      enableVibration: false,
    );

    final androidPlugin =
        _notifications.resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>();
    await androidPlugin?.createNotificationChannel(androidChannel);

    await _service.configure(
      iosConfiguration: IosConfiguration(
        autoStart: false,
        onForeground: _onStart,
      ),
      androidConfiguration: AndroidConfiguration(
        onStart: _onStart,
        autoStart: false,
        isForegroundMode: true,
        foregroundServiceTypes: [
          AndroidForegroundType.microphone,
          AndroidForegroundType.mediaPlayback,
        ],
        notificationChannelId: _notificationChannelId,
        initialNotificationTitle: 'Voicely',
        initialNotificationContent: 'PTT session active',
        foregroundServiceNotificationId: _notificationId,
      ),
    );

    _initialized = true;
  }

  /// Start the background service
  Future<void> start() async {
    if (!_initialized) await initialize();
    final isRunning = await _service.isRunning();
    if (!isRunning) {
      await _service.startService();
    }
  }

  /// Stop the background service
  Future<void> stop() async {
    final isRunning = await _service.isRunning();
    if (isRunning) {
      _service.invoke('stop');
    }
  }

  /// Update notification to show someone is speaking
  void notifySpeaking(String speakerName, String channelName) {
    _service.invoke('update', {
      'title': 'Voicely - $channelName',
      'content': '$speakerName is speaking',
    });
  }

  /// Update notification to idle state
  void notifyIdle() {
    _service.invoke('update', {
      'title': 'Voicely',
      'content': 'PTT session active',
    });
  }

  /// Static entry point for background isolate
  @pragma('vm:entry-point')
  static Future<void> _onStart(ServiceInstance service) async {
    WidgetsFlutterBinding.ensureInitialized();

    if (service is AndroidServiceInstance) {
      service.on('stop').listen((_) {
        service.stopSelf();
      });

      service.on('update').listen((event) {
        if (event != null) {
          service.setForegroundNotificationInfo(
            title: event['title'] as String? ?? 'Voicely',
            content: event['content'] as String? ?? 'PTT session active',
          );
        }
      });

      // Set as foreground service
      await service.setAsForegroundService();
    }
  }
}
