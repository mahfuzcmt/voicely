import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

import '../../../core/constants/app_constants.dart';
import '../../../core/services/native_audio_service.dart';
import '../../../core/utils/logger.dart';
import 'websocket_signaling_service.dart';

/// Simplified live streaming state
enum SimpleLiveStreamingState {
  idle,
  connecting,
  broadcasting,
  listening,
  error,
}

/// Provider for simple live streaming service per channel
final simpleLiveStreamingServiceProvider =
    Provider.family<SimpleLiveStreamingService, String>(
  (ref, channelId) {
    final wsService = ref.watch(websocketSignalingServiceProvider);
    final service = SimpleLiveStreamingService(
      channelId: channelId,
      wsService: wsService,
    );
    ref.onDispose(() => service.dispose());
    return service;
  },
);

/// Simplified Live streaming service - core PTT functionality only
/// Removes: multi-peer complexity, ICE restart, candidate batching,
/// listener tracking, late joiner detection, stale connection cleanup
class SimpleLiveStreamingService {
  final String channelId;
  final WebSocketSignalingService _wsService;

  /// CRITICAL: Track the currently active PTT channel globally
  /// Only the service for this channel should process incoming audio
  /// This prevents cross-channel audio leak when multiple services exist
  static String? _activeChannelId;

  /// Set this channel as the active PTT channel
  /// Called when user enters this channel's PTT screen
  void setAsActiveChannel() {
    if (_activeChannelId != channelId) {
      debugPrint('SimpleStream: Setting $channelId as active channel (was: $_activeChannelId)');
      _activeChannelId = channelId;
    }
  }

  /// Check if this channel is currently active
  bool get isActiveChannel => _activeChannelId == channelId;

  /// Clear active channel (called on dispose)
  void _clearActiveChannelIfSelf() {
    if (_activeChannelId == channelId) {
      debugPrint('SimpleStream: Clearing active channel $channelId');
      _activeChannelId = null;
    }
  }

  // WebRTC state - multiple peer connections for broadcasting to all listeners
  MediaStream? _localStream;
  final Map<String, RTCPeerConnection> _peerConnections = {};
  MediaStream? _remoteStream;
  String? _currentSpeakerPeerId; // The peer we're receiving audio from

  // Pending ICE candidates per peer (before remote description is set)
  final Map<String, List<RTCIceCandidate>> _pendingIceCandidates = {};

  // Track connected listeners for count
  final Set<String> _connectedListeners = {};

  // Stream subscriptions
  StreamSubscription? _offerSubscription;
  StreamSubscription? _answerSubscription;
  StreamSubscription? _iceSubscription;
  StreamSubscription? _floorSubscription;
  StreamSubscription? _floorDeniedSubscription;
  StreamSubscription? _connectionSubscription;
  StreamSubscription? _memberJoinedSubscription;
  StreamSubscription? _offerRequestSubscription;
  Timer? _floorRequestTimeout;

  // State
  SimpleLiveStreamingState _state = SimpleLiveStreamingState.idle;
  bool _isBroadcasting = false;
  String? _currentSpeakerId;
  bool _isMuted = false;

  // Minimum broadcast duration for audio to establish
  static const Duration _minBroadcastDuration = Duration(milliseconds: 800);
  DateTime? _broadcastStartTime;

  // Audio flow verification
  Timer? _audioFlowTimer;
  int _lastBytesReceived = 0;
  int _silentCheckCount = 0;
  static const int _maxSilentChecks = 3; // 3 seconds of silence = problem

  // Listening timeout - if no audio track received within this time, something is wrong
  Timer? _listeningTimeoutTimer;
  Timer? _earlyOfferCheckTimer; // NEW: Check early if no offer arrives
  static const Duration _listeningTimeout = Duration(seconds: 5);
  static const Duration _earlyOfferCheckDelay = Duration(seconds: 2); // NEW: Check after 2s
  bool _hasReceivedAudioTrack = false;
  bool _hasReceivedOffer = false; // NEW: Track if offer was received
  int _offerRetryCount = 0;
  static const int _maxOfferRetries = 3; // Increased from 2 to 3 for better recovery

  // Track audio flow recovery attempts separately from initial offer retries
  int _silentAudioRecoveryCount = 0;
  static const int _maxSilentAudioRecoveries = 2;

  // Controllers
  final _stateController =
      StreamController<SimpleLiveStreamingState>.broadcast();
  final _remoteStreamController = StreamController<MediaStream>.broadcast();
  final _speakerController =
      StreamController<({String? id, String? name})>.broadcast();
  final _listenerCountController = StreamController<int>.broadcast();
  final _audioFlowController = StreamController<bool>.broadcast();

  /// Stream indicating whether audio is actually flowing (not just connected)
  Stream<bool> get audioFlowStream => _audioFlowController.stream;

  // Streams
  Stream<SimpleLiveStreamingState> get stateStream => _stateController.stream;
  Stream<MediaStream> get remoteStreamAdded => _remoteStreamController.stream;
  Stream<({String? id, String? name})> get currentSpeaker =>
      _speakerController.stream;
  Stream<int> get listenerCountStream => _listenerCountController.stream;

  // Getters
  SimpleLiveStreamingState get state => _state;
  bool get isBroadcasting => _isBroadcasting;
  bool get isMuted => _isMuted;
  MediaStream? get localStream => _localStream;
  String? get currentSpeakerId => _currentSpeakerId;
  int get activeListenerCount => _connectedListeners.length;

  // Track if audio system has been pre-warmed for this session
  bool _isAudioPreWarmed = false;

  SimpleLiveStreamingService({
    required this.channelId,
    required WebSocketSignalingService wsService,
  }) : _wsService = wsService {
    // Set this as the active channel immediately
    setAsActiveChannel();
    _setupListeners();
    // Pre-warm audio system on service creation
    _preWarmAudioSystem();
  }

  /// Pre-warm the audio system when service is created
  /// This ensures audio mode is ready BEFORE the first broadcast arrives
  Future<void> _preWarmAudioSystem() async {
    if (_isAudioPreWarmed) return;

    try {
      debugPrint('SimpleStream: Pre-warming audio system for channel $channelId');
      // Configure audio mode proactively - this primes the Android AudioManager
      // so the first broadcast doesn't have cold-start latency
      await NativeAudioService.setAudioModeForVoiceChat();
      await NativeAudioService.setSpeakerOn(true);
      _isAudioPreWarmed = true;
      debugPrint('SimpleStream: Audio system pre-warmed successfully');
    } catch (e) {
      debugPrint('SimpleStream: Audio pre-warm error (non-fatal): $e');
      // Non-fatal - will retry when broadcast arrives
    }
  }

