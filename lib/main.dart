import 'dart:async';

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'core/router/app_router.dart';
import 'core/services/background_audio_service.dart';
import 'core/services/fcm_ptt_service.dart';
import 'core/theme/app_theme.dart';
import 'firebase_options.dart';

/// Global navigator key for navigation from notification taps
final GlobalKey<NavigatorState> navigatorKey = GlobalKey<NavigatorState>();

/// Global notification plugin instance
final FlutterLocalNotificationsPlugin flutterLocalNotificationsPlugin =
    FlutterLocalNotificationsPlugin();

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Initialize Firebase
  await Firebase.initializeApp(
    options: DefaultFirebaseOptions.currentPlatform,
  );

  // Initialize FCM background handler for PTT wake-up
  // This is critical for receiving live broadcast notifications
  FirebaseMessaging.onBackgroundMessage(handleFcmPttBackgroundMessage);

  // Initialize background audio service
  final backgroundService = BackgroundAudioService();
  await backgroundService.initialize();

  // Initialize local notifications for showing alerts when app is in background
  await _initializeLocalNotifications();

  // Request notification permission
  await _requestNotificationPermission();

  // Set preferred orientations
  await SystemChrome.setPreferredOrientations([
    DeviceOrientation.portraitUp,
    DeviceOrientation.portraitDown,
  ]);

  // Set system UI overlay style
  SystemChrome.setSystemUIOverlayStyle(
    const SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      statusBarIconBrightness: Brightness.light,
      systemNavigationBarColor: Colors.black,
      systemNavigationBarIconBrightness: Brightness.light,
    ),
  );

  runApp(const ProviderScope(child: VoicelyApp()));
}

/// Initialize local notifications for showing alerts
Future<void> _initializeLocalNotifications() async {
  const androidSettings = AndroidInitializationSettings('@mipmap/ic_launcher');
  const iosSettings = DarwinInitializationSettings(
    requestSoundPermission: true,
    requestBadgePermission: true,
    requestAlertPermission: true,
  );
  const initSettings = InitializationSettings(
    android: androidSettings,
    iOS: iosSettings,
  );

  await flutterLocalNotificationsPlugin.initialize(
    initSettings,
    onDidReceiveNotificationResponse: _onNotificationTapped,
  );

  // Create notification channel for live broadcasts with attention-grabbing settings
  const androidChannel = AndroidNotificationChannel(
    'voicely_live_channel',
    'Live Broadcasts',
    description: 'Notifications when someone is speaking',
    importance: Importance.max,
    playSound: true,
    enableVibration: true,
    showBadge: true,
  );

  await flutterLocalNotificationsPlugin
      .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>()
      ?.createNotificationChannel(androidChannel);

  debugPrint('Local notifications initialized');
}

/// Handle notification tap - navigate to the channel
void _onNotificationTapped(NotificationResponse response) {
  final channelId = response.payload;
  debugPrint('Notification tapped, channelId: $channelId');

  if (channelId != null && channelId.isNotEmpty) {
    // Store the channel ID to navigate after app is ready
    _pendingChannelId = channelId;
    // Also emit to stream for apps that are already running
    _notificationTapController.add(channelId);
  }
}

/// Pending channel ID to navigate to after app startup
String? _pendingChannelId;

/// Stream controller for real-time notification tap events
final _notificationTapController = StreamController<String>.broadcast();

/// Stream of notification taps with channel IDs (for when app is already open)
Stream<String> get notificationTapStream => _notificationTapController.stream;

/// Get and clear the pending channel ID
String? getPendingChannelId() {
  final channelId = _pendingChannelId;
  _pendingChannelId = null;
  return channelId;
}

Future<void> _requestNotificationPermission() async {
  final messaging = FirebaseMessaging.instance;

  // Request permission
  final settings = await messaging.requestPermission(
    alert: true,
    badge: true,
    sound: true,
    criticalAlert: true,
    provisional: false,
  );

  debugPrint('FCM: Permission status: ${settings.authorizationStatus}');

  // Get FCM token
  final token = await messaging.getToken();
  debugPrint('FCM: Token: $token');
}

class VoicelyApp extends ConsumerStatefulWidget {
  const VoicelyApp({super.key});

