import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

import '../../../core/constants/app_constants.dart';
import '../../../core/utils/logger.dart';
import 'signaling_repository.dart';

final webrtcServiceProvider = Provider.autoDispose.family<WebRTCService, String>(
  (ref, channelId) {
    final signalingRepo = ref.watch(signalingRepositoryProvider);
    final service = WebRTCService(
      channelId: channelId,
      signalingRepository: signalingRepo,
    );

    ref.onDispose(() {
      service.dispose();
    });

    return service;
  },
);

/// WebRTC service for peer-to-peer audio streaming
/// Supports both legacy Firestore-based signaling and new WebSocket-based signaling
class WebRTCService {
  final String channelId;
  final SignalingRepository _signalingRepository;

  MediaStream? _localStream;
  final Map<String, RTCPeerConnection> _peerConnections = {};
  final Map<String, MediaStream> _remoteStreams = {};
  final Map<String, List<RTCIceCandidate>> _pendingIceCandidates = {};
  final List<RTCIceCandidate> _localIceCandidates = [];
  Timer? _iceBatchTimer;

  String? _currentUserId;
  bool _isLiveMode = false;

  final _remoteStreamController = StreamController<MediaStream>.broadcast();
  Stream<MediaStream> get remoteStreamAdded => _remoteStreamController.stream;

  final _connectionStateController =
      StreamController<Map<String, RTCPeerConnectionState>>.broadcast();
  Stream<Map<String, RTCPeerConnectionState>> get connectionStates =>
      _connectionStateController.stream;

  // Callback for ICE candidates (used in live mode)
  void Function(RTCIceCandidate candidate, String? targetUserId)? onIceCandidate;

  WebRTCService({
    required this.channelId,
    required SignalingRepository signalingRepository,
  }) : _signalingRepository = signalingRepository;

  MediaStream? get localStream => _localStream;
  Map<String, MediaStream> get remoteStreams => Map.unmodifiable(_remoteStreams);

  /// Enable live streaming mode (uses WebSocket for signaling)
  void setLiveMode(bool enabled) {
    _isLiveMode = enabled;
  }

  /// Initialize local audio stream (microphone access)
  Future<MediaStream?> initLocalStream() async {
    try {
      // Try with full audio constraints first
      final constraints = {
        'audio': {
          'echoCancellation': true,
          'noiseSuppression': true,
          'autoGainControl': true,
          'sampleRate': AppConstants.audioSampleRate,
        },
        'video': false,
      };

      try {
        _localStream = await navigator.mediaDevices.getUserMedia(constraints);
        Logger.d('Local audio stream initialized with full constraints');
        return _localStream;
      } catch (e) {
        // Fallback to simpler constraints if device doesn't support all options
        Logger.w('Full audio constraints failed, trying fallback: $e');
        final fallbackConstraints = {
          'audio': true,
          'video': false,
        };
        _localStream = await navigator.mediaDevices.getUserMedia(fallbackConstraints);
        Logger.d('Local audio stream initialized with fallback constraints');
        return _localStream;
      }
    } catch (e) {
      Logger.e('Failed to initialize local stream', error: e);
      return null;
    }
  }

  /// Create peer connection and send offer to a specific peer
  Future<void> createOfferAndSend({
    required String currentUserId,
    required String peerId,
  }) async {
    _currentUserId = currentUserId;

    try {
      final pc = await _createPeerConnection(peerId);
      _peerConnections[peerId] = pc;

      // Add local stream tracks to peer connection
      if (_localStream != null) {
        for (final track in _localStream!.getTracks()) {
          await pc.addTrack(track, _localStream!);
        }
      }

      // Create offer
      final offer = await pc.createOffer({
        'offerToReceiveAudio': true,
        'offerToReceiveVideo': false,
      });

      await pc.setLocalDescription(offer);

      // Send offer via signaling
      await _signalingRepository.sendOffer(
        channelId: channelId,
        fromUserId: currentUserId,
        toUserId: peerId,
        sdp: offer.sdp!,
      );

      Logger.d('Created and sent offer to $peerId');
    } catch (e) {
      Logger.e('Failed to create offer for $peerId', error: e);
      rethrow;
    }
  }