  /// Re-warm audio system after app resumes from background
  /// Called when app comes to foreground to ensure audio is ready
  /// CRITICAL: This fixes the "first broadcast missed after wake up" issue
  Future<void> reWarmAudioForForeground() async {
    debugPrint('SimpleStream: Re-warming audio for foreground (was pre-warmed: $_isAudioPreWarmed)');

    // Reset the flag since Android may have reset audio mode while app was in background
    _isAudioPreWarmed = false;

    // If we're currently in listening state, aggressively activate audio
    if (_state == SimpleLiveStreamingState.listening) {
      debugPrint('SimpleStream: Currently listening - activating audio aggressively');
      await _activateAudioForTrack();
    } else {
      await _preWarmAudioSystem();
    }
  }

  /// Set muted state for incoming audio
  /// Safe against race conditions during disposal
  void setMuted(bool muted) {
    _isMuted = muted;

    // Capture reference to avoid race condition with disposal
    final stream = _remoteStream;
    if (stream == null) return;

    try {
      final tracks = stream.getAudioTracks();
      for (final track in tracks) {
        track.enabled = !muted;
      }
    } catch (e) {
      // Stream may have been disposed between null check and usage
      debugPrint('SimpleStream: setMuted error (stream may be disposed): $e');
    }
  }

  /// Setup WebSocket message listeners
  void _setupListeners() {
    _offerSubscription = _wsService.webrtcOffers.listen((event) {
      if (event.roomId == channelId) {
        _handleIncomingOffer(event.fromUserId, event.sdp);
      }
    });

    _answerSubscription = _wsService.webrtcAnswers.listen((event) {
      if (event.roomId == channelId) {
        _handleIncomingAnswer(event.fromUserId, event.sdp);
      }
    });

    _iceSubscription = _wsService.webrtcIceCandidates.listen((event) {
      if (event.roomId == channelId) {
        _handleIncomingIceCandidate(
          event.fromUserId,
          event.candidate,
          event.sdpMid,
          event.sdpMLineIndex,
        );
      }
    });

    _floorSubscription = _wsService.floorState.listen((event) {
      if (event.roomId == channelId) {
        // CRITICAL: Only process if this is the active channel
        // This prevents cross-channel audio when multiple services exist
        if (!isActiveChannel) {
          debugPrint('SimpleStream: Ignoring floor event for $channelId - not active channel (active: $_activeChannelId)');
          return;
        }
        _handleFloorStateChange(event.state);
      }
    });

    _floorDeniedSubscription = _wsService.floorDenied.listen((event) {
      if (event.roomId == channelId) {
        _handleFloorDenied(event.reason);
      }
    });

    _connectionSubscription = _wsService.connectionState.listen((connState) {
      if (connState == WSConnectionState.disconnected ||
          connState == WSConnectionState.error) {
        if (_state == SimpleLiveStreamingState.broadcasting ||
            _state == SimpleLiveStreamingState.listening) {
          _isBroadcasting = false;
          _closeAllPeerConnections();
          _disposeLocalStream();
          _updateState(SimpleLiveStreamingState.idle);
        }
      }
    });

    // Listen for new members when broadcasting - send offer to new joiners
    _memberJoinedSubscription = _wsService.roomMembers.listen((event) async {
      if (event.roomId == channelId && _isBroadcasting && _localStream != null) {
        final myUserId = _wsService.userId;
        for (final member in event.members) {
          // Send offer to new members who don't already have a connection
          if (member.userId != myUserId && !_peerConnections.containsKey(member.userId)) {
            debugPrint(
                'SimpleStream: New listener ${member.displayName}, sending offer');
            await _createAndSendOffer(member.userId);
          }
        }
      }
    });

    // Listen for offer requests from listeners who didn't receive our offer
    _offerRequestSubscription = _wsService.webrtcOfferRequests.listen((event) async {
      debugPrint('SimpleStream: Received offer request from ${event.fromUserId} for room ${event.roomId}');
      debugPrint('SimpleStream: My channel=$channelId, isBroadcasting=$_isBroadcasting, hasLocalStream=${_localStream != null}');

      if (event.roomId == channelId && _isBroadcasting && _localStream != null) {
        debugPrint('SimpleStream: RESENDING offer to ${event.fromUserId}');
        await _createAndSendOffer(event.fromUserId);
      } else {
        debugPrint('SimpleStream: Ignoring offer request - conditions not met');
      }
    });
  }

  /// Initialize local audio stream
  Future<bool> initLocalStream() async {
    if (_localStream != null) return true;

    try {
      debugPrint('SimpleStream: Initializing local stream');

      // Configure audio mode for broadcasting
      await NativeAudioService.setAudioModeForBroadcasting();

      // Enhanced audio constraints for better voice quality
      final constraints = {
        'audio': {
          'echoCancellation': true,
          'noiseSuppression': true,
          'autoGainControl': true,
          // Additional settings for better voice clarity
          'googEchoCancellation': true,
          'googAutoGainControl': true,
          'googNoiseSuppression': true,
          'googHighpassFilter': true,
          'googTypingNoiseDetection': true,
          // Don't specify sample rate - let WebRTC use optimal (usually 48kHz)
          // Specifying lower rates can cause playback speed issues
        },
        'video': false,
      };

      _localStream = await navigator.mediaDevices.getUserMedia(constraints);
      debugPrint(
          'SimpleStream: Got local stream with ${_localStream!.getAudioTracks().length} audio tracks');

      for (final track in _localStream!.getAudioTracks()) {
        track.enabled = true;
      }

      return true;
    } catch (e) {
      Logger.e('Failed to initialize local stream', error: e);
      _updateState(SimpleLiveStreamingState.error);
      return false;
    }
  }

  /// Start broadcasting (PTT pressed)
  Future<bool> startBroadcasting() async {
    if (_isBroadcasting) return false;

    // CRITICAL: Set this channel as active when user starts broadcasting
    // This ensures floor grant events are not ignored
    setAsActiveChannel();

    _updateState(SimpleLiveStreamingState.connecting);

    // Initialize local stream
    if (_localStream == null) {
      final success = await initLocalStream();
      if (!success) {
        _updateState(SimpleLiveStreamingState.error);
        return false;
      }
    }

    // Request floor
    debugPrint('SimpleStream: Requesting floor');
    _wsService.requestFloor(channelId);

    // Timeout for floor request
    _floorRequestTimeout?.cancel();
    _floorRequestTimeout = Timer(AppConstants.floorRequestTimeout, () {
      if (_state == SimpleLiveStreamingState.connecting && !_isBroadcasting) {
        debugPrint('SimpleStream: Floor request timed out');
        _updateState(SimpleLiveStreamingState.error);
        Timer(const Duration(seconds: 2), () {
          if (_state == SimpleLiveStreamingState.error) {
            _updateState(SimpleLiveStreamingState.idle);
          }
        });
      }
    });

    return true;
  }

