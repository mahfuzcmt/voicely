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

  // Audio settings - optimized for PTT with multiple devices
  static const int audioSampleRate = 16000; // Lower sample rate for voice
  static const int audioChannels = 1;
  static const int audioBitRate = 24000; // Lower bitrate for smoother multi-device

  // PTT settings
  static const Duration pttMinDuration = Duration(milliseconds: 300);
  static const Duration pttMaxDuration = Duration(minutes: 2);
  static const Duration floorRequestTimeout = Duration(seconds: 2); // Reduced from 5s for faster connection

  // WebRTC ICE servers configuration
  // IMPORTANT: Order matters! STUN first for direct connections, then TURN for relay
  // Using 'all' transport policy allows direct connections when possible
  static const List<Map<String, dynamic>> iceServers = [
    // Google STUN servers - for direct connections (fastest if both parties have good NAT)
    {
      'urls': [
        'stun:stun.l.google.com:19302',
        'stun:stun1.l.google.com:19302',
      ],
    },
    // Primary: Your coturn TURN server (relay when direct fails)
    // UDP only first for faster connection (no TCP fallback overhead)
    {
      'urls': [
        'turn:103.159.37.167:3478', // UDP first - fastest
      ],
      'username': 'voicely',
      'credential': 'VoicelyTurn2024Secure',
    },
    // Secondary: Same server with TCP/TLS fallback (only if UDP fails)
    {
      'urls': [
        'turn:103.159.37.167:3478?transport=tcp',
        'turns:voicelyent.xyz:5349', // TLS requires hostname for certificate validation
      ],
      'username': 'voicely',
      'credential': 'VoicelyTurn2024Secure',
    },
    // Fallback: OpenRelay public TURN server (if your server is down)
    {
      'urls': [
        'turn:openrelay.metered.ca:443',
        'turn:openrelay.metered.ca:443?transport=tcp',
      ],
      'username': 'openrelayproject',
      'credential': 'openrelayproject',
    },
  ];

  // Location settings
  static const Duration locationUpdateInterval = Duration(seconds: 30);
  static const double locationDistanceFilter = 10.0; // meters

  // UI settings
  static const Duration animationDuration = Duration(milliseconds: 300);
  static const double borderRadius = 12.0;
}
