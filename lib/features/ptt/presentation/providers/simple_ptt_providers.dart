import 'dart:async';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../../../../core/services/native_audio_service.dart';
import '../../../../di/providers.dart';
import '../../../channels/data/channel_repository.dart';
import '../../data/simple_live_streaming_service.dart';
import '../../data/websocket_signaling_service.dart';

/// Simplified PTT state - essential fields only
enum SimplePttState {
  idle,
  connecting,
  requestingFloor,
  broadcasting,
  listening,
  error,
  disconnected,
}

/// Simplified PTT session state
class SimplePttSessionState {
  final SimplePttState state;
  final String? errorMessage;
  final DateTime? broadcastStartTime;
  final String? currentSpeakerId;
  final String? currentSpeakerName;
  final WSConnectionState connectionState;
  final bool isMuted;
  final int listenerCount;

  const SimplePttSessionState({
    this.state = SimplePttState.disconnected,
    this.errorMessage,
    this.broadcastStartTime,
    this.currentSpeakerId,
    this.currentSpeakerName,
    this.connectionState = WSConnectionState.disconnected,
    this.isMuted = false,
    this.listenerCount = 0,
  });

  SimplePttSessionState copyWith({
    SimplePttState? state,
    String? errorMessage,
    DateTime? broadcastStartTime,
    String? currentSpeakerId,
    String? currentSpeakerName,
    WSConnectionState? connectionState,
    bool? isMuted,
    int? listenerCount,
    bool clearError = false,
    bool clearSpeaker = false,
  }) {
    return SimplePttSessionState(
      state: state ?? this.state,
      errorMessage: clearError ? null : (errorMessage ?? this.errorMessage),
      broadcastStartTime: broadcastStartTime ?? this.broadcastStartTime,
      currentSpeakerId:
          clearSpeaker ? null : (currentSpeakerId ?? this.currentSpeakerId),
      currentSpeakerName:
          clearSpeaker ? null : (currentSpeakerName ?? this.currentSpeakerName),
      connectionState: connectionState ?? this.connectionState,
      isMuted: isMuted ?? this.isMuted,
      listenerCount: listenerCount ?? this.listenerCount,
    );
  }

  bool get canBroadcast =>
      state == SimplePttState.idle &&
      connectionState == WSConnectionState.authenticated;

  bool get isBroadcasting => state == SimplePttState.broadcasting;
  bool get isListening => state == SimplePttState.listening;
  bool get isConnected =>
      connectionState == WSConnectionState.authenticated;
  bool get isConnecting =>
      connectionState == WSConnectionState.connecting ||
      connectionState == WSConnectionState.authenticating ||
      connectionState == WSConnectionState.reconnecting;

  Duration get broadcastDuration {
    if (broadcastStartTime == null) return Duration.zero;
    return DateTime.now().difference(broadcastStartTime!);
  }

  int get remainingBroadcastSeconds {
    if (broadcastStartTime == null) return 60;
    final elapsed = DateTime.now().difference(broadcastStartTime!).inSeconds;
    return (60 - elapsed).clamp(0, 60);
  }

  bool get isBroadcastTimeWarning =>
      remainingBroadcastSeconds <= 10 && isBroadcasting;
}

/// Simplified PTT session provider
final simplePttSessionProvider = StateNotifierProvider.family<
    SimplePttSessionNotifier, SimplePttSessionState, String>((ref, channelId) {
  final wsService = ref.watch(websocketSignalingServiceProvider);
  final streamingService =
      ref.watch(simpleLiveStreamingServiceProvider(channelId));

  return SimplePttSessionNotifier(
    ref: ref,
    channelId: channelId,
    wsService: wsService,
    streamingService: streamingService,
  );
});

