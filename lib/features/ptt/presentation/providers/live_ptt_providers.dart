import 'dart:async';
import 'dart:io';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../../../../core/constants/app_constants.dart';
import '../../../../core/services/background_ptt_service.dart';
import '../../../../core/services/fcm_ptt_service.dart';
import '../../../../core/services/native_audio_service.dart';
import '../../../../core/services/native_websocket_service.dart';
import '../../../../di/providers.dart';
import '../../../channels/data/channel_repository.dart';
import '../../../messaging/data/message_repository.dart';
import '../../data/audio_recording_service.dart';
import '../../data/audio_storage_service.dart';
import '../../data/live_streaming_service.old.dart';
import '../../data/websocket_signaling_service.dart';

/// Token cache for faster reconnection
/// Firebase ID tokens are valid for 1 hour, so we cache with a 55-minute buffer
class _TokenCache {
  String? _token;
  DateTime? _fetchedAt;

  /// Get cached token if valid, otherwise fetch fresh
  Future<String?> getToken(User user, {bool forceRefresh = false}) async {
    // Check if we have a valid cached token (with 5-minute buffer before expiry)
    if (!forceRefresh &&
        _token != null &&
        _fetchedAt != null &&
        DateTime.now().difference(_fetchedAt!) < const Duration(minutes: 55)) {
      debugPrint('TokenCache: Using cached token (age: ${DateTime.now().difference(_fetchedAt!).inMinutes}m)');
      return _token;
    }

    // Fetch fresh token
    debugPrint('TokenCache: Fetching fresh token...');
    _token = await user.getIdToken(true);
    _fetchedAt = DateTime.now();
    debugPrint('TokenCache: Fresh token obtained');
    return _token;
  }

  /// Clear the cache (e.g., on logout)
  void clear() {
    _token = null;
    _fetchedAt = null;
  }
}

/// Global token cache instance
final _tokenCache = _TokenCache();

/// Live PTT state
enum LivePttState {
  /// Idle, ready to speak
  idle,

  /// Connecting to server
  connecting,

  /// Requesting floor
  requestingFloor,

  /// Broadcasting audio
  broadcasting,

  /// Listening to someone else
  listening,

  /// Error occurred
  error,

  /// Not connected to server
  disconnected,
}

/// Live PTT session state
class LivePttSessionState {
  final LivePttState state;
  final String? errorMessage;
  final DateTime? broadcastStartTime;
  final String? currentSpeakerId;
  final String? currentSpeakerName;
  final DateTime? floorExpiresAt;
  final WSConnectionState connectionState;
  final bool isMuted;
  // Debug info
  final int audioTracksReceived;
  final bool onTrackFired;
  final String? iceState;
  // Listener count when broadcasting (WebRTC connected)
  final int listenerCount;
  // Total room members (excluding self)
  final int totalRoomMembers;
  // Audio renderers for RTCVideoView consumption (required for audio playback)
  final Map<String, RTCVideoRenderer> audioRenderers;

  const LivePttSessionState({
    this.state = LivePttState.disconnected,
    this.errorMessage,
    this.broadcastStartTime,
    this.currentSpeakerId,
    this.currentSpeakerName,
    this.floorExpiresAt,
    this.connectionState = WSConnectionState.disconnected,
    this.isMuted = false,
    this.audioTracksReceived = 0,
    this.onTrackFired = false,
    this.iceState,
    this.listenerCount = 0,
    this.totalRoomMembers = 0,
    this.audioRenderers = const {},
  });

  /// Check if all room members are listening
  bool get allListening => listenerCount > 0 && listenerCount >= totalRoomMembers;

  /// Use a sentinel value to distinguish "not provided" from "set to null"
  static const _sentinel = Object();

  LivePttSessionState copyWith({
    LivePttState? state,
    Object? errorMessage = _sentinel,
    DateTime? broadcastStartTime,
    Object? currentSpeakerId = _sentinel,
    Object? currentSpeakerName = _sentinel,
    Object? floorExpiresAt = _sentinel,
    WSConnectionState? connectionState,
    bool? isMuted,
    int? audioTracksReceived,
    bool? onTrackFired,
    String? iceState,
    int? listenerCount,
    int? totalRoomMembers,
    Map<String, RTCVideoRenderer>? audioRenderers,
  }) {
    return LivePttSessionState(
      state: state ?? this.state,
      errorMessage: identical(errorMessage, _sentinel)
          ? this.errorMessage
          : errorMessage as String?,
      broadcastStartTime: broadcastStartTime ?? this.broadcastStartTime,
      currentSpeakerId: identical(currentSpeakerId, _sentinel)
          ? this.currentSpeakerId
          : currentSpeakerId as String?,
      currentSpeakerName: identical(currentSpeakerName, _sentinel)
          ? this.currentSpeakerName
          : currentSpeakerName as String?,
      floorExpiresAt: identical(floorExpiresAt, _sentinel)
          ? this.floorExpiresAt
          : floorExpiresAt as DateTime?,
      connectionState: connectionState ?? this.connectionState,
      isMuted: isMuted ?? this.isMuted,
      audioTracksReceived: audioTracksReceived ?? this.audioTracksReceived,
      onTrackFired: onTrackFired ?? this.onTrackFired,
      iceState: iceState ?? this.iceState,
      listenerCount: listenerCount ?? this.listenerCount,
      totalRoomMembers: totalRoomMembers ?? this.totalRoomMembers,
      audioRenderers: audioRenderers ?? this.audioRenderers,
    );
  }

  bool get canBroadcast =>
      state == LivePttState.idle && connectionState == WSConnectionState.authenticated;

  bool get isBroadcasting => state == LivePttState.broadcasting;
  bool get isListening => state == LivePttState.listening;
  bool get isConnected => connectionState == WSConnectionState.authenticated;
  bool get isConnecting =>
      connectionState == WSConnectionState.connecting ||
      connectionState == WSConnectionState.authenticating ||
      connectionState == WSConnectionState.reconnecting;

  Duration get broadcastDuration {
    if (broadcastStartTime == null) return Duration.zero;
    return DateTime.now().difference(broadcastStartTime!);
  }

  /// Remaining broadcast time before auto-stop (60 seconds max)
  int get remainingBroadcastSeconds {
    if (broadcastStartTime == null) return 60;
    final elapsed = DateTime.now().difference(broadcastStartTime!).inSeconds;
    return (60 - elapsed).clamp(0, 60);
  }

