import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

import '../../../core/constants/app_constants.dart';
import '../../../core/utils/logger.dart';
import 'websocket_signaling_service.dart';

/// Live streaming state
enum LiveStreamingState {
  idle,
  connecting,
  broadcasting,
  listening,
  error,
}

/// Provider for live streaming service per channel
final liveStreamingServiceProvider = Provider.autoDispose.family<LiveStreamingService, String>(
  (ref, channelId) {
    final wsService = ref.watch(websocketSignalingServiceProvider);
    final service = LiveStreamingService(
      channelId: channelId,
      wsService: wsService,
    );
    ref.onDispose(() => service.dispose());
    return service;
  },
);

/// Live streaming service - orchestrates WebRTC audio streaming
class LiveStreamingService {
  final String channelId;
  final WebSocketSignalingService _wsService;

  // WebRTC state
  MediaStream? _localStream;
  final Map<String, RTCPeerConnection> _peerConnections = {};
  final Map<String, MediaStream> _remoteStreams = {};
  final Map<String, List<RTCIceCandidate>> _pendingIceCandidates = {};
  final List<RTCIceCandidate> _localIceCandidates = [];
  Timer? _iceBatchTimer;

  // Stream subscriptions
  StreamSubscription? _offerSubscription;
  StreamSubscription? _answerSubscription;
  StreamSubscription? _iceSubscription;
  StreamSubscription? _floorSubscription;

  // State
  LiveStreamingState _state = LiveStreamingState.idle;
  bool _isBroadcasting = false;
  String? _currentSpeakerId;

  // Controllers
  final _stateController = StreamController<LiveStreamingState>.broadcast();
  final _remoteStreamController = StreamController<MediaStream>.broadcast();
  final _speakerController = StreamController<({String? id, String? name})>.broadcast();

  // Streams
  Stream<LiveStreamingState> get stateStream => _stateController.stream;
  Stream<MediaStream> get remoteStreamAdded => _remoteStreamController.stream;
  Stream<({String? id, String? name})> get currentSpeaker => _speakerController.stream;

  // Getters
  LiveStreamingState get state => _state;
  bool get isBroadcasting => _isBroadcasting;
  MediaStream? get localStream => _localStream;
  Map<String, MediaStream> get remoteStreams => Map.unmodifiable(_remoteStreams);

  LiveStreamingService({
    required this.channelId,
    required WebSocketSignalingService wsService,
  }) : _wsService = wsService {
    _setupListeners();
  }

  /// Setup WebSocket message listeners
  void _setupListeners() {
    // Listen for WebRTC offers (when someone starts speaking)
    _offerSubscription = _wsService.webrtcOffers.listen((event) {
      if (event.roomId == channelId) {
        _handleIncomingOffer(event.fromUserId, event.sdp);
      }
    });

    // Listen for WebRTC answers (responses to our offers)
    _answerSubscription = _wsService.webrtcAnswers.listen((event) {
      if (event.roomId == channelId) {
        _handleIncomingAnswer(event.fromUserId, event.sdp);
      }
    });

    // Listen for ICE candidates
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

    // Listen for floor state changes
    _floorSubscription = _wsService.floorState.listen((event) {
      if (event.roomId == channelId) {
        _handleFloorStateChange(event.state);
      }
    });
  }

  /// Initialize local audio stream
  Future<bool> initLocalStream() async {
    if (_localStream != null) return true;

    try {
      final constraints = {
        'audio': {
          'echoCancellation': true,
          'noiseSuppression': true,
          'autoGainControl': true,
          'sampleRate': AppConstants.audioSampleRate,
        },
        'video': false,
      };

      _localStream = await navigator.mediaDevices.getUserMedia(constraints);
      Logger.d('Local audio stream initialized');
      return true;
    } catch (e) {
      Logger.e('Failed to initialize local stream', error: e);
      _updateState(LiveStreamingState.error);
      return false;
    }
  }

  /// Start broadcasting (when PTT pressed)
  Future<bool> startBroadcasting() async {
    if (_isBroadcasting) {
      Logger.w('Already broadcasting');
      return false;
    }

    _updateState(LiveStreamingState.connecting);

    // Initialize local stream if needed
    if (_localStream == null) {
      final success = await initLocalStream();
      if (!success) return false;
    }

    // Request floor from server
    _wsService.requestFloor(channelId);

    // Wait for floor granted (handled in _handleFloorStateChange)
    // The actual WebRTC setup happens when floor is granted

    return true;
  }

  /// Stop broadcasting (when PTT released)
  Future<void> stopBroadcasting() async {
    if (!_isBroadcasting) return;

    Logger.d('Stopping broadcast');

    // Release floor
    _wsService.releaseFloor(channelId);

    // Close all peer connections
    await _closeAllPeerConnections();

    // Mute local stream but keep it for next broadcast
    _setLocalAudioEnabled(false);

    _isBroadcasting = false;
    _updateState(LiveStreamingState.idle);
  }