  /// Stop broadcasting (PTT released)
  Future<void> stopBroadcasting() async {
    _floorRequestTimeout?.cancel();
    _floorRequestTimeout = null;

    if (_state == SimpleLiveStreamingState.connecting && !_isBroadcasting) {
      _updateState(SimpleLiveStreamingState.idle);
      return;
    }

    if (!_isBroadcasting) return;

    // Enforce minimum broadcast duration
    if (_broadcastStartTime != null) {
      final elapsed = DateTime.now().difference(_broadcastStartTime!);
      if (elapsed < _minBroadcastDuration) {
        await Future.delayed(_minBroadcastDuration - elapsed);
      }
    }

    Logger.d('Stopping broadcast');

    _setLocalAudioEnabled(false);
    _isBroadcasting = false;
    _broadcastStartTime = null;
    _updateState(SimpleLiveStreamingState.idle);

    _wsService.releaseFloor(channelId);
    await _closeAllPeerConnections();
    await _disposeLocalStream();
  }

  /// Immediately stop all audio playback (synchronous - for fast channel switching)
  void stopAllAudioImmediately() {
    debugPrint('SimpleStream: Immediately stopping all audio');

    // Disable remote audio tracks immediately (stops incoming audio)
    if (_remoteStream != null) {
      for (final track in _remoteStream!.getAudioTracks()) {
        track.enabled = false;
      }
    }

    // Disable local audio tracks immediately (stops outgoing audio)
    if (_localStream != null) {
      for (final track in _localStream!.getAudioTracks()) {
        track.enabled = false;
      }
    }

    _isBroadcasting = false;
    _broadcastStartTime = null;
  }

  /// Schedule async cleanup without blocking
  /// This prevents race conditions by running cleanup in next event loop cycle
  void _scheduleCleanup() {
    Future.microtask(() async {
      try {
        await _closeAllPeerConnections();
        await _disposeLocalStream();
      } catch (e) {
        debugPrint('SimpleStream: Scheduled cleanup error: $e');
      }
    });
  }

  /// Force stop all connections
  Future<void> forceStopAllConnections() async {
    debugPrint('SimpleStream: Force stopping all connections');

    // IMMEDIATELY disable all audio tracks (sync) before async cleanup
    stopAllAudioImmediately();

    await _closeAllPeerConnections();
    await _disposeLocalStream();

    _currentSpeakerId = null;
    _updateState(SimpleLiveStreamingState.idle);
    _speakerController.add((id: null, name: null));
  }

  /// Handle floor state changes
  /// Uses async cleanup to prevent race conditions
  void _handleFloorStateChange(WSFloorState? floor) {
    _floorRequestTimeout?.cancel();
    _floorRequestTimeout = null;

    if (floor == null) {
      // Floor released - stop audio IMMEDIATELY then cleanup async
      // Log if floor released before we received audio (ultra-short broadcast)
      if (_state == SimpleLiveStreamingState.listening && !_hasReceivedAudioTrack) {
        debugPrint('SimpleStream: WARNING - Floor released before audio track arrived (ultra-short broadcast)');
      }

      _currentSpeakerId = null;
      _speakerController.add((id: null, name: null));
      _cancelListeningTimeout();
      _stopAudioFlowVerification(); // Cancel all verification and recovery timers
      _hasReceivedAudioTrack = false;
      _hasReceivedOffer = false;
      _offerRetryCount = 0;
      _recoveryAttemptCount = 0;

      if (_isBroadcasting) {
        _setLocalAudioEnabled(false);
        _isBroadcasting = false;
        _broadcastStartTime = null;
        _updateState(SimpleLiveStreamingState.idle);
        // Stop audio immediately, then schedule async cleanup
        stopAllAudioImmediately();
        _scheduleCleanup();
      } else {
        // As listener, stop incoming audio immediately
        stopAllAudioImmediately();
        _updateState(SimpleLiveStreamingState.idle);
        _scheduleCleanup();
      }
      return;
    }

    _currentSpeakerId = floor.speakerId;
    _speakerController.add((id: floor.speakerId, name: floor.speakerName));

    if (floor.speakerId == _wsService.userId) {
      // We got the floor
      debugPrint('SimpleStream: We got the floor');
      _isBroadcasting = true;
      _broadcastStartTime = DateTime.now();
      _updateState(SimpleLiveStreamingState.broadcasting);
      _setLocalAudioEnabled(true);
      _startStreamingToListeners();
    } else {
      // Someone else is speaking - cleanup our broadcast if we were broadcasting
      debugPrint('SimpleStream: ${floor.speakerName} is speaking');
      if (_isBroadcasting) {
        stopAllAudioImmediately();
        _scheduleCleanup();
        _broadcastStartTime = null;
      }
      _isBroadcasting = false;
      _hasReceivedAudioTrack = false;
      _hasReceivedOffer = false;
      _offerRetryCount = 0;
      _silentAudioRecoveryCount = 0; // Reset silent audio recovery counter
      _updateState(SimpleLiveStreamingState.listening);

      // CRITICAL: Configure audio mode SYNCHRONOUSLY before proceeding
      // This was causing "first broadcast missed" because audio wasn't ready
      // when the WebRTC offer arrived
      _ensureAudioReadyForListening(floor.speakerId);
    }
  }

  /// Ensure audio is configured and ready for listening
  /// This is called synchronously when someone starts speaking
  Future<void> _ensureAudioReadyForListening(String speakerId) async {
    try {
      debugPrint('SimpleStream: Ensuring audio ready for listening to $speakerId');

      // CRITICAL: Wake screen FIRST when receiving audio in background
      // Audio may not play if display is completely off on some devices
      try {
        await NativeAudioService.wakeScreen();
        debugPrint('SimpleStream: Screen woken up for audio');
      } catch (e) {
        debugPrint('SimpleStream: Screen wake failed (may already be on): $e');
      }

      // Small delay to let screen wake take effect
      await Future.delayed(const Duration(milliseconds: 100));

      // Configure audio mode - MUST complete before we can receive audio
      await NativeAudioService.setAudioModeForVoiceChat();
      await NativeAudioService.setSpeakerOn(true);
      _isAudioPreWarmed = true;

      debugPrint('SimpleStream: Audio ready for listening');
    } catch (e) {
      debugPrint('SimpleStream: Audio config error for listening: $e');
      // Retry audio configuration
      try {
        await Future.delayed(const Duration(milliseconds: 200));
        await NativeAudioService.setAudioModeForVoiceChat();
        await NativeAudioService.setSpeakerOn(true);
        _isAudioPreWarmed = true;
        debugPrint('SimpleStream: Audio retry successful');
      } catch (e2) {
        debugPrint('SimpleStream: Audio retry also failed: $e2');
      }
    }

    // Start timeout to detect if we don't receive audio
    // Only start AFTER audio is configured
    _startListeningTimeout(speakerId);
  }

