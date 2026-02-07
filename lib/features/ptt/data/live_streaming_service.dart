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

  // Getters
  LiveStreamingState get state => _state;
  bool get isBroadcasting => _isBroadcasting;
  MediaStream? get localStream => _localStream;
  Map<String, MediaStream> get remoteStreams => Map.unmodifiable(_remoteStreams);
  int get audioTracksReceived => _audioTracksReceived;
  bool get onTrackFired => _onTrackFired;
  String? get iceState => _iceState;

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
      debugPrint('LiveStream: Floor released, current state: $_state');
      _currentSpeakerId = null;
      _speakerController.add((id: null, name: null));

      if (_isBroadcasting) {
        // We were broadcasting and floor was released (timeout?)
        debugPrint('LiveStream: We were broadcasting, stopping');
        stopBroadcasting();
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

  /// Start streaming to all listeners in the room
  Future<void> _startStreamingToListeners() async {
    if (_localStream == null) {
      debugPrint('LiveStream: Cannot stream - no local stream');
      return;
    }

    debugPrint('LiveStream: Starting to stream to listeners');
    debugPrint('LiveStream: Local stream tracks: ${_localStream!.getTracks().length}');

    // Close any old peer connections
    await _closeAllPeerConnections();

    // Create a template offer to broadcast
    // This offer will be used by listeners to know our capabilities
    final templatePc = await _createPeerConnection('template');
    if (_localStream != null) {
      for (final track in _localStream!.getTracks()) {
        await templatePc.addTrack(track, _localStream!);
      }
    }

    final offer = await templatePc.createOffer({
      'offerToReceiveAudio': false,
      'offerToReceiveVideo': false,
    });
    await templatePc.setLocalDescription(offer);

    _broadcastOfferSdp = offer.sdp;
    _peerConnections['template'] = templatePc;

    debugPrint('LiveStream: Sending broadcast offer, sdp length: ${offer.sdp?.length}');
    _wsService.sendOffer(
      roomId: channelId,
      sdp: offer.sdp!,
    );
  }

  /// Create WebRTC offer for a specific listener
  Future<RTCSessionDescription?> _createOfferForListener(String listenerId) async {
    try {
      debugPrint('LiveStream: Creating peer connection for listener $listenerId');

      // Create a dedicated peer connection for this listener
      final pc = await _createPeerConnection(listenerId);
      _peerConnections[listenerId] = pc;

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

      Logger.d('Created offer for listener $listenerId');
      return offer;
    } catch (e) {
      Logger.e('Failed to create offer for listener', error: e);
      debugPrint('LiveStream: Error creating offer for $listenerId: $e');
      return null;
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
      // CRITICAL: Configure audio for playback BEFORE creating peer connection
      debugPrint('LiveStream: Configuring audio for receiving');
      await _configureAudioForReceiving();

      // Create peer connection for this speaker
      debugPrint('LiveStream: Creating peer connection for $fromUserId');
      final pc = await _createPeerConnection(fromUserId);
      _peerConnections[fromUserId] = pc;

      // Add transceiver to receive audio (important for mobile!)
      debugPrint('LiveStream: Adding audio transceiver for receiving');
      await pc.addTransceiver(
        kind: RTCRtpMediaType.RTCRtpMediaTypeAudio,
        init: RTCRtpTransceiverInit(direction: TransceiverDirection.RecvOnly),
      );

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

  /// Handle incoming answer (response to our offer)
  Future<void> _handleIncomingAnswer(String fromUserId, String sdp) async {
    debugPrint('LiveStream: Received answer from $fromUserId, sdp length: ${sdp.length}');

    try {
      if (!_isBroadcasting) {
        debugPrint('LiveStream: Not broadcasting, ignoring answer from $fromUserId');
        return;
      }

      // Check if we already have a connection for this specific user
      RTCPeerConnection? pc = _peerConnections[fromUserId];

      // If we have a template connection but no dedicated connection for this user
      if (pc == null) {
        final hasTemplate = _peerConnections.containsKey('template');
        // Count real listener connections (exclude 'template')
        final listenerCount = _peerConnections.entries
            .where((e) => e.key != 'template')
            .length;

        if (hasTemplate && listenerCount == 0) {
          // Use the template connection for the first listener
          debugPrint('LiveStream: Using template connection for first listener $fromUserId');
          pc = _peerConnections.remove('template');
          _peerConnections[fromUserId] = pc!;
        } else {
          // For additional listeners, we need to create a new connection and send them a new offer
          debugPrint('LiveStream: Creating new peer connection for additional listener $fromUserId');
          pc = await _createPeerConnection(fromUserId);
          _peerConnections[fromUserId] = pc;

          // Add local stream
          if (_localStream != null) {
            for (final track in _localStream!.getTracks()) {
              await pc.addTrack(track, _localStream!);
            }
          }

          // Create and set local offer
          final offer = await pc.createOffer({
            'offerToReceiveAudio': false,
            'offerToReceiveVideo': false,
          });
          await pc.setLocalDescription(offer);

          // Send this dedicated offer to this specific listener
          debugPrint('LiveStream: Sending dedicated offer to listener $fromUserId');
          _wsService.sendOffer(
            roomId: channelId,
            sdp: offer.sdp!,
            targetUserId: fromUserId,
          );

          // Wait for their answer - don't try to set this answer yet
          debugPrint('LiveStream: Waiting for dedicated answer from $fromUserId');
          return;
        }
      }

      if (pc == null) {
        debugPrint('LiveStream: No peer connection found for answer from $fromUserId');
        return;
      }

      // Check signaling state before setting remote description
      final signalingState = pc.signalingState;
      debugPrint('LiveStream: Current signaling state for $fromUserId: $signalingState');

      if (signalingState == RTCSignalingState.RTCSignalingStateHaveLocalOffer) {
        // Good state - we're expecting an answer
        await pc.setRemoteDescription(RTCSessionDescription(sdp, 'answer'));
        debugPrint('LiveStream: Answer set successfully for $fromUserId');
      } else if (signalingState == RTCSignalingState.RTCSignalingStateStable) {
        // Already stable - connection established
        debugPrint('LiveStream: Connection already stable for $fromUserId');
        return;
      } else {
        debugPrint('LiveStream: Unexpected signaling state: $signalingState for answer from $fromUserId');
        return;
      }

      // Apply pending ICE candidates
      await _applyPendingIceCandidates(fromUserId);

      debugPrint('LiveStream: Answer handled successfully from $fromUserId');
    } catch (e) {
      debugPrint('LiveStream: Failed to handle answer from $fromUserId: $e');
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

    // If broadcasting, use 'broadcast' peer connection, otherwise use fromUserId
    RTCPeerConnection? pc = _peerConnections[fromUserId];
    if (pc == null && _isBroadcasting) {
      pc = _peerConnections['broadcast'];
    }

    final remoteDesc = await pc?.getRemoteDescription();

    if (pc == null || remoteDesc == null) {
      // Queue candidate until we have the connection ready
      _pendingIceCandidates.putIfAbsent(fromUserId, () => []);
      _pendingIceCandidates[fromUserId]!.add(iceCandidate);
      debugPrint('LiveStream: Queued ICE candidate from $fromUserId (pc=${pc != null}, remoteDesc=${remoteDesc != null})');
      return;
    }

    try {
      await pc.addCandidate(iceCandidate);
      debugPrint('LiveStream: Added ICE candidate from $fromUserId');
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
      'iceCandidatePoolSize': 10,
      'iceTransportPolicy': 'all', // Try all ICE candidates (host, srflx, relay)
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

        // Step 4: Set volume on the track (CRITICAL for Android)
        try {
          debugPrint('LiveStream: Step 4 - Setting track volume');
          await Helper.setVolume(1.0, event.track);
          debugPrint('LiveStream: Track volume set to 1.0');
        } catch (e) {
          debugPrint('LiveStream: Failed to set track volume: $e');
        }

        if (event.streams.isNotEmpty) {
          final remoteStream = event.streams.first;
          _remoteStreams[peerId] = remoteStream;

          // Step 5: Enable all audio tracks in the stream
          debugPrint('LiveStream: Step 5 - Enabling all audio tracks');
          for (final track in remoteStream.getAudioTracks()) {
            track.enabled = true;
            try {
              await Helper.setVolume(1.0, track);
              debugPrint('LiveStream: Track ${track.id} enabled, volume set');
            } catch (e) {
              debugPrint('LiveStream: Volume set failed for ${track.id}: $e');
            }
          }

          // Step 6: Create renderer to consume the stream
          debugPrint('LiveStream: Step 6 - Creating audio renderer');
          await _createAudioRenderer(peerId, remoteStream);

          // Step 7: Notify listeners
          _remoteStreamController.add(remoteStream);
          debugPrint('LiveStream: Step 7 - Stream notification sent');

          // Step 8: Final audio check with delays
          debugPrint('LiveStream: Step 8 - Final audio verification');
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

    pc.onIceConnectionState = (RTCIceConnectionState state) {
      debugPrint('LiveStream: *** ICE Connection State: $state ***');

      // Update debug state
      _iceState = state.toString().split('.').last;
      _debugController.add((tracks: _audioTracksReceived, onTrack: _onTrackFired, ice: _iceState));

      if (state == RTCIceConnectionState.RTCIceConnectionStateConnected) {
        debugPrint('LiveStream: ICE CONNECTED! Audio should flow now.');
      } else if (state == RTCIceConnectionState.RTCIceConnectionStateFailed) {
        debugPrint('LiveStream: ICE FAILED! Check TURN servers.');
        // Clean up this peer connection on failure
        _closePeerConnection(peerId);
      } else if (state == RTCIceConnectionState.RTCIceConnectionStateDisconnected) {
        debugPrint('LiveStream: ICE DISCONNECTED');
      } else if (state == RTCIceConnectionState.RTCIceConnectionStateClosed) {
        debugPrint('LiveStream: ICE CLOSED - cleaning up peer connection');
        // Clean up when ICE connection closes (floor timeout, peer left, etc.)
        _closePeerConnection(peerId);
        // Return to idle state if we were listening
        if (_state == LiveStreamingState.listening) {
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
  }

  /// Close all peer connections
  Future<void> _closeAllPeerConnections() async {
    for (final peerId in _peerConnections.keys.toList()) {
      await _closePeerConnection(peerId);
    }
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

  /// Clean up resources
  Future<void> dispose() async {
    Logger.d('Disposing LiveStreamingService');

    _iceBatchTimer?.cancel();
    _offerSubscription?.cancel();
    _answerSubscription?.cancel();
    _iceSubscription?.cancel();
    _floorSubscription?.cancel();

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