  /// Handle floor state changes
  void _handleFloorStateChange(WSFloorState? floor) {
    if (floor == null) {
      // Floor released
      _currentSpeakerId = null;
      _speakerController.add((id: null, name: null));

      if (_isBroadcasting) {
        // We were broadcasting and floor was released (timeout?)
        stopBroadcasting();
      } else {
        // Someone else stopped speaking
        _closeAllPeerConnections();
        _updateState(LiveStreamingState.idle);
      }
      return;
    }

    _currentSpeakerId = floor.speakerId;
    _speakerController.add((id: floor.speakerId, name: floor.speakerName));

    // Check if we got the floor
    if (floor.speakerId == _wsService.userId) {
      // We got the floor - start streaming
      _isBroadcasting = true;
      _updateState(LiveStreamingState.broadcasting);
      _setLocalAudioEnabled(true);
      _startStreamingToListeners();
    } else {
      // Someone else is speaking - prepare to receive
      _isBroadcasting = false;
      _updateState(LiveStreamingState.listening);
    }
  }

  /// Start streaming to all listeners in the room
  Future<void> _startStreamingToListeners() async {
    if (_localStream == null) {
      Logger.e('Cannot stream - no local stream');
      return;
    }

    Logger.d('Starting to stream to listeners');

    // Create and send offer to all room members
    // The offer is broadcast via WebSocket, and each listener responds with an answer
    final offer = await _createOffer();
    if (offer != null) {
      _wsService.sendOffer(
        roomId: channelId,
        sdp: offer.sdp!,
      );
    }
  }

  /// Create WebRTC offer for broadcasting
  Future<RTCSessionDescription?> _createOffer() async {
    try {
      // Create a "template" peer connection for offer generation
      final pc = await _createPeerConnection('broadcast');
      _peerConnections['broadcast'] = pc;

      // Add local stream
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

      await pc.setLocalDescription(offer);

      Logger.d('Created broadcast offer');
      return offer;
    } catch (e) {
      Logger.e('Failed to create offer', error: e);
      return null;
    }
  }

  /// Handle incoming offer (when someone starts speaking)
  Future<void> _handleIncomingOffer(String fromUserId, String sdp) async {
    // Skip our own offers
    if (fromUserId == _wsService.userId) return;

    Logger.d('Received offer from $fromUserId');

    try {
      // Create peer connection for this speaker
      final pc = await _createPeerConnection(fromUserId);
      _peerConnections[fromUserId] = pc;

      // Set remote description
      await pc.setRemoteDescription(RTCSessionDescription(sdp, 'offer'));

      // Apply any pending ICE candidates
      await _applyPendingIceCandidates(fromUserId);

      // Create answer
      final answer = await pc.createAnswer({
        'offerToReceiveAudio': true,
        'offerToReceiveVideo': false,
      });

      await pc.setLocalDescription(answer);

      // Send answer back
      _wsService.sendAnswer(
        roomId: channelId,
        targetUserId: fromUserId,
        sdp: answer.sdp!,
      );

      Logger.d('Sent answer to $fromUserId');
    } catch (e) {
      Logger.e('Failed to handle offer from $fromUserId', error: e);
    }
  }