  /// Start a timeout to detect if we don't receive audio while "listening"
  void _startListeningTimeout(String speakerId) {
    _cancelListeningTimeout();

    // NEW: Start an early check timer - if no offer after 2 seconds, request one
    // This catches cases where speaker never sent an offer
    _earlyOfferCheckTimer = Timer(_earlyOfferCheckDelay, () {
      if (_state == SimpleLiveStreamingState.listening && !_hasReceivedOffer) {
        debugPrint('SimpleStream: EARLY CHECK - No offer received after $_earlyOfferCheckDelay, requesting offer from $speakerId');
        _requestOfferFromSpeaker(speakerId);
      }
    });

    // Main timeout timer for backup
    _listeningTimeoutTimer = Timer(_listeningTimeout, () {
      if (_state == SimpleLiveStreamingState.listening && !_hasReceivedAudioTrack) {
        debugPrint('SimpleStream: TIMEOUT - No audio received after $_listeningTimeout, requesting offer from $speakerId');
        _requestOfferFromSpeaker(speakerId);
      }
    });
  }

  /// Cancel listening timeout
  void _cancelListeningTimeout() {
    _listeningTimeoutTimer?.cancel();
    _listeningTimeoutTimer = null;
    _earlyOfferCheckTimer?.cancel();
    _earlyOfferCheckTimer = null;
  }

  /// Request offer from speaker when we haven't received one
  void _requestOfferFromSpeaker(String speakerId) {
    if (_offerRetryCount >= _maxOfferRetries) {
      debugPrint('SimpleStream: Max offer retries reached ($_maxOfferRetries)');

      // Last resort: close all connections and request offer one final time
      // This handles edge cases where stale connections block new ones
      _performFinalRecoveryAttempt(speakerId);
      return;
    }

    _offerRetryCount++;
    debugPrint('SimpleStream: Requesting offer from speaker (attempt $_offerRetryCount/$_maxOfferRetries)');

    // Re-configure audio before requesting offer - aggressively
    _activateAudioForTrack().catchError((e) {
      debugPrint('SimpleStream: Audio config error before offer request: $e');
    });

    // Send a request_offer message to ask the speaker to send us an offer
    _wsService.requestWebRtcOffer(channelId, speakerId);

    // Set another timeout in case this request also fails
    _listeningTimeoutTimer = Timer(_listeningTimeout, () {
      if (_state == SimpleLiveStreamingState.listening && !_hasReceivedAudioTrack) {
        debugPrint('SimpleStream: Still no audio after retry $_offerRetryCount');
        _requestOfferFromSpeaker(speakerId);
      }
    });
  }

  /// Perform final recovery attempt by clearing all connections and starting fresh
  Future<void> _performFinalRecoveryAttempt(String speakerId) async {
    debugPrint('SimpleStream: Performing FINAL recovery attempt - clearing all connections');

    // Close all existing peer connections to ensure clean slate
    await _closeAllPeerConnections();

    // Reset tracking state
    _hasReceivedAudioTrack = false;
    _remoteStream = null;
    _currentSpeakerPeerId = null;

    // Wait a short moment for cleanup to complete
    await Future.delayed(const Duration(milliseconds: 300));

    // Wake screen first - critical for background audio playback
    try {
      await NativeAudioService.wakeScreen();
      await Future.delayed(const Duration(milliseconds: 100));
    } catch (e) {
      // Screen might already be on
    }

    // Reconfigure audio from scratch
    try {
      await NativeAudioService.resetAudioMode();
      await Future.delayed(const Duration(milliseconds: 100));
      await NativeAudioService.setAudioModeForVoiceChat();
      await NativeAudioService.setSpeakerOn(true);
    } catch (e) {
      debugPrint('SimpleStream: Final recovery audio config error: $e');
    }

    // Request fresh offer
    debugPrint('SimpleStream: Final recovery - requesting fresh offer from $speakerId');
    _wsService.requestWebRtcOffer(channelId, speakerId);

    // Set one more timeout - if this fails, we've done all we can
    _listeningTimeoutTimer = Timer(const Duration(seconds: 8), () {
      if (_state == SimpleLiveStreamingState.listening && !_hasReceivedAudioTrack) {
        debugPrint('SimpleStream: FINAL RECOVERY FAILED - still no audio');
        // At this point, the speaker might have stopped or there's a network issue
        // The audio flow controller will signal this to UI if needed
        _audioFlowController.add(false);
      }
    });
  }

  /// Handle floor denied
  void _handleFloorDenied(String? reason) {
    debugPrint('SimpleStream: Floor denied: $reason');
    _floorRequestTimeout?.cancel();
    _floorRequestTimeout = null;

    if (_state == SimpleLiveStreamingState.connecting) {
      _updateState(SimpleLiveStreamingState.error);
      Timer(const Duration(seconds: 2), () {
        if (_state == SimpleLiveStreamingState.error) {
          _updateState(SimpleLiveStreamingState.idle);
        }
      });
    }
  }

  /// Start streaming to ALL listeners in the room
  Future<void> _startStreamingToListeners() async {
    if (_localStream == null) return;

    debugPrint('SimpleStream: Starting to stream to all listeners');
    await _closeAllPeerConnections();

    // Get all listeners and send offers to ALL of them
    final members = _wsService.getRoomMembers(channelId);
    final myUserId = _wsService.userId;

    final listenersToConnect = members
        .where((member) => member.userId != myUserId)
        .toList();

    debugPrint('SimpleStream: Sending offers to ${listenersToConnect.length} listeners');

    // Send offers to all listeners in parallel
    await Future.wait(
      listenersToConnect.map((member) async {
        debugPrint('SimpleStream: Sending offer to ${member.displayName}');
        await _createAndSendOffer(member.userId);
      }),
    );

    _listenerCountController.add(_connectedListeners.length);
  }

  /// Create and send offer to a listener
  Future<void> _createAndSendOffer(String listenerId) async {
    try {
      // Close existing connection to this peer if any
      await _closePeerConnectionFor(listenerId);

      final pc = await _createPeerConnection(listenerId);
      _peerConnections[listenerId] = pc;

      // Add local tracks
      if (_localStream != null) {
        for (final track in _localStream!.getTracks()) {
          await pc.addTrack(track, _localStream!);
        }
      }

      // Create offer
      final offer = await pc.createOffer({
        'offerToReceiveAudio': false,
        'offerToReceiveVideo': false,
      });

      if (offer.sdp == null || offer.sdp!.isEmpty) {
        debugPrint('SimpleStream: Failed to create offer for $listenerId');
        return;
      }

      // Optimize SDP for better voice quality broadcasting
      final optimizedSdp = _optimizeSdpForVoiceBroadcasting(offer.sdp!);
      final optimizedOffer = RTCSessionDescription(optimizedSdp, offer.type);

      await pc.setLocalDescription(optimizedOffer);

      _wsService.sendOffer(
        roomId: channelId,
        sdp: optimizedSdp,
        targetUserId: listenerId,
      );

      debugPrint('SimpleStream: Offer sent to $listenerId');
    } catch (e) {
      Logger.e('Error creating offer for $listenerId', error: e);
      await _closePeerConnectionFor(listenerId);
    }
  }

