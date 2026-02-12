import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

import '../../../core/constants/app_constants.dart';
import '../../../core/services/native_audio_service.dart';
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
  final Map<String, RTCVideoRenderer> _audioRenderers = {};
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

  // Debug state
  int _audioTracksReceived = 0;
  bool _onTrackFired = false;
  String? _iceState;

  // Controllers
  final _stateController = StreamController<LiveStreamingState>.broadcast();
  final _remoteStreamController = StreamController<MediaStream>.broadcast();
  final _speakerController = StreamController<({String? id, String? name})>.broadcast();
  final _debugController = StreamController<({int tracks, bool onTrack, String? ice})>.broadcast();

  // Streams
  Stream<LiveStreamingState> get stateStream => _stateController.stream;
  Stream<MediaStream> get remoteStreamAdded => _remoteStreamController.stream;
  Stream<({String? id, String? name})> get currentSpeaker => _speakerController.stream;
  Stream<({int tracks, bool onTrack, String? ice})> get debugState => _debugController.stream;

  // Mute state
  bool _isMuted = false;

  // Getters
  LiveStreamingState get state => _state;
  bool get isBroadcasting => _isBroadcasting;
  bool get isMuted => _isMuted;
  MediaStream? get localStream => _localStream;
  Map<String, MediaStream> get remoteStreams => Map.unmodifiable(_remoteStreams);
  int get audioTracksReceived => _audioTracksReceived;
  bool get onTrackFired => _onTrackFired;
  String? get iceState => _iceState;

  /// Set muted state for incoming audio
  void setMuted(bool muted) {
    _isMuted = muted;
    debugPrint('LiveStreaming: Setting muted to $muted');

    // Mute/unmute all remote audio tracks
    for (final stream in _remoteStreams.values) {
      for (final track in stream.getAudioTracks()) {
        track.enabled = !muted;
        debugPrint('LiveStreaming: Audio track ${track.id} enabled: ${!muted}');
      }
    }
  }

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
        return true;
      } catch (e) {
        // Fallback to simpler constraints if device doesn't support all options
        Logger.w('Full audio constraints failed, trying fallback: $e');
        final fallbackConstraints = {
          'audio': true,
          'video': false,
        };
        _localStream = await navigator.mediaDevices.getUserMedia(fallbackConstraints);
        Logger.d('Local audio stream initialized with fallback constraints');
        return true;
      }
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

    // CRITICAL: Initialize local stream FIRST before anything else
    // This ensures audio is ready when floor is granted
    if (_localStream == null) {
      debugPrint('LiveStream: Initializing local stream before floor request');
      final success = await initLocalStream();
      if (!success) {
        debugPrint('LiveStream: Failed to initialize local stream');
        _updateState(LiveStreamingState.error);
        return false;
      }
      debugPrint('LiveStream: Local stream ready with ${_localStream!.getTracks().length} tracks');
    }

    // Verify we have audio tracks
    final audioTracks = _localStream!.getAudioTracks();
    if (audioTracks.isEmpty) {
      Logger.e('No audio tracks in local stream');
      _updateState(LiveStreamingState.error);
      return false;
    }
    debugPrint('LiveStream: Audio tracks ready: ${audioTracks.length}');

    // Now request floor from server
    debugPrint('LiveStream: Requesting floor');
    _wsService.requestFloor(channelId);

    // Wait for floor granted (handled in _handleFloorStateChange)
    // The actual WebRTC setup happens when floor is granted

    return true;
  }

  /// Stop broadcasting (when PTT released)
  Future<void> stopBroadcasting() async {
    if (!_isBroadcasting) return;

    Logger.d('Stopping broadcast');

    // Mute local stream immediately to stop audio
    _setLocalAudioEnabled(false);

    _isBroadcasting = false;
    _updateState(LiveStreamingState.idle);

    // Release floor - this notifies other users
    _wsService.releaseFloor(channelId);

    // IMPORTANT: Don't close peer connections immediately!
    // Let ICE complete and audio flow for a moment, then clean up.
    // This allows any in-flight audio to be delivered.
    Future.delayed(const Duration(seconds: 2), () {
      // Only close if we're still not broadcasting (user didn't start again)
      if (!_isBroadcasting) {
        _closeAllPeerConnections();
      }
    });
  }

  /// Handle floor state changes
  void _handleFloorStateChange(WSFloorState? floor) {
    if (floor == null) {
      // Floor released
      debugPrint('LiveStream: Floor released, current state: $_state');
      _currentSpeakerId = null;
      _speakerController.add((id: null, name: null));

      if (_isBroadcasting) {
        // We were broadcasting and floor was released (timeout or we released it)
        // DON'T call stopBroadcasting() here - it would send another releaseFloor!
        // Just clean up local state
        debugPrint('LiveStream: We were broadcasting, cleaning up locally');
        _setLocalAudioEnabled(false);
        _isBroadcasting = false;
        _updateState(LiveStreamingState.idle);
        // Delayed cleanup of peer connections
        Future.delayed(const Duration(seconds: 2), () {
          if (!_isBroadcasting) {
            _closeAllPeerConnections();
          }
        });
      } else {
        // Someone else stopped speaking
        // Don't close peer connections immediately - let ICE finish or timeout naturally
        // The peer connections will be cleaned up when ICE fails or closes
        debugPrint('LiveStream: Floor released by speaker, returning to idle');
        // Only close if we've fully connected - otherwise let ICE fail naturally
        _delayedCleanup();
        _updateState(LiveStreamingState.idle);
      }
      return;
    }

    _currentSpeakerId = floor.speakerId;
    _speakerController.add((id: floor.speakerId, name: floor.speakerName));

    // Check if we got the floor
    if (floor.speakerId == _wsService.userId) {
      // We got the floor - start streaming
      debugPrint('LiveStream: We got the floor, starting to broadcast');
      _isBroadcasting = true;
      _updateState(LiveStreamingState.broadcasting);
      _setLocalAudioEnabled(true);
      _startStreamingToListeners();
    } else {
      // Someone else is speaking - prepare to receive
      debugPrint('LiveStream: Someone else is speaking: ${floor.speakerName}');

      // If we were broadcasting, stop and clean up
      if (_isBroadcasting) {
        debugPrint('LiveStream: We were broadcasting, cleaning up');
        _closeAllPeerConnections();
      }

      _isBroadcasting = false;
      _updateState(LiveStreamingState.listening);
    }
  }

  /// Store the SDP offer template for creating connections to late joiners
  String? _broadcastOfferSdp;

  /// Track pending offers sent to specific listeners (to handle their answers)
  final Map<String, bool> _pendingOffersSent = {};

  /// Start streaming to all listeners in the room
  Future<void> _startStreamingToListeners() async {
    if (_localStream == null) {
      debugPrint('LiveStream: Cannot stream - no local stream');
      Logger.e('Cannot stream - local stream is null');
      return;
    }

    // Verify audio tracks exist and are enabled
    final audioTracks = _localStream!.getAudioTracks();
    if (audioTracks.isEmpty) {
      debugPrint('LiveStream: Cannot stream - no audio tracks');
      Logger.e('Cannot stream - no audio tracks in local stream');
      return;
    }

    // Ensure tracks are enabled
    for (final track in audioTracks) {
      if (!track.enabled) {
        track.enabled = true;
        debugPrint('LiveStream: Enabled audio track ${track.id}');
      }
    }

    debugPrint('LiveStream: Starting to stream to listeners');
    debugPrint('LiveStream: Local stream tracks: ${_localStream!.getTracks().length}');
    debugPrint('LiveStream: Audio tracks enabled: ${audioTracks.where((t) => t.enabled).length}/${audioTracks.length}');

    // Close any old peer connections
    await _closeAllPeerConnections();
    _pendingOffersSent.clear();

    // Get list of room members and create dedicated connections for each
    final members = _wsService.getRoomMembers(channelId);
    final myUserId = _wsService.userId;

    debugPrint('LiveStream: Room has ${members.length} members, my ID: $myUserId');

    for (final member in members) {
      // Skip ourselves
      if (member.userId == myUserId) continue;

      debugPrint('LiveStream: Creating dedicated connection for listener ${member.userId} (${member.displayName})');
      await _createAndSendOfferToListener(member.userId);
    }
  }

  /// Create a dedicated peer connection and send offer to a specific listener
  Future<void> _createAndSendOfferToListener(String listenerId) async {
    try {
      // Create peer connection for this listener
      final pc = await _createPeerConnection(listenerId);
      _peerConnections[listenerId] = pc;

      // Add local audio tracks
      if (_localStream != null) {
        for (final track in _localStream!.getTracks()) {
          await pc.addTrack(track, _localStream!);
        }
        debugPrint('LiveStream: Added ${_localStream!.getTracks().length} tracks to PC for $listenerId');
      }

      // Create offer
      final offer = await pc.createOffer({
        'offerToReceiveAudio': false,
        'offerToReceiveVideo': false,
      });

      if (offer.sdp == null || offer.sdp!.isEmpty) {
        debugPrint('LiveStream: Failed to create offer for $listenerId - empty SDP');
        return;
      }

      // Constrain bandwidth
      final constrainedSdp = _constrainAudioBandwidth(offer.sdp!);

      // Set local description
      await pc.setLocalDescription(RTCSessionDescription(constrainedSdp, 'offer'));

      // Mark that we've sent an offer
      _pendingOffersSent[listenerId] = true;

      debugPrint('LiveStream: Sending targeted offer to $listenerId, sdp length: ${constrainedSdp.length}');

      // Send targeted offer to this specific listener
      _wsService.sendOffer(
        roomId: channelId,
        sdp: constrainedSdp,
        targetUserId: listenerId,
      );
    } catch (e) {
      debugPrint('LiveStream: Error creating offer for $listenerId: $e');
      Logger.e('Error creating offer for $listenerId', error: e);
    }
  }

  /// Handle incoming offer (when someone starts speaking)
  Future<void> _handleIncomingOffer(String fromUserId, String sdp) async {
    // Skip our own offers
    if (fromUserId == _wsService.userId) {
      debugPrint('LiveStream: Skipping own offer');
      return;
    }

    debugPrint('LiveStream: Received offer from $fromUserId, sdp length: ${sdp.length}');

    try {
      // CRITICAL: Close any existing PC for this user first to avoid ICE conflicts
      if (_peerConnections.containsKey(fromUserId)) {
        debugPrint('LiveStream: Closing existing PC for $fromUserId before creating new one');
        await _closePeerConnection(fromUserId);
      }

      // CRITICAL: Configure audio for playback BEFORE creating peer connection
      debugPrint('LiveStream: Configuring audio for receiving');
      await _configureAudioForReceiving();

      // Create peer connection for this speaker
      debugPrint('LiveStream: Creating peer connection for $fromUserId');
      final pc = await _createPeerConnection(fromUserId);
      _peerConnections[fromUserId] = pc;

      // Add transceiver to receive audio (important for mobile!)
      debugPrint('LiveStream: Adding audio transceiver for receiving');
      try {
        await pc.addTransceiver(
          kind: RTCRtpMediaType.RTCRtpMediaTypeAudio,
          init: RTCRtpTransceiverInit(direction: TransceiverDirection.RecvOnly),
        );
        debugPrint('LiveStream: Audio transceiver added successfully');
      } catch (e) {
        debugPrint('LiveStream: Failed to add transceiver (may be ok on some devices): $e');
        // Continue anyway - some devices handle this automatically
      }

      // Set remote description
      debugPrint('LiveStream: Setting remote description');
      await pc.setRemoteDescription(RTCSessionDescription(sdp, 'offer'));

      // Apply any pending ICE candidates
      await _applyPendingIceCandidates(fromUserId);

      // Create answer
      debugPrint('LiveStream: Creating answer');
      final answer = await pc.createAnswer({
        'offerToReceiveAudio': true,
        'offerToReceiveVideo': false,
      });

      await pc.setLocalDescription(answer);
      debugPrint('LiveStream: Answer created, sending back');

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

  /// Handle incoming answer (response to our targeted offer)
  Future<void> _handleIncomingAnswer(String fromUserId, String sdp) async {
    debugPrint('LiveStream: Received answer from $fromUserId, sdp length: ${sdp.length}');

    try {
      if (!_isBroadcasting) {
        debugPrint('LiveStream: Not broadcasting, ignoring answer from $fromUserId');
        return;
      }

      // We should already have a PC for this user (created when we sent the offer)
      final pc = _peerConnections[fromUserId];

      if (pc == null) {
        // We don't have a PC for this user - they might be a late joiner
        // Create a new connection and send them an offer
        debugPrint('LiveStream: No PC for $fromUserId, creating one now (late joiner?)');
        await _createAndSendOfferToListener(fromUserId);
        return;
      }

      // Check signaling state
      final signalingState = pc.signalingState;
      debugPrint('LiveStream: Current signaling state for $fromUserId: $signalingState');

      if (signalingState == RTCSignalingState.RTCSignalingStateHaveLocalOffer) {
        // Good state - we're expecting an answer
        await pc.setRemoteDescription(RTCSessionDescription(sdp, 'answer'));
        debugPrint('LiveStream: Answer set successfully for $fromUserId');

        // Clear the pending offer flag
        _pendingOffersSent.remove(fromUserId);

        // Apply pending ICE candidates
        await _applyPendingIceCandidates(fromUserId);

        debugPrint('LiveStream: Connection establishing with $fromUserId, ICE should start');
      } else if (signalingState == RTCSignalingState.RTCSignalingStateStable) {
        // Already stable - connection established
        debugPrint('LiveStream: Connection already stable for $fromUserId');
        return;
      } else {
        debugPrint('LiveStream: Unexpected signaling state: $signalingState for $fromUserId');
        return;
      }
    } catch (e) {
      debugPrint('LiveStream: Failed to handle answer from $fromUserId: $e');
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
    debugPrint('LiveStream: Received ICE candidate from $fromUserId');

    final iceCandidate = RTCIceCandidate(candidate, sdpMid, sdpMLineIndex);

    // Look up the peer connection for this user
    RTCPeerConnection? pc = _peerConnections[fromUserId];

    // If no PC yet, queue the candidate - it will be applied when PC is created
    if (pc == null) {
      _pendingIceCandidates.putIfAbsent(fromUserId, () => []);
      _pendingIceCandidates[fromUserId]!.add(iceCandidate);
      debugPrint('LiveStream: Queued ICE candidate from $fromUserId (no PC yet, queue size: ${_pendingIceCandidates[fromUserId]!.length})');
      return;
    }

    // Check if remote description is set
    final remoteDesc = await pc.getRemoteDescription();
    if (remoteDesc == null) {
      // Queue candidate until remote description is set
      _pendingIceCandidates.putIfAbsent(fromUserId, () => []);
      _pendingIceCandidates[fromUserId]!.add(iceCandidate);
      debugPrint('LiveStream: Queued ICE candidate from $fromUserId (no remote desc yet, queue size: ${_pendingIceCandidates[fromUserId]!.length})');
      return;
    }

    try {
      await pc.addCandidate(iceCandidate);
      debugPrint('LiveStream: Added ICE candidate from $fromUserId successfully');
    } catch (e) {
      debugPrint('LiveStream: Failed to add ICE candidate from $fromUserId: $e');
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

  /// Track ICE restart attempts per peer
  final Map<String, int> _iceRestartAttempts = {};
  static const int _maxIceRestartAttempts = 2;

  /// Create a WebRTC peer connection
  Future<RTCPeerConnection> _createPeerConnection(String peerId) async {
    final configuration = {
      'iceServers': AppConstants.iceServers,
      'sdpSemantics': 'unified-plan',
      'iceCandidatePoolSize': 10,
      'iceTransportPolicy': 'all', // Allow both direct and relay connections
      'bundlePolicy': 'max-bundle', // Bundle all media for efficiency
      'rtcpMuxPolicy': 'require', // Require RTCP multiplexing
    };

    final pc = await createPeerConnection(configuration);

    // Reset ICE restart counter for this peer
    _iceRestartAttempts[peerId] = 0;

    // Handle local ICE candidates
    pc.onIceCandidate = (RTCIceCandidate candidate) {
      // Skip null/empty candidates (end-of-candidates signal)
      if (candidate.candidate == null || candidate.candidate!.isEmpty) {
        debugPrint('LiveStream: ICE gathering complete for $peerId');
        return;
      }
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
    pc.onTrack = (RTCTrackEvent event) async {
      debugPrint('LiveStream: *** onTrack fired! ***');
      debugPrint('LiveStream: Track kind: ${event.track.kind}, id: ${event.track.id}');
      debugPrint('LiveStream: Track enabled: ${event.track.enabled}, muted: ${event.track.muted}');
      debugPrint('LiveStream: Streams count: ${event.streams.length}');

      // Update debug state
      _onTrackFired = true;
      _debugController.add((tracks: _audioTracksReceived, onTrack: true, ice: _iceState));

      if (event.track.kind == 'audio') {
        // Update debug track count
        _audioTracksReceived++;
        _debugController.add((tracks: _audioTracksReceived, onTrack: true, ice: _iceState));

        // CRITICAL: Configure audio BEFORE anything else
        debugPrint('LiveStream: ========== AUDIO TRACK RECEIVED ==========');

        // Step 1: Native Android audio setup
        try {
          debugPrint('LiveStream: Step 1 - Native audio mode setup');
          await NativeAudioService.setAudioModeForVoiceChat();
          await NativeAudioService.setSpeakerOn(true);
          debugPrint('LiveStream: Native audio configured');
        } catch (e) {
          debugPrint('LiveStream: Native audio error: $e');
        }

        // Step 2: Flutter WebRTC speaker setup
        try {
          debugPrint('LiveStream: Step 2 - Flutter speakerphone');
          await Helper.setSpeakerphoneOn(true);
          debugPrint('LiveStream: Flutter speakerphone enabled');
        } catch (e) {
          debugPrint('LiveStream: Flutter speaker error: $e');
        }

        // Step 3: Enable the track
        event.track.enabled = true;
        debugPrint('LiveStream: Step 3 - Track enabled: ${event.track.enabled}');

        if (event.streams.isNotEmpty) {
          final remoteStream = event.streams.first;
          _remoteStreams[peerId] = remoteStream;

          // Step 4: Enable all audio tracks in the stream (respects device volume)
          debugPrint('LiveStream: Step 4 - Enabling all audio tracks');
          for (final track in remoteStream.getAudioTracks()) {
            track.enabled = true;
            debugPrint('LiveStream: Track ${track.id} enabled');
          }

          // Step 5: Create renderer to consume the stream
          debugPrint('LiveStream: Step 5 - Creating audio renderer');
          await _createAudioRenderer(peerId, remoteStream);

          // Step 6: Notify listeners
          _remoteStreamController.add(remoteStream);
          debugPrint('LiveStream: Step 6 - Stream notification sent');

          // Step 7: Final audio routing check
          debugPrint('LiveStream: Step 7 - Final audio routing verification');
          for (int i = 0; i < 5; i++) {
            await Future.delayed(const Duration(milliseconds: 200));
            try {
              await NativeAudioService.setSpeakerOn(true);
              await Helper.setSpeakerphoneOn(true);
            } catch (e) {
              // ignore
            }
          }

          // Log final state
          final audioState = await NativeAudioService.getAudioState();
          debugPrint('LiveStream: ========== FINAL STATE ==========');
          debugPrint('LiveStream: Audio state: $audioState');
          debugPrint('LiveStream: Audio tracks: ${remoteStream.getAudioTracks().length}');
          for (final track in remoteStream.getAudioTracks()) {
            debugPrint('LiveStream: Track ${track.id}: enabled=${track.enabled}, muted=${track.muted}');
          }
          debugPrint('LiveStream: ================================');
        } else {
          debugPrint('LiveStream: WARNING - No stream in event, only track');
        }
      }
    };

    pc.onIceConnectionState = (RTCIceConnectionState state) async {
      debugPrint('LiveStream: *** ICE Connection State: $state ***');

      // Update debug state
      _iceState = state.toString().split('.').last;
      _debugController.add((tracks: _audioTracksReceived, onTrack: _onTrackFired, ice: _iceState));

      if (state == RTCIceConnectionState.RTCIceConnectionStateConnected) {
        debugPrint('LiveStream: ICE CONNECTED! Audio should flow now.');
        // Reset restart counter on successful connection
        _iceRestartAttempts[peerId] = 0;
      } else if (state == RTCIceConnectionState.RTCIceConnectionStateFailed) {
        debugPrint('LiveStream: ICE FAILED! Attempting restart...');

        // Try ICE restart before giving up
        final attempts = _iceRestartAttempts[peerId] ?? 0;
        if (attempts < _maxIceRestartAttempts) {
          _iceRestartAttempts[peerId] = attempts + 1;
          debugPrint('LiveStream: ICE restart attempt ${attempts + 1}/$_maxIceRestartAttempts');

          try {
            // ICE restart by creating a new offer with iceRestart option
            await pc.restartIce();
            debugPrint('LiveStream: ICE restart triggered');
          } catch (e) {
            debugPrint('LiveStream: ICE restart failed: $e');
            _closePeerConnection(peerId);
          }
        } else {
          debugPrint('LiveStream: Max ICE restart attempts reached, closing connection');
          _closePeerConnection(peerId);
        }
      } else if (state == RTCIceConnectionState.RTCIceConnectionStateDisconnected) {
        debugPrint('LiveStream: ICE DISCONNECTED - waiting for reconnection...');
        // Don't close immediately - ICE may recover
        // Set a timeout to close if it doesn't recover
        Future.delayed(const Duration(seconds: 5), () async {
          final currentPc = _peerConnections[peerId];
          if (currentPc != null) {
            final currentState = currentPc.iceConnectionState;
            if (currentState == RTCIceConnectionState.RTCIceConnectionStateDisconnected ||
                currentState == RTCIceConnectionState.RTCIceConnectionStateFailed) {
              debugPrint('LiveStream: ICE did not recover, closing connection');
              _closePeerConnection(peerId);
            }
          }
        });
      } else if (state == RTCIceConnectionState.RTCIceConnectionStateClosed) {
        debugPrint('LiveStream: ICE CLOSED - connection ended normally');
        // Only clean up if we haven't already
        if (_peerConnections.containsKey(peerId)) {
          _closePeerConnection(peerId);
        }
        // Return to idle state if we were listening and no more connections
        if (_state == LiveStreamingState.listening && _peerConnections.isEmpty) {
          _updateState(LiveStreamingState.idle);
        }
      }
    };

    pc.onSignalingState = (RTCSignalingState state) {
      debugPrint('LiveStream: Signaling state with $peerId: $state');
    };

    // Monitor ICE gathering state
    pc.onIceGatheringState = (RTCIceGatheringState state) {
      debugPrint('LiveStream: ICE Gathering state with $peerId: $state');
      if (state == RTCIceGatheringState.RTCIceGatheringStateComplete) {
        debugPrint('LiveStream: ICE gathering complete - all candidates sent');
      }
    };

    return pc;
  }

  /// Per-peer ICE candidate queues for targeted sending
  final Map<String, List<RTCIceCandidate>> _peerIceCandidates = {};
  final Map<String, Timer?> _peerIceBatchTimers = {};

  /// Schedule batched ICE candidate sending for a specific peer
  void _scheduleIceBatch(String peerId) {
    // Store candidates per peer for targeted sending
    _peerIceCandidates.putIfAbsent(peerId, () => []);
    _peerIceCandidates[peerId]!.addAll(_localIceCandidates);
    _localIceCandidates.clear();

    // Cancel existing timer for this peer
    _peerIceBatchTimers[peerId]?.cancel();

    // Schedule batch send for this peer (reduced from 100ms to 50ms for faster ICE)
    _peerIceBatchTimers[peerId] = Timer(const Duration(milliseconds: 50), () {
      _sendBatchedIceCandidates(peerId);
    });
  }

  /// Send batched ICE candidates to a specific peer
  void _sendBatchedIceCandidates(String targetUserId) {
    final peerCandidates = _peerIceCandidates[targetUserId];
    if (peerCandidates == null || peerCandidates.isEmpty) return;

    // Filter out candidates with null/empty values to prevent crashes
    final validCandidates = <Map<String, dynamic>>[];
    for (final c in peerCandidates) {
      // Skip candidates with null or empty required fields
      if (c.candidate == null || c.candidate!.isEmpty) {
        debugPrint('LiveStream: Skipping ICE candidate with null/empty candidate string');
        continue;
      }
      if (c.sdpMid == null) {
        debugPrint('LiveStream: Skipping ICE candidate with null sdpMid');
        continue;
      }
      if (c.sdpMLineIndex == null || c.sdpMLineIndex! < 0) {
        debugPrint('LiveStream: Skipping ICE candidate with invalid sdpMLineIndex');
        continue;
      }
      validCandidates.add({
        'candidate': c.candidate!,
        'sdpMid': c.sdpMid!,
        'sdpMLineIndex': c.sdpMLineIndex!,
      });
    }

    if (validCandidates.isEmpty) {
      debugPrint('LiveStream: No valid ICE candidates to send to $targetUserId');
      peerCandidates.clear();
      _peerIceBatchTimers.remove(targetUserId);
      return;
    }

    // Always send to specific target user for better multi-device performance
    _wsService.sendIceCandidatesBatch(
      roomId: channelId,
      candidates: validCandidates,
      targetUserId: targetUserId,
    );

    peerCandidates.clear();
    _peerIceBatchTimers.remove(targetUserId);
    Logger.d('Sent ${validCandidates.length} ICE candidates to $targetUserId');
  }

  /// Configure audio session and routing for receiving WebRTC audio
  Future<void> _configureAudioForReceiving() async {
    try {
      // Use native Android audio manager for reliable audio routing
      debugPrint('LiveStream: Configuring native audio for voice chat...');

      // First, configure Android AudioManager for voice communication mode
      final modeSet = await NativeAudioService.setAudioModeForVoiceChat();
      debugPrint('LiveStream: Native audio mode set: $modeSet');

      // Then enable speakerphone via native code
      final speakerSet = await NativeAudioService.setSpeakerOn(true);
      debugPrint('LiveStream: Native speakerphone enabled: $speakerSet');

      // Also try the flutter_webrtc Helper as backup
      try {
        await Helper.setSpeakerphoneOn(true);
        debugPrint('LiveStream: Flutter Helper speakerphone also enabled');
      } catch (e) {
        debugPrint('LiveStream: Flutter Helper speakerphone failed (ok): $e');
      }

      // Log audio state for debugging
      final audioState = await NativeAudioService.getAudioState();
      debugPrint('LiveStream: Audio state after config: $audioState');
    } catch (e) {
      debugPrint('LiveStream: Failed to configure audio for receiving: $e');
    }
  }

  /// Create an audio renderer to play the remote stream
  /// In Flutter WebRTC, even audio-only streams need a renderer to be consumed
  Future<void> _createAudioRenderer(String peerId, MediaStream stream) async {
    try {
      // Dispose existing renderer if any
      if (_audioRenderers.containsKey(peerId)) {
        await _audioRenderers[peerId]!.dispose();
      }

      // Create and initialize the renderer
      final renderer = RTCVideoRenderer();
      await renderer.initialize();

      // Attach the stream to the renderer
      renderer.srcObject = stream;

      _audioRenderers[peerId] = renderer;
      debugPrint('LiveStream: Audio renderer created and stream attached for $peerId');

      // CRITICAL: Use native Android audio to ensure speakerphone is on after renderer setup
      // This is the most reliable way to route audio to the speaker
      try {
        // Short delay to let Android audio routing settle
        await Future.delayed(const Duration(milliseconds: 50));

        // Native Android AudioManager (most reliable)
        final nativeResult = await NativeAudioService.setSpeakerOn(true);
        debugPrint('LiveStream: Native speakerphone after renderer: $nativeResult');

        // Also try Flutter helper
        await Helper.setSpeakerphoneOn(true);
        debugPrint('LiveStream: Flutter speakerphone re-confirmed enabled');

        // Log audio state
        final audioState = await NativeAudioService.getAudioState();
        debugPrint('LiveStream: Audio state after renderer: $audioState');
      } catch (e) {
        debugPrint('LiveStream: Failed to set speakerphone after renderer: $e');
      }
    } catch (e) {
      debugPrint('LiveStream: Failed to create audio renderer: $e');
    }
  }

  /// Close a specific peer connection
  Future<void> _closePeerConnection(String peerId) async {
    // IMPORTANT: Send any pending ICE candidates before closing
    // This ensures ICE candidates aren't lost if user releases quickly
    _peerIceBatchTimers[peerId]?.cancel();
    _sendBatchedIceCandidates(peerId);

    final pc = _peerConnections.remove(peerId);
    if (pc != null) {
      await pc.close();
    }

    final stream = _remoteStreams.remove(peerId);
    if (stream != null) {
      await stream.dispose();
    }

    // Dispose the audio renderer
    final renderer = _audioRenderers.remove(peerId);
    if (renderer != null) {
      renderer.srcObject = null;
      await renderer.dispose();
      debugPrint('LiveStream: Audio renderer disposed for $peerId');
    }

    _pendingIceCandidates.remove(peerId);

    // Clean up per-peer ICE state (already sent, now remove)
    _peerIceBatchTimers.remove(peerId);
    _peerIceCandidates.remove(peerId);
    _pendingOffersSent.remove(peerId);
    _iceRestartAttempts.remove(peerId);
  }

  /// Close all peer connections
  Future<void> _closeAllPeerConnections() async {
    for (final peerId in _peerConnections.keys.toList()) {
      await _closePeerConnection(peerId);
    }

    // Clear per-peer ICE state
    for (final timer in _peerIceBatchTimers.values) {
      timer?.cancel();
    }
    _peerIceBatchTimers.clear();
    _peerIceCandidates.clear();
    _pendingOffersSent.clear();
    _iceRestartAttempts.clear();
  }

  /// Delayed cleanup - allows ICE to complete before closing
  void _delayedCleanup() {
    // Give ICE some time to complete or fail naturally
    Future.delayed(const Duration(seconds: 3), () {
      if (_state == LiveStreamingState.idle && !_isBroadcasting) {
        debugPrint('LiveStream: Delayed cleanup - closing peer connections');
        _closeAllPeerConnections();
      }
    });
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

  /// Modify SDP to constrain audio bandwidth for better multi-device performance
  String _constrainAudioBandwidth(String sdp) {
    // Add bandwidth constraint for audio (b=AS:30 means 30 kbps)
    // This helps with multiple devices by reducing bandwidth per connection
    final lines = sdp.split('\r\n');
    final newLines = <String>[];

    for (int i = 0; i < lines.length; i++) {
      newLines.add(lines[i]);
      // Add bandwidth constraint after m=audio line
      if (lines[i].startsWith('m=audio')) {
        // Check if bandwidth line already exists
        if (i + 1 < lines.length && !lines[i + 1].startsWith('b=')) {
          newLines.add('b=AS:30'); // 30 kbps for audio
        }
      }
    }

    return newLines.join('\r\n');
  }

  /// Clean up resources
  Future<void> dispose() async {
    Logger.d('Disposing LiveStreamingService');

    _iceBatchTimer?.cancel();
    _offerSubscription?.cancel();
    _answerSubscription?.cancel();
    _iceSubscription?.cancel();
    _floorSubscription?.cancel();

    // Clean up per-peer ICE timers
    for (final timer in _peerIceBatchTimers.values) {
      timer?.cancel();
    }
    _peerIceBatchTimers.clear();
    _peerIceCandidates.clear();
    _pendingOffersSent.clear();
    _iceRestartAttempts.clear();

    await _closeAllPeerConnections();

    // Dispose all audio renderers
    for (final renderer in _audioRenderers.values) {
      renderer.srcObject = null;
      await renderer.dispose();
    }
    _audioRenderers.clear();

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
    await _debugController.close();
  }
}
