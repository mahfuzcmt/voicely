import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

import '../../../../di/providers.dart';
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

  const LivePttSessionState({
    this.state = LivePttState.disconnected,
    this.errorMessage,
    this.broadcastStartTime,
    this.currentSpeakerId,
    this.currentSpeakerName,
    this.floorExpiresAt,
    this.connectionState = WSConnectionState.disconnected,
  });

  LivePttSessionState copyWith({
    LivePttState? state,
    String? errorMessage,
    DateTime? broadcastStartTime,
    String? currentSpeakerId,
    String? currentSpeakerName,
    DateTime? floorExpiresAt,
    WSConnectionState? connectionState,
  }) {
    return LivePttSessionState(
      state: state ?? this.state,
      errorMessage: errorMessage,
      broadcastStartTime: broadcastStartTime ?? this.broadcastStartTime,
      currentSpeakerId: currentSpeakerId,
      currentSpeakerName: currentSpeakerName,
      floorExpiresAt: floorExpiresAt,
      connectionState: connectionState ?? this.connectionState,
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
final livePttSessionProvider = StateNotifierProvider.autoDispose
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
class LivePttSessionNotifier extends StateNotifier<LivePttSessionState> {
  final Ref _ref;
  final String channelId;
  final WebSocketSignalingService _wsService;
  final LiveStreamingService _streamingService;

  StreamSubscription? _connectionSubscription;
  StreamSubscription? _streamingStateSubscription;
  StreamSubscription? _speakerSubscription;
  StreamSubscription? _floorSubscription;
  StreamSubscription? _remoteStreamSubscription;
  Timer? _broadcastTimer;

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
      state = state.copyWith(
        currentSpeakerId: speaker.id,
        currentSpeakerName: speaker.name,
      );
    });

    // Listen to floor state from WebSocket
    _floorSubscription = _wsService.floorState.listen((event) {
      if (event.roomId != channelId) return;

      final floor = event.state;
      if (floor != null) {
        state = state.copyWith(
          currentSpeakerId: floor.speakerId,
          currentSpeakerName: floor.speakerName,
          floorExpiresAt: floor.expiresAt,
        );
      } else {
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
  }

  /// Auto-connect to WebSocket server
  Future<void> _autoConnect() async {
    debugPrint('LivePTT: _autoConnect called for channel $channelId');

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
        debugPrint('LivePTT: Connecting to WebSocket...');
        await _wsService.connect(token);
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

    return true;
  }

  /// Stop broadcasting (PTT released)
  Future<void> stopBroadcasting() async {
    if (!state.isBroadcasting && state.state != LivePttState.requestingFloor) {
      return;
    }

    await _streamingService.stopBroadcasting();
    _stopBroadcastTimer();

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

  /// Play remote audio stream
  Future<void> _playRemoteStream(MediaStream stream) async {
    debugPrint('LivePTT: Playing remote stream: ${stream.id}');

    // Configure audio session for receiving
    final audioManager = _ref.read(audioSessionProvider);
    await audioManager.configureForReceiving();
    await audioManager.activate();

    // Enable speakerphone for WebRTC audio
    try {
      await Helper.setSpeakerphoneOn(true);
      debugPrint('LivePTT: Speakerphone enabled');
    } catch (e) {
      debugPrint('LivePTT: Failed to enable speakerphone: $e');
    }

    // Ensure all audio tracks are enabled
    for (final track in stream.getAudioTracks()) {
      track.enabled = true;
      debugPrint('LivePTT: Audio track ${track.id} enabled');
    }

    debugPrint('LivePTT: Remote audio should now be playing');
  }

  /// Start timer to track broadcast duration
  void _startBroadcastTimer() {
    _stopBroadcastTimer();
    _broadcastTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      // Trigger rebuild to update duration display
      state = state.copyWith(
        state: LivePttState.broadcasting,
        broadcastStartTime: state.broadcastStartTime,
      );
    });
  }

  /// Stop broadcast duration timer
  void _stopBroadcastTimer() {
    _broadcastTimer?.cancel();
    _broadcastTimer = null;
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

  @override
  void dispose() {
    _connectionSubscription?.cancel();
    _streamingStateSubscription?.cancel();
    _speakerSubscription?.cancel();
    _floorSubscription?.cancel();
    _remoteStreamSubscription?.cancel();
    _stopBroadcastTimer();

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