  /// Handle incoming offer (when receiving audio from broadcaster)
  Future<void> _handleIncomingOffer(String fromUserId, String sdp) async {
    if (fromUserId == _wsService.userId) return;

    debugPrint('SimpleStream: Received offer from $fromUserId');

    // Mark that we received an offer - cancel early check timer
    _hasReceivedOffer = true;
    _earlyOfferCheckTimer?.cancel();

    try {
      // Configure audio for receiving
      await NativeAudioService.setAudioModeForVoiceChat();
      await NativeAudioService.setSpeakerOn(true);

      // CRITICAL: Preserve pending ICE candidates before closing old connection
      // ICE candidates may arrive before offer processing completes
      final savedIceCandidates = List<RTCIceCandidate>.from(
        _pendingIceCandidates[fromUserId] ?? [],
      );
      if (savedIceCandidates.isNotEmpty) {
        debugPrint('SimpleStream: Preserving ${savedIceCandidates.length} ICE candidates for $fromUserId');
      }

      // Close existing connection to this speaker if any
      await _closePeerConnectionFor(fromUserId);

      // Restore saved ICE candidates after closing old connection
      if (savedIceCandidates.isNotEmpty) {
        _pendingIceCandidates[fromUserId] = savedIceCandidates;
        debugPrint('SimpleStream: Restored ${savedIceCandidates.length} ICE candidates for $fromUserId');
      }

      // Create peer connection for receiving
      final pc = await _createPeerConnection(fromUserId);
      _peerConnections[fromUserId] = pc;
      _currentSpeakerPeerId = fromUserId;

      // Add transceiver for receiving audio
      await pc.addTransceiver(
        kind: RTCRtpMediaType.RTCRtpMediaTypeAudio,
        init: RTCRtpTransceiverInit(direction: TransceiverDirection.RecvOnly),
      );

      // Set remote description with optimized audio settings
      final optimizedSdp = _optimizeSdpForVoiceReceiving(sdp);
      await pc.setRemoteDescription(RTCSessionDescription(optimizedSdp, 'offer'));

      // Apply pending ICE candidates for this peer
      await _applyPendingIceCandidatesFor(fromUserId);

      // Create answer with optimized audio settings
      final answer = await pc.createAnswer({
        'offerToReceiveAudio': true,
        'offerToReceiveVideo': false,
      });

      // Optimize SDP for better voice receiving quality
      final optimizedAnswerSdp = _optimizeSdpForVoiceReceiving(answer.sdp!);
      final optimizedAnswer = RTCSessionDescription(optimizedAnswerSdp, answer.type);

      await pc.setLocalDescription(optimizedAnswer);

      _wsService.sendAnswer(
        roomId: channelId,
        targetUserId: fromUserId,
        sdp: optimizedAnswerSdp,
      );

      debugPrint('SimpleStream: Answer sent to $fromUserId');
    } catch (e) {
      Logger.e('Failed to handle offer', error: e);
      await _closePeerConnectionFor(fromUserId);
    }
  }

  /// Handle incoming answer (when broadcasting)
  Future<void> _handleIncomingAnswer(String fromUserId, String sdp) async {
    if (!_isBroadcasting) return;

    final pc = _peerConnections[fromUserId];
    if (pc == null) {
      debugPrint('SimpleStream: No peer connection for $fromUserId');
      return;
    }

    debugPrint('SimpleStream: Received answer from $fromUserId');

    try {
      final signalingState = pc.signalingState;
      if (signalingState == RTCSignalingState.RTCSignalingStateHaveLocalOffer) {
        await pc.setRemoteDescription(RTCSessionDescription(sdp, 'answer'));
        await _applyPendingIceCandidatesFor(fromUserId);
        debugPrint('SimpleStream: Answer processed from $fromUserId');
        _connectedListeners.add(fromUserId);
        _listenerCountController.add(_connectedListeners.length);
      }
    } catch (e) {
      Logger.e('Failed to handle answer from $fromUserId', error: e);
    }
  }

  // Maximum ICE candidates to queue per peer (prevents memory leak)
  static const int _maxPendingIceCandidates = 50;

  /// Handle incoming ICE candidate
  Future<void> _handleIncomingIceCandidate(
    String fromUserId,
    String candidate,
    String sdpMid,
    int sdpMLineIndex,
  ) async {
    // Log received ICE candidate (truncate for readability)
    final candidatePreview = candidate.length > 60 ? '${candidate.substring(0, 60)}...' : candidate;
    debugPrint('SimpleStream: ICE candidate received from $fromUserId: $candidatePreview');

    final iceCandidate = RTCIceCandidate(candidate, sdpMid, sdpMLineIndex);

    final pc = _peerConnections[fromUserId];
    if (pc == null) {
      // Store pending candidate for this peer (with bounds)
      _pendingIceCandidates.putIfAbsent(fromUserId, () => []);
      if (_pendingIceCandidates[fromUserId]!.length < _maxPendingIceCandidates) {
        _pendingIceCandidates[fromUserId]!.add(iceCandidate);
        debugPrint('SimpleStream: Queued ICE candidate for $fromUserId (pending: ${_pendingIceCandidates[fromUserId]!.length})');
      } else {
        debugPrint('SimpleStream: ICE queue full for $fromUserId, dropping candidate');
      }
      return;
    }

    final remoteDesc = await pc.getRemoteDescription();
    if (remoteDesc == null) {
      _pendingIceCandidates.putIfAbsent(fromUserId, () => []);
      if (_pendingIceCandidates[fromUserId]!.length < _maxPendingIceCandidates) {
        _pendingIceCandidates[fromUserId]!.add(iceCandidate);
        debugPrint('SimpleStream: Queued ICE (no remote desc) for $fromUserId');
      }
      return;
    }

    try {
      await pc.addCandidate(iceCandidate);
      debugPrint('SimpleStream: Added ICE candidate from $fromUserId');
    } catch (e) {
      debugPrint('SimpleStream: Failed to add ICE candidate from $fromUserId: $e');
    }
  }

  /// Apply pending ICE candidates for a specific peer
  Future<void> _applyPendingIceCandidatesFor(String peerId) async {
    final pc = _peerConnections[peerId];
    final candidates = _pendingIceCandidates[peerId];
    if (pc == null || candidates == null || candidates.isEmpty) {
      debugPrint('SimpleStream: No pending ICE candidates to apply for $peerId');
      return;
    }

    debugPrint('SimpleStream: Applying ${candidates.length} pending ICE candidates for $peerId');
    for (final candidate in candidates) {
      try {
        await pc.addCandidate(candidate);
      } catch (e) {
        debugPrint('SimpleStream: Failed to apply pending ICE for $peerId: $e');
      }
    }
    _pendingIceCandidates.remove(peerId);
  }