  /// Whether broadcast time is running low (less than 10 seconds)
  bool get isBroadcastTimeWarning => remainingBroadcastSeconds <= 10 && isBroadcasting;
}

/// Provider for WebSocket connection state
final wsConnectionStateProvider = StreamProvider<WSConnectionState>((ref) {
  final wsService = ref.watch(websocketSignalingServiceProvider);
  return wsService.connectionState;
});

/// Provider to initialize WebSocket connection
final wsConnectionProvider = FutureProvider<bool>((ref) async {
  final wsService = ref.watch(websocketSignalingServiceProvider);
  final user = await ref.watch(authStateProvider.future);

  if (user == null) {
    return false;
  }

  // Get FRESH Firebase ID token for authentication
  final token = await user.getIdToken(true);
  if (token == null) {
    return false;
  }

  // Connect if not already connected
  if (!wsService.isConnected) {
    // Pass displayName so other users see the full name
    return wsService.connect(token, displayName: user.displayName);
  }

  return true;
});

/// Live PTT session provider for each channel
/// NOT autoDispose - must survive widget rebuilds and app backgrounding
final livePttSessionProvider = StateNotifierProvider
    .family<LivePttSessionNotifier, LivePttSessionState, String>((ref, channelId) {
  final wsService = ref.watch(websocketSignalingServiceProvider);
  final streamingService = ref.watch(liveStreamingServiceProvider(channelId));

  return LivePttSessionNotifier(
    ref: ref,
    channelId: channelId,
    wsService: wsService,
    streamingService: streamingService,
  );
});