  /// Handle incoming offer and create answer
  Future<void> handleOffer({
    required String currentUserId,
    required String fromUserId,
    required String sdp,
  }) async {
    _currentUserId = currentUserId;

    try {
      // Create peer connection if not exists
      RTCPeerConnection pc;
      if (_peerConnections.containsKey(fromUserId)) {
        pc = _peerConnections[fromUserId]!;
      } else {
        pc = await _createPeerConnection(fromUserId);
        _peerConnections[fromUserId] = pc;
      }

      // Set remote description (the offer)
      await pc.setRemoteDescription(RTCSessionDescription(sdp, 'offer'));

      // Apply any pending ICE candidates
      await _applyPendingIceCandidates(fromUserId);

      // Create answer
      final answer = await pc.createAnswer({
        'offerToReceiveAudio': true,
        'offerToReceiveVideo': false,
      });

      await pc.setLocalDescription(answer);

      // Send answer via signaling
      await _signalingRepository.sendAnswer(
        channelId: channelId,
        fromUserId: currentUserId,
        toUserId: fromUserId,
        sdp: answer.sdp!,
      );

      Logger.d('Handled offer from $fromUserId and sent answer');
    } catch (e) {
      Logger.e('Failed to handle offer from $fromUserId', error: e);
      rethrow;
    }
  }

  /// Handle incoming answer
  Future<void> handleAnswer({
    required String fromUserId,
    required String sdp,
  }) async {
    try {
      final pc = _peerConnections[fromUserId];
      if (pc == null) {
        Logger.w('No peer connection found for $fromUserId');
        return;
      }

      await pc.setRemoteDescription(RTCSessionDescription(sdp, 'answer'));

      // Apply any pending ICE candidates
      await _applyPendingIceCandidates(fromUserId);

      Logger.d('Handled answer from $fromUserId');
    } catch (e) {
      Logger.e('Failed to handle answer from $fromUserId', error: e);
    }
  }

  /// Handle incoming ICE candidate
  Future<void> handleIceCandidate({
    required String fromUserId,
    required String candidate,
    required String sdpMid,
    required int sdpMLineIndex,
  }) async {
    try {
      final iceCandidate = RTCIceCandidate(candidate, sdpMid, sdpMLineIndex);

      final pc = _peerConnections[fromUserId];
      final remoteDesc = await pc?.getRemoteDescription();
      if (pc == null || remoteDesc == null) {
        // Store pending ICE candidates until remote description is set
        _pendingIceCandidates.putIfAbsent(fromUserId, () => []);
        _pendingIceCandidates[fromUserId]!.add(iceCandidate);
        Logger.d('Queued ICE candidate for $fromUserId');
        return;
      }

      await pc.addCandidate(iceCandidate);
      Logger.d('Added ICE candidate from $fromUserId');
    } catch (e) {
      Logger.e('Failed to handle ICE candidate from $fromUserId', error: e);
    }
  }

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

  Future<RTCPeerConnection> _createPeerConnection(String peerId) async {
    final configuration = {
      'iceServers': AppConstants.iceServers,
      'sdpSemantics': 'unified-plan',
    };

    final pc = await createPeerConnection(configuration);

    // Handle ICE candidates
    pc.onIceCandidate = (RTCIceCandidate candidate) {
      // Validate candidate fields before processing
      if (candidate.candidate == null || candidate.candidate!.isEmpty) {
        Logger.d('Skipping ICE candidate with null/empty candidate string');
        return;
      }
      if (candidate.sdpMid == null) {
        Logger.d('Skipping ICE candidate with null sdpMid');
        return;
      }
      if (candidate.sdpMLineIndex == null || candidate.sdpMLineIndex! < 0) {
        Logger.d('Skipping ICE candidate with invalid sdpMLineIndex');
        return;
      }

      if (_isLiveMode) {
        // In live mode, batch ICE candidates and use callback
        _localIceCandidates.add(candidate);
        _scheduleIceBatch(peerId);
      } else if (_currentUserId != null) {
        // Legacy mode: send via Firestore
        _signalingRepository.sendIceCandidate(
          channelId: channelId,
          fromUserId: _currentUserId!,
          toUserId: peerId,
          candidate: candidate.candidate!,
          sdpMid: candidate.sdpMid!,
          sdpMLineIndex: candidate.sdpMLineIndex!,
        );
      }
    };

    // Handle connection state changes
    pc.onConnectionState = (RTCPeerConnectionState state) {
      Logger.d('Connection state with $peerId: $state');
      _emitConnectionStates();
    };

    // Handle remote tracks
    pc.onTrack = (RTCTrackEvent event) {
      if (event.streams.isNotEmpty) {
        final remoteStream = event.streams.first;
        _remoteStreams[peerId] = remoteStream;
        _remoteStreamController.add(remoteStream);
        Logger.d('Received remote stream from $peerId');
      }
    };

    // Handle ICE connection state
    pc.onIceConnectionState = (RTCIceConnectionState state) {
      Logger.d('ICE connection state with $peerId: $state');
    };

    return pc;
  }

  void _emitConnectionStates() {
    final states = <String, RTCPeerConnectionState>{};
    for (final entry in _peerConnections.entries) {
      final state = entry.value.connectionState;
      if (state != null) {
        states[entry.key] = state;
      }
    }
    _connectionStateController.add(states);
  }

