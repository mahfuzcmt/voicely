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

  // WebRTC state - single peer connection only
  MediaStream? _localStream;
  RTCPeerConnection? _peerConnection;
  MediaStream? _remoteStream;
  String? _currentPeerId;

  // Pending ICE candidates (before remote description is set)
  final List<RTCIceCandidate> _pendingIceCandidates = [];

  // Stream subscriptions
  StreamSubscription? _offerSubscription;
  StreamSubscription? _answerSubscription;
  StreamSubscription? _iceSubscription;
  StreamSubscription? _floorSubscription;
  StreamSubscription? _floorDeniedSubscription;
  StreamSubscription? _connectionSubscription;
  StreamSubscription? _memberJoinedSubscription;
  Timer? _floorRequestTimeout;

  // State
  SimpleLiveStreamingState _state = SimpleLiveStreamingState.idle;
  bool _isBroadcasting = false;
  String? _currentSpeakerId;
  bool _isMuted = false;

  // Minimum broadcast duration for audio to establish
  static const Duration _minBroadcastDuration = Duration(milliseconds: 800);
  DateTime? _broadcastStartTime;

  // Controllers
  final _stateController =
      StreamController<SimpleLiveStreamingState>.broadcast();
  final _remoteStreamController = StreamController<MediaStream>.broadcast();
  final _speakerController =
      StreamController<({String? id, String? name})>.broadcast();
  final _listenerCountController = StreamController<int>.broadcast();

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
  int get activeListenerCount => _isBroadcasting ? 1 : 0; // Simplified

  SimpleLiveStreamingService({
    required this.channelId,
    required WebSocketSignalingService wsService,
  }) : _wsService = wsService {
    _setupListeners();
  }

  /// Set muted state for incoming audio
  void setMuted(bool muted) {
    _isMuted = muted;
    if (_remoteStream != null) {
      for (final track in _remoteStream!.getAudioTracks()) {
        track.enabled = !muted;
      }
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
          _closePeerConnection();
          _disposeLocalStream();
          _updateState(SimpleLiveStreamingState.idle);
        }
      }
    });

    // Listen for new members when broadcasting
    _memberJoinedSubscription = _wsService.roomMembers.listen((event) async {
      if (event.roomId == channelId && _isBroadcasting && _localStream != null) {
        final myUserId = _wsService.userId;
        for (final member in event.members) {
          if (member.userId != myUserId && _currentPeerId != member.userId) {
            debugPrint(
                'SimpleStream: New listener ${member.displayName}, sending offer');
            await _createAndSendOffer(member.userId);
          }
        }
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
    await _closePeerConnection();
    await _disposeLocalStream();
  }

  /// Force stop all connections
  Future<void> forceStopAllConnections() async {
    debugPrint('SimpleStream: Force stopping all connections');

    if (_isBroadcasting) {
      _isBroadcasting = false;
      _broadcastStartTime = null;
      _setLocalAudioEnabled(false);
    }

    await _closePeerConnection();
    await _disposeLocalStream();

    _currentSpeakerId = null;
    _updateState(SimpleLiveStreamingState.idle);
    _speakerController.add((id: null, name: null));
  }

  /// Handle floor state changes
  void _handleFloorStateChange(WSFloorState? floor) {
    _floorRequestTimeout?.cancel();
    _floorRequestTimeout = null;

    if (floor == null) {
      // Floor released
      _currentSpeakerId = null;
      _speakerController.add((id: null, name: null));

      if (_isBroadcasting) {
        _setLocalAudioEnabled(false);
        _isBroadcasting = false;
        _broadcastStartTime = null;
        _updateState(SimpleLiveStreamingState.idle);
        _closePeerConnection();
        _disposeLocalStream();
      } else {
        _closePeerConnection();
        _updateState(SimpleLiveStreamingState.idle);
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
      // Someone else is speaking
      debugPrint('SimpleStream: ${floor.speakerName} is speaking');
      if (_isBroadcasting) {
        _closePeerConnection();
        _disposeLocalStream();
        _broadcastStartTime = null;
      }
      _isBroadcasting = false;
      _updateState(SimpleLiveStreamingState.listening);
    }
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

  /// Start streaming to listeners
  Future<void> _startStreamingToListeners() async {
    if (_localStream == null) return;

    debugPrint('SimpleStream: Starting to stream');
    await _closePeerConnection();

    // Get listeners and send offers
    final members = _wsService.getRoomMembers(channelId);
    final myUserId = _wsService.userId;

    for (final member in members) {
      if (member.userId != myUserId) {
        debugPrint('SimpleStream: Sending offer to ${member.displayName}');
        await _createAndSendOffer(member.userId);
        break; // Only first listener for simplicity
      }
    }
  }

  /// Create and send offer to a listener
  Future<void> _createAndSendOffer(String listenerId) async {
    try {
      final pc = await _createPeerConnection(listenerId);
      _peerConnection = pc;
      _currentPeerId = listenerId;

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
        debugPrint('SimpleStream: Failed to create offer');
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
      Logger.e('Error creating offer', error: e);
      await _closePeerConnection();
    }
  }

  /// Handle incoming offer
  Future<void> _handleIncomingOffer(String fromUserId, String sdp) async {
    if (fromUserId == _wsService.userId) return;

    debugPrint('SimpleStream: Received offer from $fromUserId');

    try {
      // Configure audio for receiving
      await NativeAudioService.setAudioModeForVoiceChat();
      await NativeAudioService.setSpeakerOn(true);

      // Close existing connection
      await _closePeerConnection();

      // Create peer connection
      final pc = await _createPeerConnection(fromUserId);
      _peerConnection = pc;
      _currentPeerId = fromUserId;

      // Add transceiver for receiving audio
      await pc.addTransceiver(
        kind: RTCRtpMediaType.RTCRtpMediaTypeAudio,
        init: RTCRtpTransceiverInit(direction: TransceiverDirection.RecvOnly),
      );

      // Set remote description
      await pc.setRemoteDescription(RTCSessionDescription(sdp, 'offer'));

      // Apply pending ICE candidates
      await _applyPendingIceCandidates();

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
      await _closePeerConnection();
    }
  }

  /// Handle incoming answer
  Future<void> _handleIncomingAnswer(String fromUserId, String sdp) async {
    if (!_isBroadcasting || _peerConnection == null) return;

    debugPrint('SimpleStream: Received answer from $fromUserId');

    try {
      final signalingState = _peerConnection!.signalingState;
      if (signalingState == RTCSignalingState.RTCSignalingStateHaveLocalOffer) {
        await _peerConnection!
            .setRemoteDescription(RTCSessionDescription(sdp, 'answer'));
        await _applyPendingIceCandidates();
        debugPrint('SimpleStream: Answer processed');
        _listenerCountController.add(1);
      }
    } catch (e) {
      Logger.e('Failed to handle answer', error: e);
    }
  }

  /// Handle incoming ICE candidate
  Future<void> _handleIncomingIceCandidate(
    String fromUserId,
    String candidate,
    String sdpMid,
    int sdpMLineIndex,
  ) async {
    final iceCandidate = RTCIceCandidate(candidate, sdpMid, sdpMLineIndex);

    if (_peerConnection == null) {
      _pendingIceCandidates.add(iceCandidate);
      return;
    }

    final remoteDesc = await _peerConnection!.getRemoteDescription();
    if (remoteDesc == null) {
      _pendingIceCandidates.add(iceCandidate);
      return;
    }

    try {
      await _peerConnection!.addCandidate(iceCandidate);
    } catch (e) {
      debugPrint('SimpleStream: Failed to add ICE candidate: $e');
    }
  }

  /// Apply pending ICE candidates
  Future<void> _applyPendingIceCandidates() async {
    if (_peerConnection == null || _pendingIceCandidates.isEmpty) return;

    for (final candidate in _pendingIceCandidates) {
      try {
        await _peerConnection!.addCandidate(candidate);
      } catch (e) {
        debugPrint('SimpleStream: Failed to apply pending ICE: $e');
      }
    }
    _pendingIceCandidates.clear();
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
      debugPrint('SimpleStream: Connection state: $state');
      if (state == RTCPeerConnectionState.RTCPeerConnectionStateFailed) {
        _closePeerConnection();
      }
    };

    // Handle incoming tracks
    pc.onTrack = (RTCTrackEvent event) {
      debugPrint('SimpleStream: onTrack - ${event.track.kind}');

      if (event.track.kind == 'audio' && event.streams.isNotEmpty) {
        final stream = event.streams.first;
        _remoteStream = stream;

        // Enable audio track
        event.track.enabled = !_isMuted;
        for (final track in stream.getAudioTracks()) {
          track.enabled = !_isMuted;
        }

        _remoteStreamController.add(stream);
        debugPrint('SimpleStream: Remote audio stream ready');
      }
    };

    pc.onIceConnectionState = (RTCIceConnectionState state) {
      debugPrint('SimpleStream: ICE state: $state');

      if (state == RTCIceConnectionState.RTCIceConnectionStateConnected ||
          state == RTCIceConnectionState.RTCIceConnectionStateCompleted) {
        debugPrint('SimpleStream: ICE connected - audio should flow');
      } else if (state == RTCIceConnectionState.RTCIceConnectionStateFailed) {
        _closePeerConnection();
      }
    };

    return pc;
  }

  /// Close peer connection
  Future<void> _closePeerConnection() async {
    _pendingIceCandidates.clear();

    if (_peerConnection != null) {
      await _peerConnection!.close();
      _peerConnection = null;
    }

    if (_remoteStream != null) {
      await _remoteStream!.dispose();
      _remoteStream = null;
    }

    _currentPeerId = null;
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

    await _offerSubscription?.cancel();
    await _answerSubscription?.cancel();
    await _iceSubscription?.cancel();
    await _floorSubscription?.cancel();
    await _floorDeniedSubscription?.cancel();
    await _connectionSubscription?.cancel();
    await _memberJoinedSubscription?.cancel();

    await _closePeerConnection();
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
  }
}