  /// Create WebRTC peer connection
  Future<RTCPeerConnection> _createPeerConnection(String peerId) async {
    // CHANGED: Use 'all' instead of 'relay' to allow direct connections as fallback
    // when TURN server fails. This improves connection reliability.
    final configuration = {
      'iceServers': AppConstants.iceServers,
      'sdpSemantics': 'unified-plan',
      'iceTransportPolicy': 'all', // Was 'relay' - changed to allow STUN/direct fallback
      'bundlePolicy': 'max-bundle',
      'rtcpMuxPolicy': 'require',
    };

    // Additional constraints for better audio quality
    final constraints = {
      'mandatory': {},
      'optional': [
        {'googCpuOveruseDetection': false}, // Disable CPU overuse detection for consistent audio
        {'googDscp': true}, // Enable DSCP for QoS
      ],
    };

    final pc = await createPeerConnection(configuration, constraints);

    // Handle ICE candidates
    pc.onIceCandidate = (RTCIceCandidate candidate) {
      if (candidate.candidate == null || candidate.candidate!.isEmpty) return;

      _wsService.sendIceCandidate(
        roomId: channelId,
        candidate: candidate.candidate!,
        sdpMid: candidate.sdpMid!,
        sdpMLineIndex: candidate.sdpMLineIndex!,
        targetUserId: peerId,
      );
    };

    // Handle connection state
    pc.onConnectionState = (RTCPeerConnectionState state) {
      debugPrint('SimpleStream: Connection state for $peerId: $state');
      if (state == RTCPeerConnectionState.RTCPeerConnectionStateFailed ||
          state == RTCPeerConnectionState.RTCPeerConnectionStateClosed) {
        _connectedListeners.remove(peerId);
        _listenerCountController.add(_connectedListeners.length);
        // FIXED: Only close if still in the map (avoid concurrent modification during bulk cleanup)
        if (_peerConnections.containsKey(peerId)) {
          _closePeerConnectionFor(peerId);
        }
      }
    };

    // Handle incoming tracks
    pc.onTrack = (RTCTrackEvent event) {
      debugPrint('SimpleStream: onTrack - ${event.track.kind}');

      // CRITICAL: Ignore tracks if we're no longer in listening state
      // This handles the race condition where floor is released before track arrives
      if (_state != SimpleLiveStreamingState.listening) {
        debugPrint('SimpleStream: Ignoring track - not in listening state (state: $_state)');
        return;
      }

      if (event.track.kind == 'audio' && event.streams.isNotEmpty) {
        final stream = event.streams.first;
        _remoteStream = stream;

        // Check if this is a recovery track
        final wasRecovery = !_hasReceivedAudioTrack && _recoveryAttemptCount > 0;
        if (wasRecovery) {
          debugPrint('SimpleStream: Audio track received during RECOVERY! (attempt $_recoveryAttemptCount)');
        }

        // Mark that we've received audio - cancel timeouts
        _hasReceivedAudioTrack = true;
        _cancelListeningTimeout();
        _recoveryTimeoutTimer?.cancel();
        _recoveryAttemptCount = 0;
        debugPrint('SimpleStream: Audio track received! Cancelling timeouts.');

        // CRITICAL: Aggressively configure audio when track is received
        // This is especially important when coming from background with display off
        _activateAudioForTrack();

        // Enable audio track
        event.track.enabled = !_isMuted;
        for (final track in stream.getAudioTracks()) {
          track.enabled = !_isMuted;
          debugPrint('SimpleStream: Enabled audio track, muted: $_isMuted');
        }

        _remoteStreamController.add(stream);
        debugPrint('SimpleStream: Remote audio stream ready');

        // Start audio flow verification for this peer
        // This will detect silent audio and trigger recovery if needed
        _startAudioFlowVerification(pc, peerId);

        // Start a secondary verification to ensure audio starts flowing
        // within 3 seconds of track reception
        _startPostTrackAudioVerification(peerId);
      }
    };

    pc.onIceConnectionState = (RTCIceConnectionState state) {
      debugPrint('SimpleStream: ICE state for $peerId: $state');

      if (state == RTCIceConnectionState.RTCIceConnectionStateConnected ||
          state == RTCIceConnectionState.RTCIceConnectionStateCompleted) {
        debugPrint('SimpleStream: ICE connected to $peerId - audio should flow');
        if (_isBroadcasting) {
          _connectedListeners.add(peerId);
          _listenerCountController.add(_connectedListeners.length);
        }
      } else if (state == RTCIceConnectionState.RTCIceConnectionStateFailed ||
                 state == RTCIceConnectionState.RTCIceConnectionStateDisconnected) {
        _connectedListeners.remove(peerId);
        _listenerCountController.add(_connectedListeners.length);
      }
    };

    return pc;
  }

  /// Aggressively activate audio when track is received
  /// This is critical for audio playback when app was in background with display off
  Future<void> _activateAudioForTrack() async {
    debugPrint('SimpleStream: Activating audio for received track');

    try {
      // Step 1: Wake screen if needed (ensures audio path is active)
      try {
        await NativeAudioService.wakeScreen();
      } catch (e) {
        // Screen might already be on, ignore
      }

      // Step 2: Set audio mode for voice communication
      await NativeAudioService.setAudioModeForVoiceChat();

      // Step 3: Enable speaker output
      await NativeAudioService.setSpeakerOn(true);

      // Step 4: Boost volume for clearer audio (especially at low volumes)
      try {
        final volumeResult = await NativeAudioService.boostVoiceCallVolume();
        if (volumeResult['boosted'] == true) {
          debugPrint('SimpleStream: Volume boosted for clearer audio');
        }
      } catch (e) {
        debugPrint('SimpleStream: Volume boost failed (non-critical): $e');
      }

      debugPrint('SimpleStream: Audio activated successfully for track');
    } catch (e) {
      debugPrint('SimpleStream: Initial audio activation failed: $e');

      // Retry with delay
      await Future.delayed(const Duration(milliseconds: 300));

      try {
        await NativeAudioService.setAudioModeForVoiceChat();
        await NativeAudioService.setSpeakerOn(true);
        // Also try volume boost on retry
        await NativeAudioService.boostVoiceCallVolume();
        debugPrint('SimpleStream: Audio activation retry succeeded');
      } catch (e2) {
        debugPrint('SimpleStream: Audio activation retry failed: $e2');

        // Final retry
        await Future.delayed(const Duration(milliseconds: 500));
        try {
          await NativeAudioService.setAudioModeForVoiceChat();
          await NativeAudioService.setSpeakerOn(true);
          debugPrint('SimpleStream: Audio activation final retry succeeded');
        } catch (e3) {
          debugPrint('SimpleStream: All audio activation attempts failed: $e3');
        }
      }
    }
  }