  @override
  ConsumerState<VoicelyApp> createState() => _VoicelyAppState();
}

class _VoicelyAppState extends ConsumerState<VoicelyApp> {
  @override
  void initState() {
    super.initState();
    _setupFCMListeners();
    _checkInitialFCMMessage();
  }

  /// Check if app was opened from a killed state by tapping FCM notification
  Future<void> _checkInitialFCMMessage() async {
    // Get the initial message if the app was opened from a terminated state
    final initialMessage = await FirebaseMessaging.instance.getInitialMessage();

    if (initialMessage != null) {
      debugPrint('FCM: App opened from killed state via notification');
      debugPrint('FCM: Initial message data: ${initialMessage.data}');

      // Store the channel ID for navigation after app is ready
      final channelId = initialMessage.data['channelId'] as String?;
      if (channelId != null && channelId.isNotEmpty) {
        _pendingChannelId = channelId;
        debugPrint('FCM: Stored pending channelId: $channelId');
      }
    }
  }

  void _setupFCMListeners() {
    final fcmPttService = FcmPttService();

    // Handle foreground messages - route through FCM PTT service
    FirebaseMessaging.onMessage.listen((RemoteMessage message) {
      debugPrint('FCM: Foreground message received: ${message.messageId}');
      debugPrint('FCM: Message data: ${message.data}');

      // Check if this is a PTT-related message
      final messageType = message.data['type'] as String?;
      if (messageType == 'live_broadcast_started' ||
          messageType == 'live_broadcast_ended') {
        // Handle through PTT service
        fcmPttService.handleMessage(message);

        // For foreground, show a local notification so user knows someone is speaking
        if (messageType == 'live_broadcast_started') {
          _showLiveBroadcastNotification(message);
        }
        return;
      }

      // Legacy handling for voice messages with audio URLs
      final data = message.data;
      final audioUrl = data['audioUrl'];
      final senderName = data['senderName'] ?? 'Someone';
      final channelName = data['channelName'] ?? 'Channel';
      final autoPlay = data['autoPlay'] == 'true';

      if (audioUrl != null && autoPlay) {
        final service = BackgroundAudioService();
        service.playAudio(
          audioUrl: audioUrl,
          senderName: senderName,
          channelName: channelName,
        );
      }
    });

    // Handle notification taps when app is in background (but not killed)
    FirebaseMessaging.onMessageOpenedApp.listen((RemoteMessage message) {
      debugPrint('FCM: Message opened app from background: ${message.messageId}');
      debugPrint('FCM: Message data: ${message.data}');

      // Store channel ID for navigation
      final channelId = message.data['channelId'] as String?;
      if (channelId != null && channelId.isNotEmpty) {
        _pendingChannelId = channelId;
        debugPrint('FCM: Stored pending channelId from background: $channelId');
      }

      // Handle through PTT service
      fcmPttService.handleMessage(message);
    });
  }

  /// Show local notification when live broadcast starts while app is in foreground
  Future<void> _showLiveBroadcastNotification(RemoteMessage message) async {
    final speakerName = message.data['speakerName'] ?? 'Someone';
    final channelName = message.data['channelName'] ?? 'a channel';
    final channelId = message.data['channelId'] ?? '';

    const androidDetails = AndroidNotificationDetails(
      'voicely_live_channel',
      'Live Broadcasts',
      channelDescription: 'Notifications when someone is speaking',
      importance: Importance.max,
      priority: Priority.max,
      showWhen: true,
      autoCancel: true,
      playSound: true,
      enableVibration: true,
    );

    const iosDetails = DarwinNotificationDetails(
      presentAlert: true,
      presentBadge: true,
      presentSound: true,
    );

    const notificationDetails = NotificationDetails(
      android: androidDetails,
      iOS: iosDetails,
    );

    await flutterLocalNotificationsPlugin.show(
      channelId.hashCode,
      '$speakerName is speaking',
      'Tap to listen in $channelName',
      notificationDetails,
      payload: channelId,
    );
  }

  @override
  Widget build(BuildContext context) {
    final router = ref.watch(routerProvider);

    return MaterialApp.router(
      title: 'Voicely',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.lightTheme,
      darkTheme: AppTheme.darkTheme,
      themeMode: ThemeMode.dark,
      routerConfig: router,
    );
  }
}
