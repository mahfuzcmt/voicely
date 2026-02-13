import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../../../../core/services/background_ptt_service.dart';
import '../../../../core/services/native_audio_service.dart';
import '../../../../di/providers.dart';
import '../../../messaging/data/message_repository.dart';
import '../../data/audio_recording_service.dart';
import '../../data/audio_storage_service.dart';
import '../../data/live_streaming_service.dart';
import '../../data/websocket_signaling_service.dart';
import 'audio_providers.dart';

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
  });

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

  // Get Firebase ID token for authentication
  final token = await user.getIdToken();
  if (token == null) {
    return false;
  }

  // Connect if not already connected
  if (!wsService.isConnected) {
    return wsService.connect(token);
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
  Timer? _broadcastTimer;
  Timer? _autoStopTimer;
  bool _wakelockEnabled = false;
  bool _backgroundServiceStarted = false;

  // Audio recording fields for message archiving
  bool _isRecordingActive = false;
  DateTime? _recordingStartTime;

  /// Auto-stop broadcasting after 60 seconds to prevent accidental long broadcasts
  static const int _maxBroadcastDurationSeconds = 60;

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
    _autoConnect();
    // Register for app lifecycle events
    WidgetsBinding.instance.addObserver(this);
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
      await NativeAudioService.setAudioModeForVoiceChat();
      await NativeAudioService.setSpeakerOn(true);
    } catch (e) {
      debugPrint('LivePTT: Failed to reconfigure audio: $e');
    }

    // Reconnect WebSocket if disconnected
    if (!_wsService.isConnected) {
      debugPrint('LivePTT: WebSocket disconnected, reconnecting...');
      await reconnect();
    }
  }

  /// Setup listeners for state changes
  void _setupListeners() {
    // Listen to WebSocket connection state
    _connectionSubscription = _wsService.connectionState.listen((connState) {
      final newPttState = _mapConnectionToPttState(connState);
      state = state.copyWith(
        connectionState: connState,
        state: newPttState,
      );

      // Auto-join room when authenticated
      if (connState == WSConnectionState.authenticated) {
        _wsService.joinRoom(channelId);
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
  }

  /// Auto-connect to WebSocket server
  Future<void> _autoConnect() async {
    debugPrint('LivePTT: _autoConnect called for channel $channelId');

    // Start background service for keeping app alive when in background
    await _startBackgroundService();

    // Enable wakelock to prevent device from sleeping during PTT session
    await _enableWakelock();

    // CRITICAL: Request microphone permission first
    // WebRTC on Android needs this even for receiving audio
    debugPrint('LivePTT: Requesting microphone permission...');
    try {
      // This will trigger permission dialog if not granted
      final stream = await navigator.mediaDevices.getUserMedia({
        'audio': true,
        'video': false,
      });
      // Immediately stop the stream, we just needed the permission
      for (final track in stream.getTracks()) {
        await track.stop();
      }
      await stream.dispose();
      debugPrint('LivePTT: Microphone permission granted');
    } catch (e) {
      debugPrint('LivePTT: Microphone permission error: $e');
      // Don't block - permission might already be granted but getUserMedia failed
      // for another reason. Continue and let the actual streaming handle errors.
    }

    // Configure native audio for voice chat right away
    debugPrint('LivePTT: Pre-configuring native audio...');
    try {
      await NativeAudioService.setAudioModeForVoiceChat();
      debugPrint('LivePTT: Native audio pre-configured');
    } catch (e) {
      debugPrint('LivePTT: Native audio pre-config error: $e');
    }

    if (_wsService.isConnected) {
      debugPrint('LivePTT: Already connected, joining room');
      _wsService.joinRoom(channelId);
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
      final token = await user.getIdToken();
      debugPrint('LivePTT: Got token, length: ${token?.length ?? 0}');
      if (token != null) {
        // Get display name from Firebase user or Firestore
        String? displayName = user.displayName;
        if (displayName == null || displayName.isEmpty) {
          // Try to get from Firestore
          final userModel = await _ref.read(currentUserProvider.future);
          displayName = userModel?.displayName ?? userModel?.phoneNumber;
        }
        debugPrint('LivePTT: Connecting to WebSocket with displayName: $displayName');
        await _wsService.connect(token, displayName: displayName);
      } else {
        debugPrint('LivePTT: Token is null!');
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

    state = state.copyWith(state: LivePttState.requestingFloor);

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
  }

  /// Stop broadcasting (PTT released)
  Future<void> stopBroadcasting() async {
    if (!state.isBroadcasting && state.state != LivePttState.requestingFloor) {
      return;
    }

    await _streamingService.stopBroadcasting();
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

  /// Toggle mute state for incoming audio
  void toggleMute() {
    final newMuteState = !state.isMuted;
    state = state.copyWith(isMuted: newMuteState);

    // Mute/unmute audio tracks in the streaming service
    _streamingService.setMuted(newMuteState);

    debugPrint('LivePTT: Mute toggled to $newMuteState');
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
      } catch (_) {}
      return;
    }

    // Fire-and-forget upload
    () async {
      try {
        final audioRecordingService = _ref.read(audioRecordingServiceProvider);
        final audioStorageService = _ref.read(audioStorageServiceProvider);
        final messageRepo = _ref.read(messageRepositoryProvider);

        final audioFilePath = await audioRecordingService.stopRecording();
        if (audioFilePath == null) {
          debugPrint('LivePTT Recording: No audio file to upload');
          return;
        }

        debugPrint('LivePTT Recording: Uploading audio...');
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
        } catch (_) {
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
        debugPrint('LivePTT Recording: Error uploading/creating message: $e');
      }
    }();
  }

  /// Play remote audio stream
  Future<void> _playRemoteStream(MediaStream stream) async {
    debugPrint('LivePTT: Playing remote stream: ${stream.id}');

    // Ensure wakelock is enabled during playback
    await _enableWakelock();

    // Update background notification to show we're receiving audio
    if (state.currentSpeakerName != null) {
      _backgroundService.notifySpeaking(state.currentSpeakerName!, 'Channel');
    }

    // CRITICAL: Use native Android AudioManager for reliable audio routing
    debugPrint('LivePTT: Configuring native audio for playback...');
    try {
      // First, set up Android audio mode for voice communication
      final modeResult = await NativeAudioService.setAudioModeForVoiceChat();
      debugPrint('LivePTT: Native audio mode result: $modeResult');

      // Then enable speakerphone via native code
      final speakerResult = await NativeAudioService.setSpeakerOn(true);
      debugPrint('LivePTT: Native speakerphone result: $speakerResult');
    } catch (e) {
      debugPrint('LivePTT: Native audio setup error: $e');
    }

    // Configure audio session for receiving (Flutter layer)
    final audioManager = _ref.read(audioSessionProvider);
    await audioManager.configureForReceiving();
    await audioManager.activate();

    // Ensure all audio tracks are enabled FIRST
    for (final track in stream.getAudioTracks()) {
      track.enabled = true;
      debugPrint('LivePTT: Audio track ${track.id} enabled');
    }

    // Enable speakerphone via native Android + flutter_webrtc
    try {
      await NativeAudioService.setSpeakerOn(true);
      await Helper.setSpeakerphoneOn(true);
      debugPrint('LivePTT: Speakerphone enabled');
      // Single delay to let audio routing settle
      await Future.delayed(const Duration(milliseconds: 200));
    } catch (e) {
      debugPrint('LivePTT: Failed to enable speakerphone: $e');
    }

    // Also try to select audio output device explicitly
    try {
      // Get available audio output devices and select speaker
      final devices = await Helper.enumerateDevices('audiooutput');
      debugPrint('LivePTT: Available audio outputs: ${devices.length}');
      for (final device in devices) {
        debugPrint('LivePTT: Audio output: ${device.label} (${device.deviceId})');
        if (device.label.toLowerCase().contains('speaker')) {
          await Helper.selectAudioOutput(device.deviceId);
          debugPrint('LivePTT: Selected speaker output');
          break;
        }
      }
    } catch (e) {
      debugPrint('LivePTT: Failed to enumerate/select audio output: $e');
    }

    // Final check: log audio state
    try {
      final audioState = await NativeAudioService.getAudioState();
      debugPrint('LivePTT: Final audio state: $audioState');
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

  @override
  void dispose() {
    // Remove lifecycle observer
    WidgetsBinding.instance.removeObserver(this);

    _connectionSubscription?.cancel();
    _streamingStateSubscription?.cancel();
    _speakerSubscription?.cancel();
    _floorSubscription?.cancel();
    _remoteStreamSubscription?.cancel();
    _debugSubscription?.cancel();
    _stopBroadcastTimer();

    // Stop background service and disable wakelock
    _stopBackgroundService();
    _disableWakelock();

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

/// Provider for room members
final liveRoomMembersProvider =
    StreamProvider.family<List<WSRoomMember>, String>((ref, channelId) {
  final wsService = ref.watch(websocketSignalingServiceProvider);
  return wsService.roomMembers
      .where((event) => event.roomId == channelId)
      .map((event) => event.members);
});