  /// Handle incoming answer (response to our offer)
  Future<void> _handleIncomingAnswer(String fromUserId, String sdp) async {
    Logger.d('Received answer from $fromUserId');

    try {
      // Get or create peer connection
      RTCPeerConnection? pc = _peerConnections[fromUserId];

      if (pc == null) {
        // Create new connection for this listener
        pc = await _createPeerConnection(fromUserId);
        _peerConnections[fromUserId] = pc;

        // Add local stream for broadcasting
        if (_localStream != null) {
          for (final track in _localStream!.getTracks()) {
            await pc.addTrack(track, _localStream!);
          }
        }
      }

      // Set remote description
      await pc.setRemoteDescription(RTCSessionDescription(sdp, 'answer'));

      // Apply pending ICE candidates
      await _applyPendingIceCandidates(fromUserId);

      Logger.d('Handled answer from $fromUserId');
    } catch (e) {
      Logger.e('Failed to handle answer from $fromUserId', error: e);
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

    final pc = _peerConnections[fromUserId];
    final remoteDesc = await pc?.getRemoteDescription();

    if (pc == null || remoteDesc == null) {
      // Queue candidate until we have the connection ready
      _pendingIceCandidates.putIfAbsent(fromUserId, () => []);
      _pendingIceCandidates[fromUserId]!.add(iceCandidate);
      return;
    }

    try {
      await pc.addCandidate(iceCandidate);
    } catch (e) {
      Logger.e('Failed to add ICE candidate', error: e);
    }
  }

  /// Apply queued ICE candidates
  Future<void> _applyPendingIceCandidates(String peerId) async {
    final pending = _pendingIceCandidates[peerId];
    if (pending == null || pending.isEmpty) return;

    final pc = _peerConnections[peerId];
    if (pc == null) return;

    for (final candidate in pending) {
      try {
        await pc.addCandidate(candidate);
      } catch (e) {
        Logger.e('Failed to apply pending ICE candidate', error: e);
      }
    }

    _pendingIceCandidates[peerId]!.clear();
    Logger.d('Applied ${pending.length} pending ICE candidates for $peerId');
  }

  /// Create a WebRTC peer connection
  Future<RTCPeerConnection> _createPeerConnection(String peerId) async {
    final configuration = {
      'iceServers': AppConstants.iceServers,
      'sdpSemantics': 'unified-plan',
    };

    final pc = await createPeerConnection(configuration);

    // Handle local ICE candidates
    pc.onIceCandidate = (RTCIceCandidate candidate) {
      // Batch ICE candidates for efficiency
      _localIceCandidates.add(candidate);
      _scheduleIceBatch(peerId);
    };

    // Handle connection state
    pc.onConnectionState = (RTCPeerConnectionState state) {
      Logger.d('Connection state with $peerId: $state');

      if (state == RTCPeerConnectionState.RTCPeerConnectionStateFailed ||
          state == RTCPeerConnectionState.RTCPeerConnectionStateDisconnected) {
        _closePeerConnection(peerId);
      }
    };

    // Handle incoming tracks (for listeners)
    pc.onTrack = (RTCTrackEvent event) {
      if (event.streams.isNotEmpty) {
        final remoteStream = event.streams.first;
        _remoteStreams[peerId] = remoteStream;
        _remoteStreamController.add(remoteStream);
        Logger.d('Received remote stream from $peerId');
      }
    };

    pc.onIceConnectionState = (RTCIceConnectionState state) {
      Logger.d('ICE connection state with $peerId: $state');
    };

    return pc;
  }

  /// Schedule batched ICE candidate sending
  void _scheduleIceBatch(String peerId) {
    _iceBatchTimer?.cancel();
    _iceBatchTimer = Timer(const Duration(milliseconds: 100), () {
      _sendBatchedIceCandidates(peerId);
    });
  }

  /// Send batched ICE candidates
  void _sendBatchedIceCandidates(String targetUserId) {
    if (_localIceCandidates.isEmpty) return;

    final candidates = _localIceCandidates.map((c) => {
      'candidate': c.candidate!,
      'sdpMid': c.sdpMid!,
      'sdpMLineIndex': c.sdpMLineIndex!,
    }).toList();

    // For broadcast, send to all (no targetUserId)
    // For direct connection, send to specific user
    if (_isBroadcasting) {
      _wsService.sendIceCandidatesBatch(
        roomId: channelId,
        candidates: candidates,
      );
    } else {
      _wsService.sendIceCandidatesBatch(
        roomId: channelId,
        candidates: candidates,
        targetUserId: targetUserId,
      );
    }

    _localIceCandidates.clear();
    Logger.d('Sent ${candidates.length} ICE candidates');
  }

  /// Close a specific peer connection
  Future<void> _closePeerConnection(String peerId) async {
    final pc = _peerConnections.remove(peerId);
    if (pc != null) {
      await pc.close();
    }

    final stream = _remoteStreams.remove(peerId);
    if (stream != null) {
      await stream.dispose();
    }

    _pendingIceCandidates.remove(peerId);
  }

  /// Close all peer connections
  Future<void> _closeAllPeerConnections() async {
    for (final peerId in _peerConnections.keys.toList()) {
      await _closePeerConnection(peerId);
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
  void _updateState(LiveStreamingState newState) {
    if (_state != newState) {
      _state = newState;
      _stateController.add(newState);
      debugPrint('LiveStreaming state: $newState');
    }
  }

  /// Clean up resources
  Future<void> dispose() async {
    Logger.d('Disposing LiveStreamingService');

    _iceBatchTimer?.cancel();
    _offerSubscription?.cancel();
    _answerSubscription?.cancel();
    _iceSubscription?.cancel();
    _floorSubscription?.cancel();

    await _closeAllPeerConnections();

    if (_localStream != null) {
      for (final track in _localStream!.getTracks()) {
        await track.stop();
      }
      await _localStream!.dispose();
      _localStream = null;
    }

    await _stateController.close();
    await _remoteStreamController.close();
    await _speakerController.close();
  }
}
