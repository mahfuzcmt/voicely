import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

import '../../../core/constants/app_constants.dart';
import '../../../core/services/native_audio_service.dart';
import '../../../core/utils/logger.dart';
import 'websocket_signaling_service.dart';

/// Simple async lock to prevent concurrent operations
class _AsyncLock {
  Completer<void>? _completer;

  Future<T> synchronized<T>(Future<T> Function() fn) async {
    // Wait for any existing operation to complete
    while (_completer != null) {
      await _completer!.future;
    }

    // Start our operation
    _completer = Completer<void>();
    try {
      return await fn();
    } finally {
      final c = _completer;
      _completer = null;
      c?.complete();
    }
  }
}

/// Live streaming state
enum LiveStreamingState {
  idle,
  connecting,
  broadcasting,
  listening,
  error,
}

/// Provider for live streaming service per channel
/// NOT autoDispose - must survive widget rebuilds and app backgrounding
final liveStreamingServiceProvider = Provider.family<LiveStreamingService, String>(
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

  // Synchronization lock to prevent race conditions
  final _AsyncLock _connectionLock = _AsyncLock();

  // Track if audio is already configured to avoid redundant setup
  bool _audioConfigured = false;

  // WebRTC state
  MediaStream? _localStream;
  final Map<String, RTCPeerConnection> _peerConnections = {};
  final Map<String, MediaStream> _remoteStreams = {};
  final Map<String, RTCVideoRenderer> _audioRenderers = {};
  final Map<String, List<RTCIceCandidate>> _pendingIceCandidates = {};

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
  LiveStreamingState _state = LiveStreamingState.idle;
  bool _isBroadcasting = false;
  String? _currentSpeakerId;

  // Debug state
  int _audioTracksReceived = 0;
  bool _onTrackFired = false;
  String? _iceState;

  // Track actually connected listeners (ICE connected)
  final Set<String> _connectedListeners = {};

  // Track pending delayed futures for cancellation
  final List<Timer> _pendingTimers = [];

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

  /// Number of active listeners (actually ICE-connected when broadcasting)
  int get activeListenerCount => _isBroadcasting ? _connectedListeners.length : 0;

  /// Stream of listener count changes
  final _listenerCountController = StreamController<int>.broadcast();
  Stream<int> get listenerCountStream => _listenerCountController.stream;

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

    // Listen for floor denied
    _floorDeniedSubscription = _wsService.floorDenied.listen((event) {
      if (event.roomId == channelId) {
        _handleFloorDenied(event.reason);
      }
    });

    // Listen for new members joining the room while we're broadcasting
    _memberJoinedSubscription = _wsService.roomMembers.listen((event) async {
      if (event.roomId == channelId && _isBroadcasting) {
        // Use lock to prevent race conditions with parallel offer creation
        await _connectionLock.synchronized(() async {
          final myUserId = _wsService.userId;
          for (final member in event.members) {
            if (member.userId != myUserId &&
                !_peerConnections.containsKey(member.userId) &&
                !_pendingOffersSent.containsKey(member.userId)) {
              debugPrint('LiveStream: Late joiner detected: ${member.displayName}, sending offer');
              await _createAndSendOfferToListener(member.userId);
            }
          }
        });
      }
    });

    // Listen for WebSocket reconnection to recover WebRTC state
    _connectionSubscription = _wsService.connectionState.listen((connState) {
      if (connState == WSConnectionState.authenticated) {
        _handleReconnected();
      } else if (connState == WSConnectionState.disconnected ||
          connState == WSConnectionState.error) {
        // If we were broadcasting or listening, the connections are now stale
        if (_state == LiveStreamingState.broadcasting ||
            _state == LiveStreamingState.listening) {
          debugPrint('LiveStream: WebSocket lost during active session, cleaning up');
          _isBroadcasting = false;
          _closeAllPeerConnections();
          _updateState(LiveStreamingState.idle);
        }
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

  /// Reset debug state for new session
  void _resetDebugState() {
    _audioTracksReceived = 0;
    _onTrackFired = false;
    _iceState = null;
    _debugController.add((tracks: 0, onTrack: false, ice: null));
  }

  /// Start broadcasting (when PTT pressed)
  Future<bool> startBroadcasting() async {
    if (_isBroadcasting) {
      Logger.w('Already broadcasting');
      return false;
    }

    // Reset debug state for new session
    _resetDebugState();

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

    // Start timeout for floor request - if no response in 5 seconds, give up
    _floorRequestTimeout?.cancel();
    _floorRequestTimeout = Timer(AppConstants.floorRequestTimeout, () {
      if (_state == LiveStreamingState.connecting && !_isBroadcasting) {
        debugPrint('LiveStream: Floor request timed out');
        _updateState(LiveStreamingState.error);
        Future.delayed(const Duration(seconds: 2), () {
          if (_state == LiveStreamingState.error) {
            _updateState(LiveStreamingState.idle);
          }
        });
      }
    });

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

    // Close peer connections immediately to avoid stale connections
    // when another user starts speaking or we start again quickly
    await _closeAllPeerConnections();

    // Reset audio configured flag so next session sets it up fresh
    _audioConfigured = false;
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
        // Close peer connections immediately to avoid stale connections
        _closeAllPeerConnections();
        _audioConfigured = false;
      } else {
        // Someone else stopped speaking - close connections immediately
        debugPrint('LiveStream: Floor released by speaker, returning to idle');
        _closeAllPeerConnections();
        _updateState(LiveStreamingState.idle);
        _audioConfigured = false;
      }
      return;
    }

    _currentSpeakerId = floor.speakerId;
    _speakerController.add((id: floor.speakerId, name: floor.speakerName));

    // Check if we got the floor
    if (floor.speakerId == _wsService.userId) {
      // We got the floor - cancel timeout and start streaming
      _floorRequestTimeout?.cancel();
      _floorRequestTimeout = null;
      debugPrint('LiveStream: We got the floor, starting to broadcast');
      _isBroadcasting = true;
      _updateState(LiveStreamingState.broadcasting);
      _setLocalAudioEnabled(true);
      _startStreamingToListeners();
    } else {
      // Someone else is speaking - prepare to receive
      debugPrint('LiveStream: Someone else is speaking: ${floor.speakerName}');

      // If we were broadcasting, stop and clean up immediately
      if (_isBroadcasting) {
        debugPrint('LiveStream: We were broadcasting, cleaning up');
        _closeAllPeerConnections();
        _audioConfigured = false;
      }

      // Reset debug state for new listening session
      _resetDebugState();

      _isBroadcasting = false;
      _updateState(LiveStreamingState.listening);
    }
  }

  /// Handle floor request denied
  void _handleFloorDenied(String? reason) {
    debugPrint('LiveStream: Floor denied: $reason');
    _floorRequestTimeout?.cancel();
    _floorRequestTimeout = null;

    if (_state == LiveStreamingState.connecting) {
      _updateState(LiveStreamingState.error);
      // Return to idle after a short delay so UI can show the error
      Future.delayed(const Duration(seconds: 2), () {
        if (_state == LiveStreamingState.error) {
          _updateState(LiveStreamingState.idle);
        }
      });
    }
  }

  /// Handle WebSocket reconnection - re-negotiate WebRTC if needed
  void _handleReconnected() {
    debugPrint('LiveStream: WebSocket reconnected');
    // If we had stale peer connections, they are already cleaned up
    // by the disconnection handler above. Nothing more to do -
    // the user can start a new broadcast or will receive new offers.
  }

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

    // CRITICAL: Send offers to ALL listeners IN PARALLEL for simultaneous delivery
    // This ensures all listeners receive the broadcast at the same time
    final listenersToConnect = members
        .where((member) => member.userId != myUserId)
        .toList();

    debugPrint('LiveStream: Sending offers to ${listenersToConnect.length} listeners in parallel');

    // Create all peer connections and send offers simultaneously
    await Future.wait(
      listenersToConnect.map((member) async {
        debugPrint('LiveStream: Creating connection for ${member.userId} (${member.displayName})');
        await _createAndSendOfferToListener(member.userId);
      }),
    );

    debugPrint('LiveStream: All offers sent to listeners');
  }

  /// Create a dedicated peer connection and send offer to a specific listener
  Future<void> _createAndSendOfferToListener(String listenerId) async {
    try {
      // Create peer connection for this listener
      final pc = await _createPeerConnection(listenerId);
      _peerConnections[listenerId] = pc;

      // Note: Listener count will be emitted when ICE actually connects (in onIceConnectionState)

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

    // Use lock to prevent race conditions when processing multiple offers
    await _connectionLock.synchronized(() async {
      try {
        // CRITICAL: Configure audio for playback FIRST, before any WebRTC operations
        // This ensures audio routing is ready when tracks arrive
        if (!_audioConfigured) {
          debugPrint('LiveStream: Pre-configuring audio for receiving');
          await _configureAudioForReceiving();
          _audioConfigured = true;
        }

        // Close any existing PC for this user first to avoid ICE conflicts
        if (_peerConnections.containsKey(fromUserId)) {
          debugPrint('LiveStream: Closing existing PC for $fromUserId before creating new one');
          await _closePeerConnection(fromUserId);
        }

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

        // Apply any pending ICE candidates immediately after remote description is set
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
        // Clean up on error
        await _closePeerConnection(fromUserId);
      }
    });
  }

  /// Handle incoming answer (response to our targeted offer)
  Future<void> _handleIncomingAnswer(String fromUserId, String sdp) async {
    debugPrint('LiveStream: Received answer from $fromUserId, sdp length: ${sdp.length}');

    // Use lock to prevent race conditions
    await _connectionLock.synchronized(() async {
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

          // Apply pending ICE candidates immediately
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
    });
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

    // Use lock to prevent race conditions with offer/answer handling
    await _connectionLock.synchronized(() async {
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
        // Don't log as error - ICE candidates can fail for valid reasons (e.g., connection closed)
      }
    });
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
      // Add directly to per-peer queue (avoids shared list race condition)
      _peerIceCandidates.putIfAbsent(peerId, () => []);
      _peerIceCandidates[peerId]!.add(candidate);
      _scheduleIceBatch(peerId);
    };

    // Handle connection state
    pc.onConnectionState = (RTCPeerConnectionState state) {
      Logger.d('Connection state with $peerId: $state');

      if (state == RTCPeerConnectionState.RTCPeerConnectionStateFailed) {
        // Only close on failed - disconnected is temporary and may recover
        _closePeerConnection(peerId);
      }
      // Note: RTCPeerConnectionStateDisconnected is handled by
      // onIceConnectionState with a 5-second grace period
    };

    // Handle incoming tracks (for listeners)
    pc.onTrack = (RTCTrackEvent event) {
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

        debugPrint('LiveStream: ========== AUDIO TRACK RECEIVED ==========');

        // Audio is already configured in _handleIncomingOffer BEFORE peer connection
        // Just enable the track and set up the renderer - NO async audio config here
        // to avoid race conditions

        // Enable the track immediately (synchronous)
        event.track.enabled = !_isMuted;
        debugPrint('LiveStream: Track enabled: ${event.track.enabled}');

        if (event.streams.isNotEmpty) {
          final remoteStream = event.streams.first;
          _remoteStreams[peerId] = remoteStream;

          // Enable all audio tracks in the stream (synchronous, respects mute state)
          for (final track in remoteStream.getAudioTracks()) {
            track.enabled = !_isMuted;
            debugPrint('LiveStream: Stream track ${track.id} enabled: ${track.enabled}');
          }

          // Create renderer and notify in a non-blocking way
          // Use unawaited future to avoid blocking onTrack callback
          _setupAudioRendererAsync(peerId, remoteStream);
        } else {
          debugPrint('LiveStream: WARNING - No stream in event, only track');
        }
      }
    };

    pc.onIceConnectionState = (RTCIceConnectionState state) async {
      debugPrint('LiveStream: *** ICE Connection State for $peerId: $state ***');

      // Update debug state
      _iceState = state.toString().split('.').last;
      _debugController.add((tracks: _audioTracksReceived, onTrack: _onTrackFired, ice: _iceState));

      if (state == RTCIceConnectionState.RTCIceConnectionStateConnected ||
          state == RTCIceConnectionState.RTCIceConnectionStateCompleted) {
        debugPrint('LiveStream: ICE CONNECTED with $peerId! Audio should flow now.');
        // Reset restart counter on successful connection
        _iceRestartAttempts[peerId] = 0;

        // Track this peer as connected and emit updated count
        if (_isBroadcasting && !_connectedListeners.contains(peerId)) {
          _connectedListeners.add(peerId);
          _emitListenerCount();
        }
      } else if (state == RTCIceConnectionState.RTCIceConnectionStateFailed) {
        debugPrint('LiveStream: ICE FAILED with $peerId! Attempting restart...');

        // Remove from connected listeners
        _connectedListeners.remove(peerId);
        _emitListenerCount();

        // Try ICE restart before giving up
        final attempts = _iceRestartAttempts[peerId] ?? 0;
        if (attempts < _maxIceRestartAttempts && _isBroadcasting) {
          _iceRestartAttempts[peerId] = attempts + 1;
          debugPrint('LiveStream: ICE restart attempt ${attempts + 1}/$_maxIceRestartAttempts');

          try {
            // Trigger ICE restart - this will generate new ICE candidates
            await pc.restartIce();
            debugPrint('LiveStream: ICE restart triggered for $peerId');
          } catch (e) {
            debugPrint('LiveStream: ICE restart failed for $peerId: $e');
            _closePeerConnection(peerId);
          }
        } else {
          debugPrint('LiveStream: Max ICE restart attempts reached for $peerId, closing connection');
          _closePeerConnection(peerId);
        }
      } else if (state == RTCIceConnectionState.RTCIceConnectionStateDisconnected) {
        debugPrint('LiveStream: ICE DISCONNECTED with $peerId - waiting for reconnection...');

        // Temporarily remove from connected (will re-add if reconnects)
        _connectedListeners.remove(peerId);
        _emitListenerCount();

        // Don't close immediately - ICE may recover
        // Use a tracked timer so we can cancel on dispose
        final timer = Timer(const Duration(seconds: 5), () {
          final currentPc = _peerConnections[peerId];
          if (currentPc != null) {
            final currentState = currentPc.iceConnectionState;
            if (currentState == RTCIceConnectionState.RTCIceConnectionStateDisconnected ||
                currentState == RTCIceConnectionState.RTCIceConnectionStateFailed) {
              debugPrint('LiveStream: ICE did not recover for $peerId, closing connection');
              _closePeerConnection(peerId);
            }
          }
        });
        _pendingTimers.add(timer);
      } else if (state == RTCIceConnectionState.RTCIceConnectionStateClosed) {
        debugPrint('LiveStream: ICE CLOSED with $peerId - connection ended normally');

        // Remove from connected listeners
        _connectedListeners.remove(peerId);
        _emitListenerCount();

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
    // Cancel existing timer for this peer
    _peerIceBatchTimers[peerId]?.cancel();

    // Schedule batch send for this peer (50ms batching window)
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

  /// Async setup for audio renderer - called from onTrack without blocking
  Future<void> _setupAudioRendererAsync(String peerId, MediaStream stream) async {
    try {
      // Create renderer
      await _createAudioRenderer(peerId, stream);

      // Notify listeners that stream is ready
      _remoteStreamController.add(stream);
      debugPrint('LiveStream: Stream notification sent');

      // Final audio routing confirmation (only if not already configured)
      // Use a short delay to let Android audio system settle
      await Future.delayed(const Duration(milliseconds: 100));

      // Re-confirm speaker is on (belt and suspenders approach)
      try {
        await NativeAudioService.setSpeakerOn(true);
        await Helper.setSpeakerphoneOn(true);
      } catch (e) {
        // Ignore - audio should already be configured
      }

      // Log final state for debugging
      final audioState = await NativeAudioService.getAudioState();
      debugPrint('LiveStream: ========== FINAL STATE ==========');
      debugPrint('LiveStream: Audio state: $audioState');
      debugPrint('LiveStream: Audio tracks: ${stream.getAudioTracks().length}');
      for (final track in stream.getAudioTracks()) {
        debugPrint('LiveStream: Track ${track.id}: enabled=${track.enabled}, muted=${track.muted}');
      }
      debugPrint('LiveStream: ================================');
    } catch (e) {
      debugPrint('LiveStream: Error in async audio setup: $e');
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
    } catch (e) {
      debugPrint('LiveStream: Failed to create audio renderer: $e');
    }
  }

  /// Emit the current listener count to the stream
  void _emitListenerCount() {
    if (_isBroadcasting) {
      _listenerCountController.add(_connectedListeners.length);
      debugPrint('LiveStream: Connected listener count: ${_connectedListeners.length}');
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

    // Remove from connected listeners and emit updated count
    _connectedListeners.remove(peerId);
    _emitListenerCount();

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
    _connectedListeners.clear();

    // Emit zero listeners
    _listenerCountController.add(0);
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
    // Add bandwidth constraint for audio (b=AS:48 means 48 kbps)
    // This helps with multiple devices by reducing bandwidth per connection
    final lines = sdp.split('\r\n');
    final newLines = <String>[];

    for (int i = 0; i < lines.length; i++) {
      newLines.add(lines[i]);
      // Add bandwidth constraint after m=audio line
      if (lines[i].startsWith('m=audio')) {
        // Check if bandwidth line already exists
        if (i + 1 < lines.length && !lines[i + 1].startsWith('b=')) {
          newLines.add('b=AS:48'); // 48 kbps for audio (covers 24kbps codec + RTP overhead)
        }
      }
    }

    return newLines.join('\r\n');
  }

  /// Clean up resources
  Future<void> dispose() async {
    Logger.d('Disposing LiveStreamingService');

    _floorRequestTimeout?.cancel();
    _offerSubscription?.cancel();
    _answerSubscription?.cancel();
    _iceSubscription?.cancel();
    _floorSubscription?.cancel();
    _floorDeniedSubscription?.cancel();
    _connectionSubscription?.cancel();
    _memberJoinedSubscription?.cancel();

    // Cancel all pending delayed timers (ICE disconnection checks, etc.)
    for (final timer in _pendingTimers) {
      timer.cancel();
    }
    _pendingTimers.clear();

    // Clean up per-peer ICE timers
    for (final timer in _peerIceBatchTimers.values) {
      timer?.cancel();
    }
    _peerIceBatchTimers.clear();
    _peerIceCandidates.clear();
    _pendingOffersSent.clear();
    _iceRestartAttempts.clear();
    _connectedListeners.clear();

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

    // Reset audio mode to normal so it doesn't affect other apps
    try {
      await NativeAudioService.resetAudioMode();
    } catch (_) {}

    await _stateController.close();
    await _remoteStreamController.close();
    await _speakerController.close();
    await _debugController.close();
    await _listenerCountController.close();
  }
}