/// Live PTT session state notifier
class LivePttSessionNotifier extends StateNotifier<LivePttSessionState>
    with WidgetsBindingObserver {
  final Ref _ref;
  final String channelId;
  final WebSocketSignalingService _wsService;
  final LiveStreamingService _streamingService;
  final BackgroundPttService _backgroundService = BackgroundPttService();

  StreamSubscription? _connectionSubscription;
  StreamSubscription? _streamingStateSubscription;
  StreamSubscription? _speakerSubscription;
  StreamSubscription? _floorSubscription;
  StreamSubscription? _remoteStreamSubscription;
  StreamSubscription? _debugSubscription;
  StreamSubscription? _listenerCountSubscription;
  StreamSubscription? _listenerJoinedSubscription;
  StreamSubscription? _fcmBroadcastSubscription;
  StreamSubscription? _roomMembersSubscription;
  StreamSubscription? _nativeWsConnectionSubscription;
  StreamSubscription? _nativeWsMessageSubscription;
  StreamSubscription? _audioRendererSubscription;

  /// Callback to show toast when listener joins (set by UI)
  void Function(String listenerName)? onListenerJoined;
  Timer? _broadcastTimer;
  Timer? _autoStopTimer;
  bool _wakelockEnabled = false;
  bool _backgroundServiceStarted = false;
  bool _nativeServiceStarted = false;

  // FCM service for wake-up notifications
  final FcmPttService _fcmPttService = FcmPttService();

  // Audio recording fields for message archiving
  bool _isRecordingActive = false;
  DateTime? _recordingStartTime;

  /// Auto-stop broadcasting after 60 seconds to prevent accidental long broadcasts
  static const int _maxBroadcastDurationSeconds = 60;

  // Track if observer was successfully added
  bool _observerAdded = false;

  // Track if notifier has been disposed (StateNotifier doesn't have 'mounted')
  bool _isDisposed = false;

  LivePttSessionNotifier({
    required Ref ref,
    required this.channelId,
    required WebSocketSignalingService wsService,
    required LiveStreamingService streamingService,
  })  : _ref = ref,
        _wsService = wsService,
        _streamingService = streamingService,
        super(LivePttSessionState(
          connectionState: wsService.currentConnectionState,
          state: wsService.isConnected ? LivePttState.idle : LivePttState.disconnected,
        )) {
    _setupListeners();
    _setupFcmWakeUpHandler();
    _autoConnect();
    // Register for app lifecycle events safely
    try {
      WidgetsBinding.instance.addObserver(this);
      _observerAdded = true;
    } catch (e) {
      debugPrint('LivePTT: Failed to add lifecycle observer: $e');
    }
    // Check for pending FCM wake-up messages
    _checkPendingFcmMessage();
  }

  /// Set up FCM wake-up handler for this channel
  void _setupFcmWakeUpHandler() {
    // Set the callback for FCM wake-up
    _fcmPttService.onWakeUpForBroadcast = (fcmChannelId) async {
      if (fcmChannelId == channelId) {
        debugPrint('LivePTT: FCM wake-up for our channel $channelId');
        // Ensure we're connected and in the room
        if (!_wsService.isConnected) {
          debugPrint('LivePTT: Reconnecting for FCM wake-up...');
          await reconnect();
        }
        return _wsService.isConnected;
      }
      return false;
    };

    // Listen for live broadcast started notifications for this channel
    _fcmBroadcastSubscription = _fcmPttService.onLiveBroadcastStarted
        .where((msg) => msg.channelId == channelId)
        .listen((message) {
      debugPrint('LivePTT: FCM - Live broadcast started by ${message.speakerName}');
      // The WebSocket will receive the floor state change
      // This is just for ensuring connection is ready
    });
  }

  /// Pre-initialize local stream and audio for fast PTT connection
  /// Called when entering a room to have everything ready before PTT is pressed
  Future<void> _preInitializeForFastConnection() async {
    debugPrint('LivePTT: Pre-initializing for fast connection...');

    // Pre-initialize local audio stream (so it's ready when PTT is pressed)
    try {
      final streamReady = await _streamingService.preInitializeLocalStream();
      debugPrint('LivePTT: Local stream pre-initialized: $streamReady');
    } catch (e) {
      debugPrint('LivePTT: Failed to pre-initialize local stream: $e');
    }

    // Pre-configure audio for receiving (so listeners are ready instantly)
    try {
      await _streamingService.preConfigureAudioForReceiving();
      debugPrint('LivePTT: Audio pre-configured for receiving');
    } catch (e) {
      debugPrint('LivePTT: Failed to pre-configure audio: $e');
    }

    debugPrint('LivePTT: Pre-initialization complete');
  }

  /// Check for pending FCM messages when initializing
  Future<void> _checkPendingFcmMessage() async {
    final pendingMessage = await _fcmPttService.checkPendingMessage();
    if (pendingMessage != null && pendingMessage.channelId == channelId) {
      debugPrint('LivePTT: Found pending FCM message for channel $channelId');
      // Ensure we're connected
      if (!_wsService.isConnected) {
        await reconnect();
      }
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    debugPrint('LivePTT: App lifecycle changed to: $state');
    switch (state) {
      case AppLifecycleState.paused:
      case AppLifecycleState.inactive:
        // App went to background - ensure background service is running
        _onAppBackground();
        break;
      case AppLifecycleState.resumed:
        // App came to foreground - reconfigure audio
        _onAppForeground();
        break;
      case AppLifecycleState.detached:
      case AppLifecycleState.hidden:
        // App being closed
        break;
    }
  }

  /// Handle app going to background
  Future<void> _onAppBackground() async {
    debugPrint('LivePTT: App going to background, ensuring services are running');

    // Make sure background service is running
    await _startBackgroundService();

    // Keep wakelock enabled
    await _enableWakelock();

    // Update notification
    if (state.currentSpeakerName != null) {
      _backgroundService.notifySpeaking(state.currentSpeakerName!, 'Channel');
    } else {
      _backgroundService.notifyIdle();
    }
  }

  /// Handle app coming to foreground
  Future<void> _onAppForeground() async {
    debugPrint('LivePTT: App coming to foreground, reconfiguring audio');

    // Reconfigure audio for playback
    try {
      // Check Bluetooth status first
      final bluetoothStatus = await NativeAudioService.isBluetoothAudioConnected();
      final isBluetoothConnected = bluetoothStatus['isConnected'] as bool? ?? false;

      await NativeAudioService.setAudioModeForVoiceChat();

      // Force speaker ON only if no Bluetooth connected
      if (!isBluetoothConnected) {
        await NativeAudioService.setSpeakerOn(true);
        debugPrint('LivePTT: Speaker enabled (no Bluetooth)');
      } else {
        debugPrint('LivePTT: Using Bluetooth audio');
      }
    } catch (e) {
      debugPrint('LivePTT: Failed to reconfigure audio: $e');
    }

    // Always try to reconnect when coming to foreground
    // The WebSocket might have been disconnected while in background
    // even if the state hasn't been updated yet
    debugPrint('LivePTT: Checking WebSocket connection on foreground...');

    // Force a ping to check if connection is really alive
    if (_wsService.isConnected) {
      _wsService.sendPing();
      // Give it a brief moment to respond (reduced for faster detection)
      await Future.delayed(const Duration(milliseconds: 200));
    }

    // Reconnect if disconnected or if ping didn't get a response
    if (!_wsService.isConnected) {
      debugPrint('LivePTT: WebSocket disconnected, force reconnecting (fast mode)...');
      // Use force reconnect to ensure clean state (uses fast mode internally)
      await _wsService.forceReconnect();
      // Wait briefly for connection to establish
      await Future.delayed(const Duration(milliseconds: 300));
      // Join room after reconnecting
      if (_wsService.isConnected) {
        _wsService.joinRoom(channelId, rejoin: true);
      }
    } else {
      // Rejoin room to ensure we're still in it
      _wsService.joinRoom(channelId, rejoin: true);
    }

    // CRITICAL: Check and reconnect WebRTC peer connections if they're stale
    // This handles the case where WebSocket stayed connected (via native service)
    // but the WebRTC ICE connections timed out while backgrounded
    await _checkAndReconnectWebRtc();

    // If we're broadcasting, check and resend offers to any stale listeners
    if (state.isBroadcasting) {
      debugPrint('LivePTT: Broadcaster coming to foreground, checking listener connections');
      await _streamingService.resendOffersToStaleListeners();
    }
  }

  /// Check if WebRTC connections are stale and request reconnection if needed
  Future<void> _checkAndReconnectWebRtc() async {
    // Only relevant if we're supposed to be listening to someone
    final currentSpeakerId = _streamingService.currentSpeakerId;

    if (currentSpeakerId == null) {
      debugPrint('LivePTT: No current speaker, no WebRTC reconnect needed');
      return;
    }

    // Skip if we're the speaker
    if (currentSpeakerId == _wsService.userId) {
      debugPrint('LivePTT: We are the speaker, no WebRTC reconnect needed');
      return;
    }

    // Check if we have healthy peer connections
    if (_streamingService.hasHealthyPeerConnections()) {
      debugPrint('LivePTT: WebRTC connections are healthy');
      return;
    }

    // Peer connections are stale - clean them up
    debugPrint('LivePTT: WebRTC connections are stale, cleaning up...');
    await _streamingService.cleanupStalePeerConnections();

    // Update state to show we're reconnecting
    state = state.copyWith(
      iceState: 'Reconnecting...',
    );

    // Request the speaker to resend their offer
    debugPrint('LivePTT: Requesting WebRTC reconnect from speaker $currentSpeakerId');
    _streamingService.requestWebRtcReconnect();

    // Fallback: Leave and rejoin the room to trigger member_joined on broadcaster side
    // This works even if the server doesn't support the request_webrtc_offer message
    debugPrint('LivePTT: Also rejoining room to trigger broadcaster offer');
    _wsService.leaveRoom(channelId);
    await Future.delayed(const Duration(milliseconds: 100));
    _wsService.joinRoom(channelId, rejoin: true);
  }

  /// Setup listeners for state changes
  void _setupListeners() {
    // Setup background service ping callback
    _backgroundService.setOnBackgroundPing(() {
      debugPrint('LivePTT: Background ping received, sending WebSocket ping');
      if (_wsService.isConnected) {
        _wsService.sendPing();
      } else {
        debugPrint('LivePTT: Not connected, triggering reconnect from ping');
        _backgroundReconnect();
      }
    });

    // Setup background service reconnect callback
    _backgroundService.setOnReconnectRequest(() async {
      debugPrint('LivePTT: Background reconnect request received');
      await _backgroundReconnect();
    });

    // Listen to WebSocket connection state
    _connectionSubscription = _wsService.connectionState.listen((connState) {
      final newPttState = _mapConnectionToPttState(connState);
      state = state.copyWith(
        connectionState: connState,
        state: newPttState,
      );

      // Update background service with connection status
      final isConnected = connState == WSConnectionState.authenticated;
      _backgroundService.updateConnectionStatus(isConnected);
      if (!isConnected && connState == WSConnectionState.disconnected) {
        _backgroundService.notifyDisconnected();
      } else if (isConnected) {
        _backgroundService.notifyIdle();
      }

      // Auto-join room when authenticated
      if (connState == WSConnectionState.authenticated) {
        _wsService.joinRoom(channelId);
        // Pre-initialize for fast connection
        _preInitializeForFastConnection();
      }
    });

    // Listen to streaming state changes
    _streamingStateSubscription = _streamingService.stateStream.listen((streamState) {
      final newState = _mapStreamingToPttState(streamState);
      if (newState != state.state) {
        // If leaving broadcasting state and recording is active, stop + upload
        if (state.state == LivePttState.broadcasting &&
            newState != LivePttState.broadcasting &&
            _isRecordingActive) {
          _stopRecordingAndUpload();
        }

        state = state.copyWith(state: newState);

        if (newState == LivePttState.broadcasting) {
          state = state.copyWith(broadcastStartTime: DateTime.now());
          _startBroadcastTimer();
        } else {
          _stopBroadcastTimer();
        }
      }
    });

    // Listen to current speaker changes
    _speakerSubscription = _streamingService.currentSpeaker.listen((speaker) {
      debugPrint('LivePTT: Speaker changed - id: ${speaker.id}, name: ${speaker.name}');
      state = state.copyWith(
        currentSpeakerId: speaker.id,
        currentSpeakerName: speaker.name,
      );

      // Update background notification when speaker changes
      if (speaker.name != null && speaker.name!.isNotEmpty) {
        _backgroundService.notifySpeaking(speaker.name!, 'Channel');
      } else {
        _backgroundService.notifyIdle();
      }
    });

    // Listen to floor state from WebSocket
    _floorSubscription = _wsService.floorState.listen((event) {
      if (event.roomId != channelId) return;

      final floor = event.state;
      if (floor != null) {
        debugPrint('LivePTT: Floor state update - speakerId: ${floor.speakerId}, speakerName: ${floor.speakerName}');
        state = state.copyWith(
          currentSpeakerId: floor.speakerId,
          currentSpeakerName: floor.speakerName,
          floorExpiresAt: floor.expiresAt,
        );
      } else {
        debugPrint('LivePTT: Floor released - clearing speaker info');
        state = state.copyWith(
          currentSpeakerId: null,
          currentSpeakerName: null,
          floorExpiresAt: null,
        );
      }
    });

    // Listen for remote streams (audio playback)
    _remoteStreamSubscription = _streamingService.remoteStreamAdded.listen((stream) async {
      await _playRemoteStream(stream);
    });

    // Listen for debug state updates
    _debugSubscription = _streamingService.debugState.listen((debug) {
      state = state.copyWith(
        audioTracksReceived: debug.tracks,
        onTrackFired: debug.onTrack,
        iceState: debug.ice,
      );
    });

    // Listen for listener count updates when broadcasting (WebRTC connections)
    _listenerCountSubscription = _streamingService.listenerCountStream.listen((count) {
      debugPrint('LivePTT: WebRTC listener count: $count');
      state = state.copyWith(listenerCount: count);
    });

    // Listen for listener joined events (for toast notifications)
    _listenerJoinedSubscription = _streamingService.listenerJoinedStream.listen((listenerName) {
      debugPrint('LivePTT: Listener joined notification: $listenerName');
      // Invoke callback if set by UI
      onListenerJoined?.call(listenerName);
    });

    // Listen for room members changes - track total room members
    _roomMembersSubscription = _wsService.roomMembers.listen((event) {
      if (event.roomId != channelId) return;

      final members = event.members;
      // Count all members except self as total room members
      final currentUserId = _wsService.userId;
      final totalMembers = members.where((m) => m.userId != currentUserId).length;

      debugPrint('LivePTT: Room members updated: ${members.length} total, $totalMembers others');
      state = state.copyWith(totalRoomMembers: totalMembers);
    });

    // Listen for audio renderer updates - CRITICAL for audio playback
    // These renderers must be consumed by RTCVideoView widgets in the UI
    _audioRendererSubscription = _streamingService.audioRendererStream.listen((renderers) {
      debugPrint('LivePTT: Audio renderers updated: ${renderers.length} renderers');
      state = state.copyWith(audioRenderers: renderers);
    });

    // Initialize with current renderers (in case some were created before subscription)
    state = state.copyWith(audioRenderers: _streamingService.audioRenderers);
  }

  /// Timeout duration for initialization operations
  static const Duration _initTimeout = Duration(seconds: 10);
  static const Duration _connectionTimeout = Duration(seconds: 20);

  /// Auto-connect to WebSocket server with timeout protection
  Future<void> _autoConnect() async {
    debugPrint('LivePTT: _autoConnect called for channel $channelId');

    // Start background service with timeout
    try {
      await _startBackgroundService().timeout(
        _initTimeout,
        onTimeout: () => debugPrint('LivePTT: Background service start timed out'),
      );
    } catch (e) {
      debugPrint('LivePTT: Background service error: $e');
    }

    // Acquire partial wake lock to keep CPU running in background
    try {
      await BackgroundPttService.acquirePartialWakeLock();
    } catch (e) {
      debugPrint('LivePTT: Failed to acquire partial wake lock: $e');
    }

    // Start native WebSocket service for persistent background connection (Android only)
    if (Platform.isAndroid) {
      await _startNativeWebSocketService();
    }

    // Enable wakelock with timeout
    try {
      await _enableWakelock().timeout(
        _initTimeout,
        onTimeout: () => debugPrint('LivePTT: Wakelock enable timed out'),
      );
    } catch (e) {
      debugPrint('LivePTT: Wakelock error: $e');
    }

    // Request battery optimization exemption with timeout
    try {
      await _requestBatteryOptimizationExemption().timeout(
        _initTimeout,
        onTimeout: () => debugPrint('LivePTT: Battery optimization request timed out'),
      );
    } catch (e) {
      debugPrint('LivePTT: Battery optimization error: $e');
    }

    // CRITICAL: Request microphone permission first with timeout
    debugPrint('LivePTT: Requesting microphone permission...');
    try {
      final stream = await navigator.mediaDevices.getUserMedia({
        'audio': true,
        'video': false,
      }).timeout(
        _initTimeout,
        onTimeout: () => throw TimeoutException('Microphone permission timed out'),
      );
      // Immediately stop the stream, we just needed the permission
      for (final track in stream.getTracks()) {
        await track.stop();
      }
      await stream.dispose();
      debugPrint('LivePTT: Microphone permission granted');
    } catch (e) {
      debugPrint('LivePTT: Microphone permission error: $e');
      // Don't block - continue and let the actual streaming handle errors
    }

    // Configure native audio with timeout
    debugPrint('LivePTT: Pre-configuring native audio...');
    try {
      await NativeAudioService.setAudioModeForVoiceChat().timeout(
        _initTimeout,
        onTimeout: () {
          debugPrint('LivePTT: Native audio config timed out');
          return false;
        },
      );
      debugPrint('LivePTT: Native audio pre-configured');
    } catch (e) {
      debugPrint('LivePTT: Native audio pre-config error: $e');
    }

    if (_wsService.isConnected) {
      debugPrint('LivePTT: Already connected, joining room');
      _wsService.joinRoom(channelId);
      // Pre-initialize for fast connection
      _preInitializeForFastConnection();
      return;
    }

    final user = _ref.read(authStateProvider).value;
    if (user == null) {
      debugPrint('LivePTT: No user logged in');
      state = state.copyWith(
        state: LivePttState.error,
        errorMessage: 'Not logged in',
      );
      return;
    }

    debugPrint('LivePTT: User found: ${user.uid}, getting token...');
    state = state.copyWith(state: LivePttState.connecting);

    try {
      // Use cached token for faster connection (falls back to fresh if expired)
      final token = await _tokenCache.getToken(user).timeout(
        _initTimeout,
        onTimeout: () => throw TimeoutException('Token fetch timed out'),
      );
      debugPrint('LivePTT: Got token, length: ${token?.length ?? 0}');

      if (token != null) {
        // Get display name with timeout
        // DEBUG: Track all sources of displayName
        final firebaseDisplayName = user.displayName;
        debugPrint('LivePTT: Firebase Auth displayName="${firebaseDisplayName}" (length=${firebaseDisplayName?.length ?? 0})');

        String? displayName = firebaseDisplayName;
        if (displayName == null || displayName.isEmpty) {
          debugPrint('LivePTT: Firebase displayName empty, fetching from Firestore...');
          try {
            final userModel = await _ref.read(currentUserProvider.future).timeout(
              _initTimeout,
              onTimeout: () => null,
            );
            debugPrint('LivePTT: Firestore userModel.displayName="${userModel?.displayName}" (length=${userModel?.displayName?.length ?? 0})');
            debugPrint('LivePTT: Firestore userModel.phoneNumber="${userModel?.phoneNumber}"');
            displayName = userModel?.displayName ?? userModel?.phoneNumber;
          } catch (e) {
            debugPrint('LivePTT: Failed to get display name from Firestore: $e');
          }
        }

        debugPrint('LivePTT: FINAL displayName to send="${displayName}" (length=${displayName?.length ?? 0})');
        await _wsService.connect(token, displayName: displayName).timeout(
          _connectionTimeout,
          onTimeout: () {
            debugPrint('LivePTT: WebSocket connection timed out');
            return false;
          },
        );
      } else {
        debugPrint('LivePTT: Token is null!');
        state = state.copyWith(
          state: LivePttState.error,
          errorMessage: 'Failed to get auth token',
        );
      }
    } catch (e) {
      debugPrint('LivePTT: Connection error: $e');
      state = state.copyWith(
        state: LivePttState.error,
        errorMessage: 'Failed to connect: $e',
      );
    }
  }

  /// Start broadcasting (PTT pressed)
  Future<bool> startBroadcasting() async {
    if (!state.canBroadcast) {
      debugPrint('Cannot broadcast: state=${state.state}, connected=${state.isConnected}');
      return false;
    }

    // Check if channel is active (billing check)
    try {
      final channelRepo = _ref.read(channelRepositoryProvider);
      final channel = await channelRepo.getChannelById(channelId);
      if (channel == null) {
        debugPrint('LivePTT: Channel not found');
        state = state.copyWith(
          state: LivePttState.error,
          errorMessage: 'Channel not found',
        );
        return false;
      }
      if (!channel.isActive) {
        debugPrint('LivePTT: Channel is inactive (billing)');
        state = state.copyWith(
          state: LivePttState.error,
          errorMessage: 'Channel is inactive. Contact administrator.',
        );
        return false;
      }
    } catch (e) {
      debugPrint('LivePTT: Error checking channel status: $e');
      // Allow broadcast if we can't check - don't block on network errors
    }

    state = state.copyWith(state: LivePttState.requestingFloor);

    try {
      final success = await _streamingService.startBroadcasting();
      if (!success) {
        state = state.copyWith(
          state: LivePttState.error,
          errorMessage: 'Failed to start broadcasting',
        );
        return false;
      }

      // Start local recording for message archiving (non-blocking)
      _startLocalRecording();

      return true;
    } catch (e) {
      debugPrint('LivePTT: Exception during startBroadcasting: $e');
      state = state.copyWith(
        state: LivePttState.error,
        errorMessage: 'Broadcasting error',
      );
      return false;
    }
  }

  /// Stop broadcasting (PTT released)
  Future<void> stopBroadcasting() async {
    if (!state.isBroadcasting && state.state != LivePttState.requestingFloor) {
      return;
    }

    try {
      await _streamingService.stopBroadcasting();
    } catch (e) {
      debugPrint('LivePTT: Error stopping broadcast: $e');
    }
    _stopBroadcastTimer();

    // Stop recording and upload (fire-and-forget)
    _stopRecordingAndUpload();

    state = state.copyWith(
      state: LivePttState.idle,
      broadcastStartTime: null,
    );
  }

  /// Cancel broadcasting (PTT cancelled)
  Future<void> cancelBroadcasting() async {
    await stopBroadcasting();
  }

  /// Reconnect to server
  Future<void> reconnect() async {
    if (_wsService.isConnected) return;
    await _autoConnect();
  }

  /// Start the native Android WebSocket service for persistent background connection
  Future<void> _startNativeWebSocketService() async {
    if (_nativeServiceStarted) return;

    try {
      final user = _ref.read(authStateProvider).value;
      if (user == null) {
        debugPrint('LivePTT: Cannot start native WS service - no user');
        return;
      }

      final token = await _tokenCache.getToken(user);
      if (token == null) {
        debugPrint('LivePTT: Cannot start native WS service - no token');
        return;
      }

      String? displayName = user.displayName;
      if (displayName == null || displayName.isEmpty) {
        try {
          final userModel = await _ref.read(currentUserProvider.future);
          displayName = userModel?.displayName ?? userModel?.phoneNumber;
        } catch (e) {
          debugPrint('LivePTT: Failed to get display name for native service: $e');
        }
      }

      final nativeService = NativeWebSocketService.instance;

      // Listen to connection state from native service
      _nativeWsConnectionSubscription?.cancel();
      _nativeWsConnectionSubscription = nativeService.connectionState.listen((isConnected) {
        debugPrint('LivePTT: Native WS connection state: $isConnected');
        // Update background service notification
        if (isConnected) {
          _backgroundService.notifyIdle();
        } else {
          _backgroundService.notifyDisconnected();
        }
      });

      // Listen to messages from native service and forward to Flutter WebSocket handlers
      _nativeWsMessageSubscription?.cancel();
      _nativeWsMessageSubscription = nativeService.messages.listen((message) {
        debugPrint('LivePTT: Native WS message: ${message['type']}');
        // Messages are handled by the native service for notifications
        // WebRTC signaling still goes through Flutter WebSocket when app is active
      });

      // Start the native service
      final started = await nativeService.startService(
        serverUrl: AppConstants.signalingServerUrl,
        authToken: token,
        displayName: displayName,
        roomId: channelId,
      );

      _nativeServiceStarted = started;
      debugPrint('LivePTT: Native WebSocket service started: $started');
    } catch (e) {
      debugPrint('LivePTT: Failed to start native WS service: $e');
    }
  }

  /// Stop the native WebSocket service
  Future<void> _stopNativeWebSocketService() async {
    if (!_nativeServiceStarted) return;

    try {
      _nativeWsConnectionSubscription?.cancel();
      _nativeWsConnectionSubscription = null;
      _nativeWsMessageSubscription?.cancel();
      _nativeWsMessageSubscription = null;

      await NativeWebSocketService.instance.stopService();
      _nativeServiceStarted = false;
      debugPrint('LivePTT: Native WebSocket service stopped');
    } catch (e) {
      debugPrint('LivePTT: Failed to stop native WS service: $e');
    }
  }

  /// Background reconnect - called from background service when connection is lost
  /// Uses fast mode and cached token for quick reconnection
  Future<void> _backgroundReconnect() async {
    if (_wsService.isConnected) {
      debugPrint('LivePTT: Background reconnect skipped - already connected');
      return;
    }

    debugPrint('LivePTT: Background reconnect starting...');

    try {
      final user = _ref.read(authStateProvider).value;
      if (user == null) {
        debugPrint('LivePTT: Background reconnect failed - no user');
        return;
      }

      // Use cached token for fast reconnection
      final token = await _tokenCache.getToken(user);
      if (token == null) {
        debugPrint('LivePTT: Background reconnect failed - no token');
        return;
      }

      // Get display name
      String? displayName = user.displayName;
      if (displayName == null || displayName.isEmpty) {
        try {
          final userModel = await _ref.read(currentUserProvider.future);
          displayName = userModel?.displayName ?? userModel?.phoneNumber;
        } catch (e) {
          debugPrint('LivePTT: Background reconnect - failed to get display name: $e');
        }
      }

      // Connect with fast mode
      final connected = await _wsService.connect(token, displayName: displayName, fastMode: true);

      if (connected) {
        debugPrint('LivePTT: Background reconnect successful, joining room');
        _wsService.joinRoom(channelId, rejoin: true);
      } else {
        debugPrint('LivePTT: Background reconnect failed');
      }
    } catch (e) {
      debugPrint('LivePTT: Background reconnect error: $e');
    }
  }

  /// Toggle mute state for incoming audio
  void toggleMute() {
    final newMuteState = !state.isMuted;
    state = state.copyWith(isMuted: newMuteState);

    // Mute/unmute audio tracks in the streaming service
    _streamingService.setMuted(newMuteState);

    debugPrint('LivePTT: Mute toggled to $newMuteState');
  }

  /// Force stop the current broadcast - can be used by any user to stop
  /// someone who forgot to release the floor
  Future<void> forceStopCurrentBroadcast() async {
    debugPrint('LivePTT: Force stopping current broadcast');

    // Send release floor command to the server
    _wsService.releaseFloor(channelId);

    // CRITICAL: Close all WebRTC peer connections to stop audio
    await _streamingService.forceStopAllConnections();

    // Clear the current speaker state locally
    state = state.copyWith(
      currentSpeakerId: null,
      currentSpeakerName: null,
      floorExpiresAt: null,
      state: LivePttState.idle,
    );

    // Update background notification
    _backgroundService.notifyIdle();
  }

  /// Map connection state to PTT state
  LivePttState _mapConnectionToPttState(WSConnectionState connState) {
    switch (connState) {
      case WSConnectionState.disconnected:
        return LivePttState.disconnected;
      case WSConnectionState.connecting:
      case WSConnectionState.connected:
      case WSConnectionState.authenticating:
      case WSConnectionState.reconnecting:
        return LivePttState.connecting;
      case WSConnectionState.authenticated:
        return state.isBroadcasting ? LivePttState.broadcasting : LivePttState.idle;
      case WSConnectionState.error:
        return LivePttState.error;
    }
  }

  /// Map streaming state to PTT state
  LivePttState _mapStreamingToPttState(LiveStreamingState streamState) {
    switch (streamState) {
      case LiveStreamingState.idle:
        return state.isConnected ? LivePttState.idle : LivePttState.disconnected;
      case LiveStreamingState.connecting:
        return LivePttState.requestingFloor;
      case LiveStreamingState.broadcasting:
        return LivePttState.broadcasting;
      case LiveStreamingState.listening:
        return LivePttState.listening;
      case LiveStreamingState.error:
        return LivePttState.error;
    }
  }

  /// Start local recording for message archiving
  void _startLocalRecording() {
    try {
      final audioRecordingService = _ref.read(audioRecordingServiceProvider);
      audioRecordingService.hasPermission().then((hasPermission) async {
        if (!hasPermission) {
          debugPrint('LivePTT Recording: No microphone permission for archiving');
          return;
        }
        final started = await audioRecordingService.startRecording();
        if (started) {
          _isRecordingActive = true;
          _recordingStartTime = DateTime.now();
          debugPrint('LivePTT Recording: Local recording started for archiving');
        } else {
          debugPrint('LivePTT Recording: Failed to start local recording');
        }
      });
    } catch (e) {
      debugPrint('LivePTT Recording: Error starting local recording: $e');
    }
  }

  /// Stop recording and upload to Firebase Storage, then create message
  void _stopRecordingAndUpload() {
    if (!_isRecordingActive) return;
    _isRecordingActive = false;

    final recordingStart = _recordingStartTime;
    _recordingStartTime = null;

    // Calculate duration
    int durationSeconds = 0;
    if (recordingStart != null) {
      durationSeconds = DateTime.now().difference(recordingStart).inSeconds;
    }

    // Skip very short recordings (accidental taps)
    if (durationSeconds < 1) {
      debugPrint('LivePTT Recording: Skipping short recording (${durationSeconds}s)');
      try {
        _ref.read(audioRecordingServiceProvider).cancelRecording();
      } catch (e) {
        // Log but continue - cancelling a short recording is not critical
        debugPrint('LivePTT Recording: Error cancelling short recording: $e');
      }
      return;
    }

    // Upload with retry logic
    _uploadRecordingWithRetry(durationSeconds);
  }

  /// Upload recording with retry logic (max 3 attempts with exponential backoff)
  Future<void> _uploadRecordingWithRetry(int durationSeconds, {int attempt = 1}) async {
    // Check if disposed before starting
    if (_isDisposed) {
      debugPrint('LivePTT Recording: Notifier disposed, skipping upload');
      return;
    }

    const maxAttempts = 3;

    try {
      final audioRecordingService = _ref.read(audioRecordingServiceProvider);
      final audioStorageService = _ref.read(audioStorageServiceProvider);
      final messageRepo = _ref.read(messageRepositoryProvider);

      final audioFilePath = await audioRecordingService.stopRecording();
      if (audioFilePath == null) {
        debugPrint('LivePTT Recording: No audio file to upload');
        return;
      }

      debugPrint('LivePTT Recording: Uploading audio (attempt $attempt/$maxAttempts)...');
      final audioUrl = await audioStorageService.uploadAudio(
        filePath: audioFilePath,
        channelId: channelId,
      );

      // Get current user info
      final currentUser = _ref.read(authStateProvider).value;
      if (currentUser == null) {
        debugPrint('LivePTT Recording: No user, skipping message creation');
        return;
      }

      String senderName;
      String? senderPhotoUrl;
      try {
        final userProfile = await _ref.read(currentUserProvider.future);
        senderName = userProfile?.displayName ??
            currentUser.displayName ??
            'User';
        senderPhotoUrl = userProfile?.photoUrl;
      } catch (e) {
        // Log the error but continue with fallback - getting user profile is not critical
        debugPrint('LivePTT Recording: Error getting user profile: $e');
        senderName = currentUser.displayName ?? 'User';
        senderPhotoUrl = null;
      }

      await messageRepo.sendAudioMessage(
        channelId: channelId,
        senderId: currentUser.uid,
        senderName: senderName,
        senderPhotoUrl: senderPhotoUrl,
        audioUrl: audioUrl,
        durationSeconds: durationSeconds,
      );
      debugPrint('LivePTT Recording: Message created successfully');
    } catch (e) {
      debugPrint('LivePTT Recording: Error uploading/creating message (attempt $attempt): $e');

      // Retry with exponential backoff
      if (attempt < maxAttempts && !_isDisposed) {
        final delay = Duration(seconds: 1 << (attempt - 1)); // 1s, 2s, 4s
        debugPrint('LivePTT Recording: Retrying in ${delay.inSeconds}s...');
        await Future.delayed(delay);
        // Check if disposed again after delay
        if (_isDisposed) {
          debugPrint('LivePTT Recording: Notifier disposed during retry delay');
          return;
        }
        await _uploadRecordingWithRetry(durationSeconds, attempt: attempt + 1);
      } else if (!_isDisposed) {
        debugPrint('LivePTT Recording: Max retry attempts reached, giving up');
        // Update state to show error (optional - notify user)
        state = state.copyWith(
          errorMessage: 'Failed to save voice message',
        );
        // Clear error after 3 seconds
        Future.delayed(const Duration(seconds: 3), () {
          if (!_isDisposed && state.errorMessage == 'Failed to save voice message') {
            state = state.copyWith(errorMessage: null);
          }
        });
      }
    }
  }

  /// Play remote audio stream
  /// Note: Audio is already configured in LiveStreamingService before peer connection
  /// This method just handles UI-level concerns
  Future<void> _playRemoteStream(MediaStream stream) async {
    debugPrint('LivePTT: Remote stream received: ${stream.id}');

    // Validate stream has audio tracks
    final audioTracks = stream.getAudioTracks();
    if (audioTracks.isEmpty) {
      debugPrint('LivePTT: WARNING - Remote stream has no audio tracks!');
      return;
    }

    // Validate at least one track is not ended
    final activeTracks = audioTracks.where((t) => t.enabled || !(t.muted ?? false)).toList();
    if (activeTracks.isEmpty) {
      debugPrint('LivePTT: WARNING - All audio tracks are disabled/muted');
    }

    // Ensure wakelock is enabled during playback
    await _enableWakelock();

    // Update background notification to show we're receiving audio
    if (state.currentSpeakerName != null) {
      _backgroundService.notifySpeaking(state.currentSpeakerName!, 'Channel');
    }

    // Audio tracks are already enabled in LiveStreamingService.onTrack
    // Just log the state for debugging - DO NOT modify track.enabled here
    // to avoid conflicts with the mute state managed by LiveStreamingService
    for (final track in audioTracks) {
      debugPrint('LivePTT: Audio track ${track.id} state: enabled=${track.enabled}, muted=${track.muted}');
    }

    // Log audio state for debugging
    try {
      final audioState = await NativeAudioService.getAudioState();
      debugPrint('LivePTT: Audio state: $audioState');
    } catch (e) {
      debugPrint('LivePTT: Failed to get audio state: $e');
    }

    debugPrint('LivePTT: Remote audio should now be playing');
  }

  /// Start timer to track broadcast duration
  void _startBroadcastTimer() {
    _stopBroadcastTimer();

    // Duration update timer (every second)
    _broadcastTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      // Check if disposed before updating state
      if (_isDisposed) {
        _stopBroadcastTimer();
        return;
      }
      // Trigger rebuild to update duration display
      state = state.copyWith(
        state: LivePttState.broadcasting,
        broadcastStartTime: state.broadcastStartTime,
      );
    });

    // Auto-stop timer after 60 seconds
    _autoStopTimer = Timer(
      const Duration(seconds: _maxBroadcastDurationSeconds),
      () {
        // Check if disposed before stopping
        if (_isDisposed) return;
        debugPrint('LivePTT: Auto-stopping broadcast after $_maxBroadcastDurationSeconds seconds');
        stopBroadcasting();
      },
    );
  }

  /// Stop broadcast duration timer
  void _stopBroadcastTimer() {
    _broadcastTimer?.cancel();
    _broadcastTimer = null;
    _autoStopTimer?.cancel();
    _autoStopTimer = null;
  }

  /// Clear error state
  void clearError() {
    if (state.state == LivePttState.error) {
      state = state.copyWith(
        state: state.isConnected ? LivePttState.idle : LivePttState.disconnected,
        errorMessage: null,
      );
    }
  }

  /// Start background service for keeping connections alive
  Future<void> _startBackgroundService() async {
    if (_backgroundServiceStarted) return;

    try {
      debugPrint('LivePTT: Starting background service...');
      await _backgroundService.initialize();
      await _backgroundService.start();
      _backgroundServiceStarted = true;
      debugPrint('LivePTT: Background service started');
    } catch (e) {
      debugPrint('LivePTT: Failed to start background service: $e');
    }
  }

  /// Stop background service
  Future<void> _stopBackgroundService() async {
    if (!_backgroundServiceStarted) return;

    try {
      debugPrint('LivePTT: Stopping background service...');
      await _backgroundService.stop();
      _backgroundServiceStarted = false;
      debugPrint('LivePTT: Background service stopped');
    } catch (e) {
      debugPrint('LivePTT: Failed to stop background service: $e');
    }
  }

  /// Enable wakelock to keep CPU awake during PTT session
  Future<void> _enableWakelock() async {
    if (_wakelockEnabled) return;

    try {
      debugPrint('LivePTT: Enabling wakelock...');
      await WakelockPlus.enable();
      _wakelockEnabled = true;
      debugPrint('LivePTT: Wakelock enabled');
    } catch (e) {
      debugPrint('LivePTT: Failed to enable wakelock: $e');
    }
  }

  /// Disable wakelock
  Future<void> _disableWakelock() async {
    if (!_wakelockEnabled) return;

    try {
      debugPrint('LivePTT: Disabling wakelock...');
      await WakelockPlus.disable();
      _wakelockEnabled = false;
      debugPrint('LivePTT: Wakelock disabled');
    } catch (e) {
      debugPrint('LivePTT: Failed to disable wakelock: $e');
    }
  }

  /// Request battery optimization exemption for background connection
  Future<void> _requestBatteryOptimizationExemption() async {
    try {
      final isDisabled = await NativeAudioService.isBatteryOptimizationDisabled();
      if (!isDisabled) {
        debugPrint('LivePTT: Battery optimization is enabled, requesting exemption...');
        await NativeAudioService.requestDisableBatteryOptimization();
      } else {
        debugPrint('LivePTT: Battery optimization already disabled');
      }
    } catch (e) {
      debugPrint('LivePTT: Failed to check/request battery optimization: $e');
    }
  }

  @override
  void dispose() {
    // Mark as disposed first to prevent any pending async operations from modifying state
    _isDisposed = true;

    // Remove lifecycle observer safely
    if (_observerAdded) {
      try {
        WidgetsBinding.instance.removeObserver(this);
        _observerAdded = false;
      } catch (e) {
        debugPrint('LivePTT: Failed to remove lifecycle observer: $e');
      }
    }

    // Cancel all subscriptions
    _connectionSubscription?.cancel();
    _connectionSubscription = null;
    _streamingStateSubscription?.cancel();
    _streamingStateSubscription = null;
    _speakerSubscription?.cancel();
    _speakerSubscription = null;
    _floorSubscription?.cancel();
    _floorSubscription = null;
    _remoteStreamSubscription?.cancel();
    _remoteStreamSubscription = null;
    _debugSubscription?.cancel();
    _debugSubscription = null;
    _listenerCountSubscription?.cancel();
    _listenerCountSubscription = null;
    _listenerJoinedSubscription?.cancel();
    _listenerJoinedSubscription = null;
    _roomMembersSubscription?.cancel();
    _roomMembersSubscription = null;
    _audioRendererSubscription?.cancel();
    _audioRendererSubscription = null;
    _fcmBroadcastSubscription?.cancel();
    _fcmBroadcastSubscription = null;
    _nativeWsConnectionSubscription?.cancel();
    _nativeWsConnectionSubscription = null;
    _nativeWsMessageSubscription?.cancel();
    _nativeWsMessageSubscription = null;
    // Clear FCM wake-up callback
    _fcmPttService.onWakeUpForBroadcast = null;
    _stopBroadcastTimer();

    // Stop native WebSocket service (Android)
    if (Platform.isAndroid) {
      _stopNativeWebSocketService();
    }

    // Stop background service and disable wakelock
    _stopBackgroundService();
    _disableWakelock();

    // Release partial wake lock
    BackgroundPttService.releasePartialWakeLock();

    // Leave room on dispose
    if (_wsService.isConnected) {
      _wsService.leaveRoom(channelId);
    }

    super.dispose();
  }
}