  /// Start monitoring audio flow using RTP stats
  /// Detects "silent audio" where connection exists but no audio flows
  /// Triggers automatic recovery by requesting new offer from speaker
  void _startAudioFlowVerification(RTCPeerConnection pc, String peerId) {
    _stopAudioFlowVerification();
    _lastBytesReceived = 0;
    _silentCheckCount = 0;
    _silentAudioRecoveryCount = 0;
    _recoveryAttemptCount = 0; // Reset recovery attempts for new connection

    _audioFlowTimer = Timer.periodic(const Duration(seconds: 1), (timer) async {
      // Don't verify if we're not in listening state anymore
      if (_state != SimpleLiveStreamingState.listening) {
        timer.cancel();
        return;
      }

      try {
        final stats = await pc.getStats();
        int totalBytesReceived = 0;

        for (final report in stats) {
          if (report.type == 'inbound-rtp' && report.values['kind'] == 'audio') {
            totalBytesReceived += (report.values['bytesReceived'] as int?) ?? 0;
          }
        }

        if (totalBytesReceived > _lastBytesReceived) {
          // Audio is flowing - reset all counters and cancel recovery timer
          _silentCheckCount = 0;
          _silentAudioRecoveryCount = 0;
          _recoveryAttemptCount = 0;
          _recoveryTimeoutTimer?.cancel();
          _audioFlowController.add(true);
          // Only log occasionally to reduce noise
          if (totalBytesReceived - _lastBytesReceived > 1000) {
            debugPrint('SimpleStream: Audio flowing from $peerId');
          }
        } else {
          // No new audio bytes
          _silentCheckCount++;
          if (_silentCheckCount >= _maxSilentChecks) {
            debugPrint('SimpleStream: WARNING - No audio flow from $peerId for $_silentCheckCount seconds');
            _audioFlowController.add(false);

            // Trigger recovery - request new offer from speaker
            if (_silentAudioRecoveryCount < _maxSilentAudioRecoveries && _currentSpeakerId != null) {
              _silentAudioRecoveryCount++;
              final speakerId = _currentSpeakerId!;
              debugPrint('SimpleStream: Silent audio detected - initiating recovery attempt $_silentAudioRecoveryCount/$_maxSilentAudioRecoveries');

              // Close the silent connection and request a fresh offer
              await _closePeerConnectionFor(peerId);
              _hasReceivedAudioTrack = false;

              // Re-configure audio mode to ensure it's properly set
              await NativeAudioService.setAudioModeForVoiceChat();
              await NativeAudioService.setSpeakerOn(true);

              // Request new offer from speaker
              _wsService.requestWebRtcOffer(channelId, speakerId);

              // CRITICAL: Start recovery timeout to detect if offer doesn't arrive
              _startRecoveryTimeout(speakerId);

              // Reset silent check count for the new connection attempt
              _silentCheckCount = 0;
            } else if (_silentAudioRecoveryCount >= _maxSilentAudioRecoveries) {
              debugPrint('SimpleStream: Max silent audio recoveries reached ($_maxSilentAudioRecoveries)');
              // Stop verification to avoid continuous warnings
              timer.cancel();
            }
          }
        }

        _lastBytesReceived = totalBytesReceived;
      } catch (e) {
        debugPrint('SimpleStream: Error checking audio flow: $e');
      }
    });
  }

  /// Stop audio flow verification
  void _stopAudioFlowVerification() {
    _audioFlowTimer?.cancel();
    _audioFlowTimer = null;
    _postTrackVerificationTimer?.cancel();
    _postTrackVerificationTimer = null;
    _recoveryTimeoutTimer?.cancel();
    _recoveryTimeoutTimer = null;
    _silentCheckCount = 0;
    _recoveryAttemptCount = 0;
  }

  Timer? _postTrackVerificationTimer;

  /// Verify audio starts flowing within 3 seconds of track reception
  /// This catches cases where track arrives but audio never flows
  void _startPostTrackAudioVerification(String peerId) {
    _postTrackVerificationTimer?.cancel();

    _postTrackVerificationTimer = Timer(const Duration(seconds: 3), () async {
      // Only check if we're still in listening state
      if (_state != SimpleLiveStreamingState.listening) return;

      final pc = _peerConnections[peerId];
      if (pc == null) return;

      try {
        final stats = await pc.getStats();
        int bytesReceived = 0;

        for (final report in stats) {
          if (report.type == 'inbound-rtp' && report.values['kind'] == 'audio') {
            bytesReceived += (report.values['bytesReceived'] as int?) ?? 0;
          }
        }

        if (bytesReceived == 0 && _currentSpeakerId != null) {
          debugPrint('SimpleStream: Post-track verification FAILED - no audio bytes received after 3s');
          debugPrint('SimpleStream: Requesting fresh offer from speaker');

          final speakerId = _currentSpeakerId!;

          // Audio track arrived but no RTP packets - request new offer
          await _closePeerConnectionFor(peerId);
          _hasReceivedAudioTrack = false;

          // Reconfigure audio
          await NativeAudioService.setAudioModeForVoiceChat();
          await NativeAudioService.setSpeakerOn(true);

          _wsService.requestWebRtcOffer(channelId, speakerId);

          // CRITICAL: Set a timeout to detect if recovery fails
          // This ensures we don't get stuck if the new offer never arrives
          _startRecoveryTimeout(speakerId);
        } else {
          debugPrint('SimpleStream: Post-track verification OK - $bytesReceived bytes received');
        }
      } catch (e) {
        debugPrint('SimpleStream: Post-track verification error: $e');
      }
    });
  }

  /// Track recovery attempts to prevent infinite loops
  int _recoveryAttemptCount = 0;
  static const int _maxRecoveryAttempts = 3;
  Timer? _recoveryTimeoutTimer;

  /// Start a timeout to detect if recovery offer request fails
  void _startRecoveryTimeout(String speakerId) {
    _recoveryTimeoutTimer?.cancel();

    _recoveryTimeoutTimer = Timer(const Duration(seconds: 5), () async {
      // If we still haven't received audio after recovery attempt
      if (_state == SimpleLiveStreamingState.listening && !_hasReceivedAudioTrack) {
        _recoveryAttemptCount++;
        debugPrint('SimpleStream: Recovery timeout - attempt $_recoveryAttemptCount/$_maxRecoveryAttempts');

        if (_recoveryAttemptCount < _maxRecoveryAttempts) {
          // Try again - reconfigure audio and request new offer
          debugPrint('SimpleStream: Retrying recovery for $speakerId');

          await NativeAudioService.setAudioModeForVoiceChat();
          await NativeAudioService.setSpeakerOn(true);

          _wsService.requestWebRtcOffer(channelId, speakerId);

          // Set another timeout
          _startRecoveryTimeout(speakerId);
        } else {
          debugPrint('SimpleStream: Max recovery attempts reached - giving up');
          _recoveryAttemptCount = 0;
          _audioFlowController.add(false);
        }
      } else {
        // Recovery succeeded or state changed
        _recoveryAttemptCount = 0;
      }
    });
  }

  /// Close peer connection for a specific peer
  Future<void> _closePeerConnectionFor(String peerId) async {
    _pendingIceCandidates.remove(peerId);
    _connectedListeners.remove(peerId);
    _stopAudioFlowVerification();

    final pc = _peerConnections.remove(peerId);
    if (pc != null) {
      try {
        await pc.close();
      } catch (e) {
        debugPrint('SimpleStream: Error closing connection to $peerId: $e');
      }
    }

    if (peerId == _currentSpeakerPeerId) {
      _currentSpeakerPeerId = null;
      if (_remoteStream != null) {
        await _remoteStream!.dispose();
        _remoteStream = null;
      }
    }
  }