  /// Schedule batched ICE candidate sending (live mode)
  void _scheduleIceBatch(String peerId) {
    _iceBatchTimer?.cancel();
    _iceBatchTimer = Timer(const Duration(milliseconds: 100), () {
      _sendBatchedIceCandidates(peerId);
    });
  }

  /// Send batched ICE candidates (live mode)
  void _sendBatchedIceCandidates(String targetUserId) {
    if (_localIceCandidates.isEmpty) return;
    if (onIceCandidate == null) return;

    // Send each candidate via callback
    for (final candidate in _localIceCandidates) {
      onIceCandidate?.call(candidate, targetUserId);
    }

    Logger.d('Sent ${_localIceCandidates.length} ICE candidates');
    _localIceCandidates.clear();
  }

  /// Create offer for live streaming (returns SDP string)
  Future<String?> createLiveOffer() async {
    try {
      final pc = await _createPeerConnection('live_broadcast');
      _peerConnections['live_broadcast'] = pc;

      if (_localStream != null) {
        for (final track in _localStream!.getTracks()) {
          await pc.addTrack(track, _localStream!);
        }
      }

      final offer = await pc.createOffer({
        'offerToReceiveAudio': false,
        'offerToReceiveVideo': false,
      });

      await pc.setLocalDescription(offer);
      Logger.d('Created live offer');
      return offer.sdp;
    } catch (e) {
      Logger.e('Failed to create live offer', error: e);
      return null;
    }
  }

  /// Handle live offer (for listeners)
  Future<String?> handleLiveOffer(String fromUserId, String sdp) async {
    try {
      final pc = await _createPeerConnection(fromUserId);
      _peerConnections[fromUserId] = pc;

      await pc.setRemoteDescription(RTCSessionDescription(sdp, 'offer'));
      await _applyPendingIceCandidates(fromUserId);

      final answer = await pc.createAnswer({
        'offerToReceiveAudio': true,
        'offerToReceiveVideo': false,
      });

      await pc.setLocalDescription(answer);
      Logger.d('Created live answer for $fromUserId');
      return answer.sdp;
    } catch (e) {
      Logger.e('Failed to handle live offer', error: e);
      return null;
    }
  }

  /// Handle live answer (for speaker)
  Future<void> handleLiveAnswer(String fromUserId, String sdp) async {
    try {
      var pc = _peerConnections[fromUserId];

      if (pc == null) {
        pc = await _createPeerConnection(fromUserId);
        _peerConnections[fromUserId] = pc;

        if (_localStream != null) {
          for (final track in _localStream!.getTracks()) {
            await pc.addTrack(track, _localStream!);
          }
        }
      }

      await pc.setRemoteDescription(RTCSessionDescription(sdp, 'answer'));
      await _applyPendingIceCandidates(fromUserId);
      Logger.d('Handled live answer from $fromUserId');
    } catch (e) {
      Logger.e('Failed to handle live answer', error: e);
    }
  }

  /// Close all peer connections (for live mode)
  Future<void> closeAllConnections() async {
    for (final peerId in _peerConnections.keys.toList()) {
      await closePeerConnection(peerId);
    }
    _localIceCandidates.clear();
    _iceBatchTimer?.cancel();
  }

  /// Mute/unmute local audio
  void setMicrophoneEnabled(bool enabled) {
    if (_localStream != null) {
      for (final track in _localStream!.getAudioTracks()) {
        track.enabled = enabled;
      }
    }
  }

  /// Close connection with a specific peer
  Future<void> closePeerConnection(String peerId) async {
    final pc = _peerConnections.remove(peerId);
    if (pc != null) {
      await pc.close();
    }

    final remoteStream = _remoteStreams.remove(peerId);
    if (remoteStream != null) {
      await remoteStream.dispose();
    }

    _pendingIceCandidates.remove(peerId);
  }

  /// Clean up all resources
  Future<void> dispose() async {
    Logger.d('Disposing WebRTC service');

    _iceBatchTimer?.cancel();
    _localIceCandidates.clear();

    // Close all peer connections
    for (final peerId in _peerConnections.keys.toList()) {
      await closePeerConnection(peerId);
    }

    // Dispose local stream
    if (_localStream != null) {
      for (final track in _localStream!.getTracks()) {
        await track.stop();
      }
      await _localStream!.dispose();
      _localStream = null;
    }

    // Clean up signaling (only in legacy mode)
    if (!_isLiveMode && _currentUserId != null) {
      await _signalingRepository.cleanupSignaling(
        channelId: channelId,
        userId: _currentUserId!,
      );
    }

    await _remoteStreamController.close();
    await _connectionStateController.close();
  }
}