/// Simplified PTT session notifier
class SimplePttSessionNotifier extends StateNotifier<SimplePttSessionState>
    with WidgetsBindingObserver {
  final Ref _ref;
  final String channelId;
  final WebSocketSignalingService _wsService;
  final SimpleLiveStreamingService _streamingService;

  StreamSubscription? _connectionSubscription;
  StreamSubscription? _streamingStateSubscription;
  StreamSubscription? _speakerSubscription;
  StreamSubscription? _floorSubscription;
  StreamSubscription? _remoteStreamSubscription;
  StreamSubscription? _listenerCountSubscription;

  Timer? _broadcastTimer;
  Timer? _autoStopTimer;
  bool _wakelockEnabled = false;
  bool _observerAdded = false;
  bool _isDisposed = false;

  static const int _maxBroadcastDurationSeconds = 60;

  SimplePttSessionNotifier({
    required Ref ref,
    required this.channelId,
    required WebSocketSignalingService wsService,
    required SimpleLiveStreamingService streamingService,
  })  : _ref = ref,
        _wsService = wsService,
        _streamingService = streamingService,
        super(SimplePttSessionState(
          connectionState: wsService.currentConnectionState,
          state: wsService.isConnected
              ? SimplePttState.idle
              : SimplePttState.disconnected,
        )) {
    _setupListeners();
    _autoConnect();
    try {
      WidgetsBinding.instance.addObserver(this);
      _observerAdded = true;
    } catch (e) {
      debugPrint('SimplePTT: Failed to add lifecycle observer: $e');
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState appState) {
    if (appState == AppLifecycleState.resumed) {
      _onAppForeground();
    }
  }

  Future<void> _onAppForeground() async {
    debugPrint('SimplePTT: App coming to foreground');

    // CRITICAL: Re-warm audio system FIRST before anything else
    // This fixes "first broadcast missed after wake up" issue
    // Android may have reset audio mode while app was in background
    try {
      await _streamingService.reWarmAudioForForeground();
    } catch (e) {
      debugPrint('SimplePTT: Streaming service audio re-warm error: $e');
      // Fallback to direct audio config
      try {
        await NativeAudioService.setAudioModeForVoiceChat();
        await NativeAudioService.setSpeakerOn(true);
      } catch (e2) {
        debugPrint('SimplePTT: Audio config fallback error: $e2');
      }
    }

    if (!_wsService.isConnected) {
      await _wsService.forceReconnect();
      if (_wsService.isConnected) {
        _wsService.joinRoom(channelId, rejoin: true);
      }
    }
  }

  void _setupListeners() {
    _connectionSubscription = _wsService.connectionState.listen((connState) {
      final newPttState = _mapConnectionToPttState(connState);
      state = state.copyWith(
        connectionState: connState,
        state: newPttState,
      );

      if (connState == WSConnectionState.authenticated) {
        _wsService.joinRoom(channelId);
      }
    });

    _streamingStateSubscription =
        _streamingService.stateStream.listen((streamState) {
      final newState = _mapStreamingToPttState(streamState);
      if (newState != state.state) {
        state = state.copyWith(state: newState);

        if (newState == SimplePttState.broadcasting) {
          state = state.copyWith(broadcastStartTime: DateTime.now());
          _startBroadcastTimer();
        } else if (newState == SimplePttState.listening) {
          // Wake up the screen when someone starts speaking
          // This ensures the user can see who is speaking
          NativeAudioService.wakeScreen().catchError((e) {
            debugPrint('SimplePTT: Failed to wake screen: $e');
          });
        } else {
          _stopBroadcastTimer();
        }
      }
    });

    _speakerSubscription = _streamingService.currentSpeaker.listen((speaker) {
      if (speaker.id == null) {
        state = state.copyWith(clearSpeaker: true);
      } else {
        state = state.copyWith(
          currentSpeakerId: speaker.id,
          currentSpeakerName: speaker.name,
        );
      }
    });

    _floorSubscription = _wsService.floorState.listen((event) {
      if (event.roomId != channelId) return;
      final floor = event.state;
      if (floor != null) {
        state = state.copyWith(
          currentSpeakerId: floor.speakerId,
          currentSpeakerName: floor.speakerName,
        );
      } else {
        state = state.copyWith(clearSpeaker: true);
      }
    });

    _remoteStreamSubscription =
        _streamingService.remoteStreamAdded.listen((stream) async {
      await _enableWakelock();
      debugPrint('SimplePTT: Remote stream received');
    });

    _listenerCountSubscription =
        _streamingService.listenerCountStream.listen((count) {
      state = state.copyWith(listenerCount: count);
    });
  }

  Future<void> _autoConnect() async {
    await _enableWakelock();

    if (_wsService.isConnected) {
      _wsService.joinRoom(channelId);
      return;
    }

    final user = _ref.read(authStateProvider).value;
    if (user == null) {
      state = state.copyWith(
        state: SimplePttState.error,
        errorMessage: 'Not logged in',
      );
      return;
    }

    state = state.copyWith(state: SimplePttState.connecting);

    try {
      final token = await user.getIdToken(true);
      if (token != null) {
        String? displayName = user.displayName;
        if (displayName == null || displayName.isEmpty) {
          try {
            final userModel = await _ref.read(currentUserProvider.future);
            displayName = userModel?.displayName ?? userModel?.phoneNumber;
          } catch (e) {
            debugPrint('SimplePTT: Failed to get display name: $e');
          }
        }
        await _wsService.connect(token, displayName: displayName);
      }
    } catch (e) {
      state = state.copyWith(
        state: SimplePttState.error,
        errorMessage: 'Connection failed',
      );
    }
  }

  Future<bool> startBroadcasting() async {
    if (!state.canBroadcast) return false;

    // Check channel is active
    try {
      final channelRepo = _ref.read(channelRepositoryProvider);
      final channel = await channelRepo.getChannelById(channelId);
      if (channel == null || !channel.isActive) {
        state = state.copyWith(
          state: SimplePttState.error,
          errorMessage: 'Channel inactive',
        );
        return false;
      }
    } catch (e) {
      // Allow if check fails
    }

    state = state.copyWith(state: SimplePttState.requestingFloor);

    final success = await _streamingService.startBroadcasting();
    if (!success) {
      state = state.copyWith(
        state: SimplePttState.error,
        errorMessage: 'Failed to start',
      );
      return false;
    }

    return true;
  }

  Future<void> stopBroadcasting() async {
    if (!state.isBroadcasting &&
        state.state != SimplePttState.requestingFloor) {
      return;
    }

    try {
      await _streamingService.stopBroadcasting();
    } catch (e) {
      debugPrint('SimplePTT: Error stopping: $e');
    }

    _stopBroadcastTimer();
    state = state.copyWith(state: SimplePttState.idle);
  }

  Future<void> reconnect() async {
    if (_wsService.isConnected) return;
    await _autoConnect();
  }

  void toggleMute() {
    final newMuteState = !state.isMuted;
    state = state.copyWith(isMuted: newMuteState);
    _streamingService.setMuted(newMuteState);
  }

  Future<void> forceStopCurrentBroadcast() async {
    _wsService.releaseFloor(channelId);
    await _streamingService.forceStopAllConnections();
    state = state.copyWith(
      clearSpeaker: true,
      state: SimplePttState.idle,
    );
  }

  SimplePttState _mapConnectionToPttState(WSConnectionState connState) {
    switch (connState) {
      case WSConnectionState.disconnected:
        return SimplePttState.disconnected;
      case WSConnectionState.connecting:
      case WSConnectionState.connected:
      case WSConnectionState.authenticating:
      case WSConnectionState.reconnecting:
        return SimplePttState.connecting;
      case WSConnectionState.authenticated:
        return state.isBroadcasting
            ? SimplePttState.broadcasting
            : SimplePttState.idle;
      case WSConnectionState.error:
        return SimplePttState.error;
    }
  }

  SimplePttState _mapStreamingToPttState(SimpleLiveStreamingState streamState) {
    switch (streamState) {
      case SimpleLiveStreamingState.idle:
        return state.isConnected
            ? SimplePttState.idle
            : SimplePttState.disconnected;
      case SimpleLiveStreamingState.connecting:
        return SimplePttState.requestingFloor;
      case SimpleLiveStreamingState.broadcasting:
        return SimplePttState.broadcasting;
      case SimpleLiveStreamingState.listening:
        return SimplePttState.listening;
      case SimpleLiveStreamingState.error:
        return SimplePttState.error;
    }
  }

  void _startBroadcastTimer() {
    _stopBroadcastTimer();

    _broadcastTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (_isDisposed) {
        _stopBroadcastTimer();
        return;
      }
      state = state.copyWith(
        state: SimplePttState.broadcasting,
        broadcastStartTime: state.broadcastStartTime,
      );
    });

    _autoStopTimer = Timer(
      const Duration(seconds: _maxBroadcastDurationSeconds),
      () {
        if (!_isDisposed) {
          stopBroadcasting();
        }
      },
    );
  }

  void _stopBroadcastTimer() {
    _broadcastTimer?.cancel();
    _broadcastTimer = null;
    _autoStopTimer?.cancel();
    _autoStopTimer = null;
  }

  void clearError() {
    if (state.state == SimplePttState.error) {
      state = state.copyWith(
        state: state.isConnected
            ? SimplePttState.idle
            : SimplePttState.disconnected,
        clearError: true,
      );
    }
  }

  Future<void> _enableWakelock() async {
    if (_wakelockEnabled) return;
    try {
      await WakelockPlus.enable();
      _wakelockEnabled = true;
    } catch (e) {
      debugPrint('SimplePTT: Wakelock error: $e');
    }
  }

  Future<void> _disableWakelock() async {
    if (!_wakelockEnabled) return;
    try {
      await WakelockPlus.disable();
      _wakelockEnabled = false;
    } catch (e) {
      debugPrint('SimplePTT: Wakelock disable error: $e');
    }
  }

  @override
  void dispose() {
    _isDisposed = true;

    if (_observerAdded) {
      try {
        WidgetsBinding.instance.removeObserver(this);
      } catch (e) {
        debugPrint('SimplePTT: Failed to remove observer: $e');
      }
    }

    _connectionSubscription?.cancel();
    _streamingStateSubscription?.cancel();
    _speakerSubscription?.cancel();
    _floorSubscription?.cancel();
    _remoteStreamSubscription?.cancel();
    _listenerCountSubscription?.cancel();
    _stopBroadcastTimer();
    _disableWakelock();

    // IMMEDIATELY stop all audio (sync) before async cleanup
    // This ensures no audio plays from old channel when switching
    debugPrint('SimplePTT: Disposing session for $channelId - stopping all audio immediately');
    _streamingService.stopAllAudioImmediately();

    // Schedule async cleanup (peer connections, streams disposal)
    _streamingService.forceStopAllConnections();

    if (_wsService.isConnected) {
      _wsService.leaveRoom(channelId);
    }

    super.dispose();
  }
}

/// Provider for current speaker
final simpleCurrentSpeakerProvider =
    Provider.family<({String? id, String? name}), String>((ref, channelId) {
  final session = ref.watch(simplePttSessionProvider(channelId));
  return (id: session.currentSpeakerId, name: session.currentSpeakerName);
});

/// Provider for checking if current user is speaking
final isCurrentUserSpeakingSimpleProvider =
    Provider.family<bool, String>((ref, channelId) {
  final session = ref.watch(simplePttSessionProvider(channelId));
  final wsService = ref.watch(websocketSignalingServiceProvider);
  return session.currentSpeakerId == wsService.userId && session.isBroadcasting;
});