  /// Close all peer connections
  /// FIXED: Create a copy of entries to avoid concurrent modification
  Future<void> _closeAllPeerConnections() async {
    _stopAudioFlowVerification();
    _pendingIceCandidates.clear();
    _connectedListeners.clear();

    // CRITICAL: Create a copy of the map to avoid concurrent modification
    // The pc.close() can trigger onConnectionState callbacks that modify the map
    final connectionsToClose = Map<String, RTCPeerConnection>.from(_peerConnections);
    _peerConnections.clear(); // Clear immediately to prevent callback modifications

    for (final entry in connectionsToClose.entries) {
      try {
        await entry.value.close();
      } catch (e) {
        debugPrint('SimpleStream: Error closing connection to ${entry.key}: $e');
      }
    }

    if (_remoteStream != null) {
      try {
        await _remoteStream!.dispose();
      } catch (e) {
        debugPrint('SimpleStream: Error disposing remote stream: $e');
      }
      _remoteStream = null;
    }

    _currentSpeakerPeerId = null;
    _listenerCountController.add(0);
  }

  /// Dispose local stream
  Future<void> _disposeLocalStream() async {
    if (_localStream == null) return;

    try {
      for (final track in _localStream!.getTracks()) {
        await track.stop();
      }
      await _localStream!.dispose();
      _localStream = null;
    } catch (e) {
      debugPrint('SimpleStream: Error disposing local stream: $e');
      _localStream = null;
    }
  }

  /// Enable/disable local audio
  void _setLocalAudioEnabled(bool enabled) {
    if (_localStream != null) {
      for (final track in _localStream!.getAudioTracks()) {
        track.enabled = enabled;
      }
    }
  }

  /// Update state
  void _updateState(SimpleLiveStreamingState newState) {
    if (_state != newState) {
      _state = newState;
      _stateController.add(newState);
      debugPrint('SimpleStream state: $newState');
    }
  }

  /// Optimize SDP for better voice quality when receiving audio
  /// This modifies Opus codec parameters for higher bitrate and better clarity
  String _optimizeSdpForVoiceReceiving(String sdp) {
    // Find the Opus codec line and add optimized parameters
    // Opus params: maxaveragebitrate=128000 (128kbps for clear voice)
    //              stereo=0 (mono for voice)
    //              useinbandfec=1 (forward error correction)
    //              usedtx=0 (disable discontinuous transmission)
    //              maxplaybackrate=48000 (full sample rate)
    //              sprop-maxcapturerate=48000
    //              minptime=10 (minimum packet time)
    //              ptime=20 (packet time)

    final lines = sdp.split('\n');
    final result = <String>[];

    for (int i = 0; i < lines.length; i++) {
      final line = lines[i];
      result.add(line);

      // After the Opus rtpmap line, add fmtp line with optimized params
      // Look for: a=rtpmap:111 opus/48000/2
      if (line.contains('opus/48000')) {
        // Extract payload type (usually 111)
        final match = RegExp(r'a=rtpmap:(\d+)\s+opus').firstMatch(line);
        if (match != null) {
          final payloadType = match.group(1);

          // Check if next line already has fmtp for this payload
          bool hasExistingFmtp = false;
          for (int j = i + 1; j < lines.length && j < i + 5; j++) {
            if (lines[j].startsWith('a=fmtp:$payloadType')) {
              // Modify existing fmtp line to add our parameters
              final existingFmtp = lines[j];

              // Add our optimized parameters if not present
              String newFmtp = existingFmtp;
              if (!newFmtp.contains('maxaveragebitrate')) {
                newFmtp = '$newFmtp;maxaveragebitrate=128000';
              }
              if (!newFmtp.contains('useinbandfec')) {
                newFmtp = '$newFmtp;useinbandfec=1';
              }
              if (!newFmtp.contains('usedtx')) {
                newFmtp = '$newFmtp;usedtx=0';
              }
              if (!newFmtp.contains('maxplaybackrate')) {
                newFmtp = '$newFmtp;maxplaybackrate=48000';
              }
              if (!newFmtp.contains('stereo')) {
                newFmtp = '$newFmtp;stereo=0';
              }

              // Replace the line in the original array
              lines[j] = newFmtp;
              hasExistingFmtp = true;
              break;
            }
          }

          // If no existing fmtp, we'll add it when we encounter the line
          // (already handled above by modifying lines array)
        }
      }
    }

    final optimizedSdp = result.join('\n');
    debugPrint('SimpleStream: SDP optimized for voice receiving');
    return optimizedSdp;
  }

  /// Optimize SDP for better voice quality when broadcasting
  /// Higher bitrate and quality settings for outgoing audio
  String _optimizeSdpForVoiceBroadcasting(String sdp) {
    final lines = sdp.split('\n');
    final result = <String>[];

    for (final line in lines) {
      if (line.startsWith('a=fmtp:') && line.contains('opus')) {
        // Add optimized Opus parameters for broadcasting
        String newLine = line;
        if (!newLine.contains('maxaveragebitrate')) {
          newLine = '$newLine;maxaveragebitrate=128000';
        }
        if (!newLine.contains('useinbandfec')) {
          newLine = '$newLine;useinbandfec=1';
        }
        if (!newLine.contains('usedtx')) {
          newLine = '$newLine;usedtx=0';
        }
        if (!newLine.contains('cbr')) {
          newLine = '$newLine;cbr=0'; // Variable bitrate for better quality
        }
        result.add(newLine);
      } else {
        result.add(line);
      }
    }

    debugPrint('SimpleStream: SDP optimized for voice broadcasting');
    return result.join('\n');
  }

  /// Dispose resources
  Future<void> dispose() async {
    Logger.d('Disposing SimpleLiveStreamingService for $channelId');

    // Clear active channel if this was the active one
    _clearActiveChannelIfSelf();

    _floorRequestTimeout?.cancel();
    _cancelListeningTimeout();
    _postTrackVerificationTimer?.cancel();
    _recoveryTimeoutTimer?.cancel();

    await _offerSubscription?.cancel();
    await _answerSubscription?.cancel();
    await _iceSubscription?.cancel();
    await _floorSubscription?.cancel();
    await _floorDeniedSubscription?.cancel();
    await _connectionSubscription?.cancel();
    await _memberJoinedSubscription?.cancel();
    await _offerRequestSubscription?.cancel();

    await _closeAllPeerConnections();
    await _disposeLocalStream();

    try {
      await NativeAudioService.resetAudioMode();
    } catch (e) {
      debugPrint('SimpleStream: Error resetting audio: $e');
    }

    await _stateController.close();
    await _remoteStreamController.close();
    await _speakerController.close();
    await _listenerCountController.close();
    await _audioFlowController.close();
  }
}
