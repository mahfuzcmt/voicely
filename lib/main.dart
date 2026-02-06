import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'core/router/app_router.dart';
import 'core/services/background_audio_service.dart';
import 'core/theme/app_theme.dart';
import 'firebase_options.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Initialize Firebase
  await Firebase.initializeApp(
    options: DefaultFirebaseOptions.currentPlatform,
  );

  // Initialize FCM background handler
  FirebaseMessaging.onBackgroundMessage(firebaseMessagingBackgroundHandler);

  // Initialize background audio service
  final backgroundService = BackgroundAudioService();
  await backgroundService.initialize();

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
  }

  void _setupFCMListeners() {
    // Handle foreground messages
    FirebaseMessaging.onMessage.listen((RemoteMessage message) {
      debugPrint('FCM: Foreground message received: ${message.messageId}');

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

    // Handle notification taps when app is in background
    FirebaseMessaging.onMessageOpenedApp.listen((RemoteMessage message) {
      debugPrint('FCM: Message opened app: ${message.messageId}');
      // Navigate to channel if needed
    });
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
