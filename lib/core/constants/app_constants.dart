class AppConstants {
  AppConstants._();

  static const String appName = 'Voicely';
  static const String appVersion = '1.0.0';

  // WebSocket signaling server
  // Development (Android emulator): ws://10.0.2.2:8080
  // Development (iOS simulator): ws://localhost:8080
  // Production: wss://voicelyent.xyz
  // Local testing (physical device): ws://192.168.1.41:8080
  static const String signalingServerUrl = String.fromEnvironment(
    'SIGNALING_SERVER_URL',
    defaultValue: 'wss://voicelyent.xyz',
  );

  // Live streaming settings
  static const bool useLiveStreaming = true; // Set to false to use record-upload mode
  static const Duration floorMaxDuration = Duration(minutes: 2);

  // Firestore collections
  static const String usersCollection = 'users';
  static const String channelsCollection = 'channels';
  static const String messagesCollection = 'messages';
  static const String locationsCollection = 'locations';
  static const String audioHistoryCollection = 'audioHistory';

  // Audio settings
  static const int audioSampleRate = 48000;
  static const int audioChannels = 1;
  static const int audioBitRate = 64000;

  // PTT settings
  static const Duration pttMinDuration = Duration(milliseconds: 300);
  static const Duration pttMaxDuration = Duration(minutes: 2);
  static const Duration floorRequestTimeout = Duration(seconds: 5);

  // WebRTC ICE servers configuration
  // Using your own coturn server on voicelyent.xyz
  static const List<Map<String, dynamic>> iceServers = [
    // Your STUN server
    {
      'urls': 'stun:103.159.37.167:3478',
    },
    // Google STUN servers (backup)
    {
      'urls': [
        'stun:stun.l.google.com:19302',
        'stun:stun1.l.google.com:19302',
      ],
    },
    // Your TURN server (UDP)
    {
      'urls': 'turn:103.159.37.167:3478',
      'username': 'voicely',
      'credential': 'VoicelyTurn2024Secure',
    },
    // Your TURN server (TCP)
    {
      'urls': 'turn:103.159.37.167:3478?transport=tcp',
      'username': 'voicely',
      'credential': 'VoicelyTurn2024Secure',
    },
  ];

  // Location settings
  static const Duration locationUpdateInterval = Duration(seconds: 30);
  static const double locationDistanceFilter = 10.0; // meters

  // UI settings
  static const Duration animationDuration = Duration(milliseconds: 300);
  static const double borderRadius = 12.0;
}