/// Provider for current speaker in a channel
final liveCurrentSpeakerProvider =
    Provider.family<({String? id, String? name}), String>((ref, channelId) {
  final session = ref.watch(livePttSessionProvider(channelId));
  return (id: session.currentSpeakerId, name: session.currentSpeakerName);
});

/// Provider for checking if current user is the speaker
final isCurrentUserSpeakingLiveProvider =
    Provider.family<bool, String>((ref, channelId) {
  final session = ref.watch(livePttSessionProvider(channelId));
  final wsService = ref.watch(websocketSignalingServiceProvider);
  return session.currentSpeakerId == wsService.userId && session.isBroadcasting;
});

/// Provider for room members - combines initial cached value with stream updates
final liveRoomMembersProvider =
    StreamProvider.family<List<WSRoomMember>, String>((ref, channelId) {
  final wsService = ref.watch(websocketSignalingServiceProvider);

  // Create a stream that starts with the current cached members
  // then updates whenever the stream emits new values for this room
  return Stream.multi((controller) {
    // First, emit the current cached members immediately
    final initialMembers = wsService.getRoomMembers(channelId);
    if (initialMembers.isNotEmpty) {
      controller.add(initialMembers);
    }

    // Then listen to stream updates
    final subscription = wsService.roomMembers
        .where((event) => event.roomId == channelId)
        .map((event) => event.members)
        .listen(
          controller.add,
          onError: controller.addError,
          onDone: controller.close,
        );

    controller.onCancel = () {
      subscription.cancel();
    };
  });
});
