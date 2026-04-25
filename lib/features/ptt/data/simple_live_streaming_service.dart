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
  static const Duration _listeningTimeout = Duration(seconds: 5);
  bool _hasReceivedAudioTrack = false;
  int _offerRetryCount = 0;
  static const int _maxOfferRetries = 2;

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

  SimpleLiveStreamingService({
    required this.channelId,
    required WebSocketSignalingService wsService,
  }) : _wsService = wsService {
    _setupListeners();
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
      if (event.roomId == channelId && _isBroadcasting && _localStream != null) {
        debugPrint('SimpleStream: Listener ${event.fromUserId} requested offer - resending');
        await _createAndSendOffer(event.fromUserId);
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

      final constraints = {
        'audio': {
          'echoCancellation': true,
          'noiseSuppression': true,
          'autoGainControl': true,
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
      _currentSpeakerId = null;
      _speakerController.add((id: null, name: null));
      _cancelListeningTimeout();
      _hasReceivedAudioTrack = false;
      _offerRetryCount = 0;

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
      _offerRetryCount = 0;
      _updateState(SimpleLiveStreamingState.listening);

      // Start timeout to detect if we don't receive audio
      _startListeningTimeout(floor.speakerId);
    }
  }

  /// Start a timeout to detect if we don't receive audio while "listening"
  void _startListeningTimeout(String speakerId) {
    _cancelListeningTimeout();

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
  }

  /// Request offer from speaker when we haven't received one
  void _requestOfferFromSpeaker(String speakerId) {
    if (_offerRetryCount >= _maxOfferRetries) {
      debugPrint('SimpleStream: Max offer retries reached ($_maxOfferRetries), giving up');
      return;
    }

    _offerRetryCount++;
    debugPrint('SimpleStream: Requesting offer from speaker (attempt $_offerRetryCount/$_maxOfferRetries)');

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

      await pc.setLocalDescription(offer);

      _wsService.sendOffer(
        roomId: channelId,
        sdp: offer.sdp!,
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

    try {
      // Configure audio for receiving
      await NativeAudioService.setAudioModeForVoiceChat();
      await NativeAudioService.setSpeakerOn(true);

      // Close existing connection to this speaker if any
      await _closePeerConnectionFor(fromUserId);

      // Create peer connection for receiving
      final pc = await _createPeerConnection(fromUserId);
      _peerConnections[fromUserId] = pc;
      _currentSpeakerPeerId = fromUserId;

      // Add transceiver for receiving audio
      await pc.addTransceiver(
        kind: RTCRtpMediaType.RTCRtpMediaTypeAudio,
        init: RTCRtpTransceiverInit(direction: TransceiverDirection.RecvOnly),
      );

      // Set remote description
      await pc.setRemoteDescription(RTCSessionDescription(sdp, 'offer'));

      // Apply pending ICE candidates for this peer
      await _applyPendingIceCandidatesFor(fromUserId);

      // Create answer
      final answer = await pc.createAnswer({
        'offerToReceiveAudio': true,
        'offerToReceiveVideo': false,
      });

      await pc.setLocalDescription(answer);

      _wsService.sendAnswer(
        roomId: channelId,
        targetUserId: fromUserId,
        sdp: answer.sdp!,
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
    final iceCandidate = RTCIceCandidate(candidate, sdpMid, sdpMLineIndex);

    final pc = _peerConnections[fromUserId];
    if (pc == null) {
      // Store pending candidate for this peer (with bounds)
      _pendingIceCandidates.putIfAbsent(fromUserId, () => []);
      if (_pendingIceCandidates[fromUserId]!.length < _maxPendingIceCandidates) {
        _pendingIceCandidates[fromUserId]!.add(iceCandidate);
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
      }
      return;
    }

    try {
      await pc.addCandidate(iceCandidate);
    } catch (e) {
      debugPrint('SimpleStream: Failed to add ICE candidate from $fromUserId: $e');
    }
  }

  /// Apply pending ICE candidates for a specific peer
  Future<void> _applyPendingIceCandidatesFor(String peerId) async {
    final pc = _peerConnections[peerId];
    final candidates = _pendingIceCandidates[peerId];
    if (pc == null || candidates == null || candidates.isEmpty) return;

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
    final configuration = {
      'iceServers': AppConstants.iceServers,
      'sdpSemantics': 'unified-plan',
      'iceTransportPolicy': 'relay',
      'bundlePolicy': 'max-bundle',
      'rtcpMuxPolicy': 'require',
    };

    final pc = await createPeerConnection(configuration);

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
        _closePeerConnectionFor(peerId);
      }
    };

    // Handle incoming tracks
    pc.onTrack = (RTCTrackEvent event) {
      debugPrint('SimpleStream: onTrack - ${event.track.kind}');

      if (event.track.kind == 'audio' && event.streams.isNotEmpty) {
        final stream = event.streams.first;
        _remoteStream = stream;

        // Mark that we've received audio - cancel the timeout
        _hasReceivedAudioTrack = true;
        _cancelListeningTimeout();
        debugPrint('SimpleStream: Audio track received! Cancelling timeout.');

        // Enable audio track
        event.track.enabled = !_isMuted;
        for (final track in stream.getAudioTracks()) {
          track.enabled = !_isMuted;
        }

        _remoteStreamController.add(stream);
        debugPrint('SimpleStream: Remote audio stream ready');

        // Start audio flow verification for this peer
        _startAudioFlowVerification(pc, peerId);
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

  /// Start monitoring audio flow using RTP stats
  /// Detects "silent audio" where connection exists but no audio flows
  void _startAudioFlowVerification(RTCPeerConnection pc, String peerId) {
    _stopAudioFlowVerification();
    _lastBytesReceived = 0;
    _silentCheckCount = 0;

    _audioFlowTimer = Timer.periodic(const Duration(seconds: 1), (timer) async {
      try {
        final stats = await pc.getStats();
        int totalBytesReceived = 0;

        for (final report in stats) {
          if (report.type == 'inbound-rtp' && report.values['kind'] == 'audio') {
            totalBytesReceived += (report.values['bytesReceived'] as int?) ?? 0;
          }
        }

        if (totalBytesReceived > _lastBytesReceived) {
          // Audio is flowing
          _silentCheckCount = 0;
          _audioFlowController.add(true);
          debugPrint('SimpleStream: Audio flowing from $peerId (${totalBytesReceived - _lastBytesReceived} bytes)');
        } else {
          // No new audio bytes
          _silentCheckCount++;
          if (_silentCheckCount >= _maxSilentChecks) {
            debugPrint('SimpleStream: WARNING - No audio flow from $peerId for $_silentCheckCount seconds');
            _audioFlowController.add(false);
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
    _silentCheckCount = 0;
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
  Future<void> _closeAllPeerConnections() async {
    _stopAudioFlowVerification();
    _pendingIceCandidates.clear();
    _connectedListeners.clear();

    for (final entry in _peerConnections.entries) {
      try {
        await entry.value.close();
      } catch (e) {
        debugPrint('SimpleStream: Error closing connection to ${entry.key}: $e');
      }
    }
    _peerConnections.clear();

    if (_remoteStream != null) {
      await _remoteStream!.dispose();
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

  /// Dispose resources
  Future<void> dispose() async {
    Logger.d('Disposing SimpleLiveStreamingService');

    _floorRequestTimeout?.cancel();
    _cancelListeningTimeout();

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
