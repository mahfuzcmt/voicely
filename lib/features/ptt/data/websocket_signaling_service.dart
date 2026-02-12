import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import '../../../core/constants/app_constants.dart';
import '../../../core/utils/logger.dart';

/// WebSocket connection state
enum WSConnectionState {
  disconnected,
  connecting,
  connected,
  authenticating,
  authenticated,
  reconnecting,
  error,
}

/// Message types matching the server
enum WSMessageType {
  // Connection
  auth,
  authSuccess,
  authFailed,
  ping,
  pong,

  // Room management
  joinRoom,
  leaveRoom,
  roomJoined,
  roomLeft,
  roomMembers,
  memberJoined,
  memberLeft,

  // Floor control
  requestFloor,
  floorGranted,
  floorDenied,
  releaseFloor,
  floorReleased,
  floorTaken,
  floorState,
  floorTimeout,

  // WebRTC signaling
  webrtcOffer,
  webrtcAnswer,
  webrtcIce,
  webrtcIceBatch,

  // Errors
  error,
}

/// Convert message type to string for JSON
String _messageTypeToString(WSMessageType type) {
  switch (type) {
    case WSMessageType.auth:
      return 'auth';
    case WSMessageType.authSuccess:
      return 'auth_success';
    case WSMessageType.authFailed:
      return 'auth_failed';
    case WSMessageType.ping:
      return 'ping';
    case WSMessageType.pong:
      return 'pong';
    case WSMessageType.joinRoom:
      return 'join_room';
    case WSMessageType.leaveRoom:
      return 'leave_room';
    case WSMessageType.roomJoined:
      return 'room_joined';
    case WSMessageType.roomLeft:
      return 'room_left';
    case WSMessageType.roomMembers:
      return 'room_members';
    case WSMessageType.memberJoined:
      return 'member_joined';
    case WSMessageType.memberLeft:
      return 'member_left';
    case WSMessageType.requestFloor:
      return 'request_floor';
    case WSMessageType.floorGranted:
      return 'floor_granted';
    case WSMessageType.floorDenied:
      return 'floor_denied';
    case WSMessageType.releaseFloor:
      return 'release_floor';
    case WSMessageType.floorReleased:
      return 'floor_released';
    case WSMessageType.floorTaken:
      return 'floor_taken';
    case WSMessageType.floorState:
      return 'floor_state';
    case WSMessageType.floorTimeout:
      return 'floor_timeout';
    case WSMessageType.webrtcOffer:
      return 'webrtc_offer';
    case WSMessageType.webrtcAnswer:
      return 'webrtc_answer';
    case WSMessageType.webrtcIce:
      return 'webrtc_ice';
    case WSMessageType.webrtcIceBatch:
      return 'webrtc_ice_batch';
    case WSMessageType.error:
      return 'error';
  }
}

/// Parse message type from string
WSMessageType? _parseMessageType(String type) {
  switch (type) {
    case 'auth':
      return WSMessageType.auth;
    case 'auth_success':
      return WSMessageType.authSuccess;
    case 'auth_failed':
      return WSMessageType.authFailed;
    case 'ping':
      return WSMessageType.ping;
    case 'pong':
      return WSMessageType.pong;
    case 'join_room':
      return WSMessageType.joinRoom;
    case 'leave_room':
      return WSMessageType.leaveRoom;
    case 'room_joined':
      return WSMessageType.roomJoined;
    case 'room_left':
      return WSMessageType.roomLeft;
    case 'room_members':
      return WSMessageType.roomMembers;
    case 'member_joined':
      return WSMessageType.memberJoined;
    case 'member_left':
      return WSMessageType.memberLeft;
    case 'request_floor':
      return WSMessageType.requestFloor;
    case 'floor_granted':
      return WSMessageType.floorGranted;
    case 'floor_denied':
      return WSMessageType.floorDenied;
    case 'release_floor':
      return WSMessageType.releaseFloor;
    case 'floor_released':
      return WSMessageType.floorReleased;
    case 'floor_taken':
      return WSMessageType.floorTaken;
    case 'floor_state':
      return WSMessageType.floorState;
    case 'floor_timeout':
      return WSMessageType.floorTimeout;
    case 'webrtc_offer':
      return WSMessageType.webrtcOffer;
    case 'webrtc_answer':
      return WSMessageType.webrtcAnswer;
    case 'webrtc_ice':
      return WSMessageType.webrtcIce;
    case 'webrtc_ice_batch':
      return WSMessageType.webrtcIceBatch;
    case 'error':
      return WSMessageType.error;
    default:
      return null;
  }
}

/// Room member model
class WSRoomMember {
  final String userId;
  final String displayName;
  final String? photoUrl;
  final DateTime joinedAt;

  WSRoomMember({
    required this.userId,
    required this.displayName,
    this.photoUrl,
    required this.joinedAt,
  });

  factory WSRoomMember.fromJson(Map<String, dynamic> json) {
    return WSRoomMember(
      userId: json['userId'] as String,
      displayName: json['displayName'] as String,
      photoUrl: json['photoUrl'] as String?,
      joinedAt: DateTime.fromMillisecondsSinceEpoch(json['joinedAt'] as int),
    );
  }
}

/// Floor state model
class WSFloorState {
  final String speakerId;
  final String speakerName;
  final String? speakerPhotoUrl;
  final DateTime startedAt;
  final DateTime expiresAt;

  WSFloorState({
    required this.speakerId,
    required this.speakerName,
    this.speakerPhotoUrl,
    required this.startedAt,
    required this.expiresAt,
  });

  factory WSFloorState.fromJson(Map<String, dynamic> json) {
    return WSFloorState(
      speakerId: json['speakerId'] as String,
      speakerName: json['speakerName'] as String,
      speakerPhotoUrl: json['speakerPhotoUrl'] as String?,
      startedAt: DateTime.fromMillisecondsSinceEpoch(json['startedAt'] as int),
      expiresAt: DateTime.fromMillisecondsSinceEpoch(json['expiresAt'] as int),
    );
  }

  bool get isExpired => DateTime.now().isAfter(expiresAt);
}

/// WebSocket message wrapper
class WSMessage {
  final WSMessageType type;
  final Map<String, dynamic> data;

  WSMessage({required this.type, required this.data});

  factory WSMessage.fromJson(Map<String, dynamic> json) {
    final typeStr = json['type'] as String?;
    final type = typeStr != null ? _parseMessageType(typeStr) : null;
    if (type == null) {
      throw FormatException('Unknown message type: $typeStr');
    }
    return WSMessage(type: type, data: json);
  }
}

/// Provider for WebSocket signaling service
final websocketSignalingServiceProvider = Provider<WebSocketSignalingService>((ref) {
  final service = WebSocketSignalingService();
  ref.onDispose(() => service.dispose());
  return service;
});

/// WebSocket signaling service for real-time communication
class WebSocketSignalingService {
  WebSocketChannel? _channel;
  StreamSubscription? _subscription;
  Timer? _heartbeatTimer;
  Timer? _reconnectTimer;

  String? _authToken;
  String? _userId;
  String? _displayName;

  int _reconnectAttempts = 0;
  static const int _maxReconnectAttempts = 5;
  static const Duration _heartbeatInterval = Duration(seconds: 15);
  static const Duration _initialReconnectDelay = Duration(seconds: 1);

  // Auth completion tracking
  Completer<bool>? _authCompleter;

  // State
  WSConnectionState _connectionState = WSConnectionState.disconnected;
  final Set<String> _joinedRooms = {};
  // Track members per room for real-time updates
  final Map<String, List<WSRoomMember>> _roomMembers = {};

  // Stream controllers
  final _connectionStateController = StreamController<WSConnectionState>.broadcast();
  final _messageController = StreamController<WSMessage>.broadcast();
  final _floorStateController = StreamController<({String roomId, WSFloorState? state})>.broadcast();
  final _roomMembersController = StreamController<({String roomId, List<WSRoomMember> members})>.broadcast();
  final _webrtcOfferController = StreamController<({String roomId, String fromUserId, String sdp})>.broadcast();
  final _webrtcAnswerController = StreamController<({String roomId, String fromUserId, String sdp})>.broadcast();
  final _webrtcIceController = StreamController<({String roomId, String fromUserId, String candidate, String sdpMid, int sdpMLineIndex})>.broadcast();

  // Streams
  Stream<WSConnectionState> get connectionState => _connectionStateController.stream;
  Stream<WSMessage> get messages => _messageController.stream;
  Stream<({String roomId, WSFloorState? state})> get floorState => _floorStateController.stream;
  Stream<({String roomId, List<WSRoomMember> members})> get roomMembers => _roomMembersController.stream;
  Stream<({String roomId, String fromUserId, String sdp})> get webrtcOffers => _webrtcOfferController.stream;
  Stream<({String roomId, String fromUserId, String sdp})> get webrtcAnswers => _webrtcAnswerController.stream;
  Stream<({String roomId, String fromUserId, String candidate, String sdpMid, int sdpMLineIndex})> get webrtcIceCandidates => _webrtcIceController.stream;

  // Getters
  WSConnectionState get currentConnectionState => _connectionState;
  bool get isConnected => _connectionState == WSConnectionState.authenticated;
  String? get userId => _userId;
  Set<String> get joinedRooms => Set.unmodifiable(_joinedRooms);

  /// Get current members of a room
  List<WSRoomMember> getRoomMembers(String roomId) {
    return List.unmodifiable(_roomMembers[roomId] ?? []);
  }

  /// Connection timeout duration
  static const Duration _connectionTimeout = Duration(seconds: 15);
  static const Duration _authTimeout = Duration(seconds: 10);

  /// Connect to the signaling server
  Future<bool> connect(String authToken, {String? displayName}) async {
    debugPrint('WS: connect() called with displayName: $displayName');

    if (_connectionState == WSConnectionState.connecting ||
        _connectionState == WSConnectionState.authenticating) {
      debugPrint('WS: Already connecting/authenticating, skipping');
      return false;
    }

    _authToken = authToken;
    _displayName = displayName;
    _updateState(WSConnectionState.connecting);

    final serverUrl = AppConstants.signalingServerUrl;
    debugPrint('WS: Connecting to $serverUrl');

    try {
      final uri = Uri.parse(serverUrl);
      _channel = WebSocketChannel.connect(uri);

      debugPrint('WS: Waiting for ready (timeout: ${_connectionTimeout.inSeconds}s)...');
      // Wait for connection with timeout
      await _channel!.ready.timeout(
        _connectionTimeout,
        onTimeout: () {
          throw TimeoutException('WebSocket connection timed out', _connectionTimeout);
        },
      );

      debugPrint('WS: Connected!');
      _updateState(WSConnectionState.connected);

      // Listen to messages
      _subscription = _channel!.stream.listen(
        _handleMessage,
        onError: _handleError,
        onDone: _handleDone,
      );

      // Authenticate - include displayName so server can broadcast it
      _updateState(WSConnectionState.authenticating);

      // Create completer for auth result
      _authCompleter = Completer<bool>();

      _send({
        'type': _messageTypeToString(WSMessageType.auth),
        'token': authToken,
        if (displayName != null && displayName.isNotEmpty) 'displayName': displayName,
      });

      // Wait for auth result with timeout
      debugPrint('WS: Waiting for auth (timeout: ${_authTimeout.inSeconds}s)...');
      final authResult = await _authCompleter!.future.timeout(
        _authTimeout,
        onTimeout: () {
          debugPrint('WS: Auth timed out');
          _authCompleter = null;
          throw TimeoutException('Authentication timed out', _authTimeout);
        },
      );
      _authCompleter = null;

      if (!authResult) {
        debugPrint('WS: Auth failed');
        return false;
      }

      // Start heartbeat after successful auth
      _startHeartbeat();

      debugPrint('WS: Connection and auth successful');
      return true;
    } catch (e) {
      Logger.e('WebSocket connection failed', error: e);
      _updateState(WSConnectionState.error);
      _scheduleReconnect();
      return false;
    }
  }

  /// Disconnect from the server
  void disconnect() {
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    _reconnectAttempts = 0;

    _stopHeartbeat();
    _subscription?.cancel();
    _channel?.sink.close();
    _channel = null;

    _joinedRooms.clear();
    _roomMembers.clear();
    _updateState(WSConnectionState.disconnected);

    Logger.d('WebSocket disconnected');
  }

  /// Join a room/channel
  void joinRoom(String roomId) {
    if (!isConnected) {
      Logger.w('Cannot join room - not connected');
      return;
    }

    // Prevent duplicate join requests
    if (_joinedRooms.contains(roomId)) {
      debugPrint('WS: Already in room $roomId, skipping join');
      return;
    }

    _send({
      'type': _messageTypeToString(WSMessageType.joinRoom),
      'roomId': roomId,
    });
  }

  /// Leave a room/channel
  void leaveRoom(String roomId) {
    if (!isConnected) return;

    _send({
      'type': _messageTypeToString(WSMessageType.leaveRoom),
      'roomId': roomId,
    });

    _joinedRooms.remove(roomId);
    _roomMembers.remove(roomId);
  }

  /// Request floor control (permission to speak)
  void requestFloor(String roomId) {
    if (!isConnected) {
      Logger.w('Cannot request floor - not connected');
      return;
    }

    _send({
      'type': _messageTypeToString(WSMessageType.requestFloor),
      'roomId': roomId,
    });
  }

  /// Release floor control
  void releaseFloor(String roomId) {
    if (!isConnected) return;

    _send({
      'type': _messageTypeToString(WSMessageType.releaseFloor),
      'roomId': roomId,
    });
  }

  /// Send WebRTC offer
  void sendOffer({
    required String roomId,
    required String sdp,
    String? targetUserId,
  }) {
    if (!isConnected) return;

    _send({
      'type': _messageTypeToString(WSMessageType.webrtcOffer),
      'roomId': roomId,
      'sdp': sdp,
      if (targetUserId != null) 'targetUserId': targetUserId,
    });
  }

  /// Send WebRTC answer
  void sendAnswer({
    required String roomId,
    required String targetUserId,
    required String sdp,
  }) {
    if (!isConnected) return;

    _send({
      'type': _messageTypeToString(WSMessageType.webrtcAnswer),
      'roomId': roomId,
      'targetUserId': targetUserId,
      'sdp': sdp,
    });
  }

  /// Send ICE candidate
  void sendIceCandidate({
    required String roomId,
    required String candidate,
    required String sdpMid,
    required int sdpMLineIndex,
    String? targetUserId,
  }) {
    if (!isConnected) return;

    _send({
      'type': _messageTypeToString(WSMessageType.webrtcIce),
      'roomId': roomId,
      'candidate': candidate,
      'sdpMid': sdpMid,
      'sdpMLineIndex': sdpMLineIndex,
      if (targetUserId != null) 'targetUserId': targetUserId,
    });
  }

  /// Send batched ICE candidates
  void sendIceCandidatesBatch({
    required String roomId,
    required List<Map<String, dynamic>> candidates,
    String? targetUserId,
  }) {
    if (!isConnected) return;

    _send({
      'type': _messageTypeToString(WSMessageType.webrtcIceBatch),
      'roomId': roomId,
      'candidates': candidates,
      if (targetUserId != null) 'targetUserId': targetUserId,
    });
  }

  /// Handle incoming messages
  void _handleMessage(dynamic data) {
    try {
      final json = jsonDecode(data as String) as Map<String, dynamic>;
      final message = WSMessage.fromJson(json);

      debugPrint('WS received: ${message.type}');

      switch (message.type) {
        case WSMessageType.authSuccess:
          _userId = json['userId'] as String?;
          _displayName = json['displayName'] as String?;
          _reconnectAttempts = 0;
          _updateState(WSConnectionState.authenticated);
          Logger.d('WebSocket authenticated as $_userId');

          // Complete auth completer if waiting
          if (_authCompleter != null && !_authCompleter!.isCompleted) {
            _authCompleter!.complete(true);
          }

          // Rejoin rooms after reconnect
          for (final roomId in _joinedRooms.toList()) {
            joinRoom(roomId);
          }
          break;

        case WSMessageType.authFailed:
          Logger.e('WebSocket auth failed: ${json['reason']}');
          _updateState(WSConnectionState.error);

          // Complete auth completer with failure
          if (_authCompleter != null && !_authCompleter!.isCompleted) {
            _authCompleter!.complete(false);
          }

          disconnect();
          break;

        case WSMessageType.pong:
          // Heartbeat response received
          break;

        case WSMessageType.roomJoined:
          final roomId = json['roomId'] as String;
          _joinedRooms.add(roomId);

          final members = (json['members'] as List?)
              ?.map((m) => WSRoomMember.fromJson(m as Map<String, dynamic>))
              .toList() ?? [];
          _roomMembers[roomId] = members;
          _roomMembersController.add((roomId: roomId, members: members));

          final floorData = json['floorState'] as Map<String, dynamic>?;
          final floor = floorData != null ? WSFloorState.fromJson(floorData) : null;
          _floorStateController.add((roomId: roomId, state: floor));
          break;

        case WSMessageType.memberJoined:
          final roomId = json['roomId'] as String;
          final memberData = json['member'] as Map<String, dynamic>;
          final newMember = WSRoomMember.fromJson(memberData);

          // Add new member to the list
          final currentMembers = _roomMembers[roomId] ?? [];
          if (!currentMembers.any((m) => m.userId == newMember.userId)) {
            currentMembers.add(newMember);
            _roomMembers[roomId] = currentMembers;
          }
          _roomMembersController.add((roomId: roomId, members: List.from(currentMembers)));
          debugPrint('WS: Member joined $roomId: ${newMember.displayName}, total: ${currentMembers.length}');
          break;

        case WSMessageType.memberLeft:
          final roomId = json['roomId'] as String;
          final leftUserId = json['userId'] as String;

          // Remove member from the list
          final currentMembers = _roomMembers[roomId] ?? [];
          currentMembers.removeWhere((m) => m.userId == leftUserId);
          _roomMembers[roomId] = currentMembers;
          _roomMembersController.add((roomId: roomId, members: List.from(currentMembers)));
          debugPrint('WS: Member left $roomId: $leftUserId, remaining: ${currentMembers.length}');
          break;

        case WSMessageType.roomMembers:
          final roomId = json['roomId'] as String;
          final members = (json['members'] as List?)
              ?.map((m) => WSRoomMember.fromJson(m as Map<String, dynamic>))
              .toList() ?? [];
          _roomMembers[roomId] = members;
          _roomMembersController.add((roomId: roomId, members: members));
          debugPrint('WS: Room members updated $roomId: ${members.length}');
          break;

        case WSMessageType.floorGranted:
        case WSMessageType.floorDenied:
        case WSMessageType.floorReleased:
        case WSMessageType.floorTaken:
        case WSMessageType.floorTimeout:
          _handleFloorMessage(message.type, json);
          break;

        case WSMessageType.floorState:
          final roomId = json['roomId'] as String;
          final stateData = json['state'] as Map<String, dynamic>?;
          final state = stateData != null ? WSFloorState.fromJson(stateData) : null;
          _floorStateController.add((roomId: roomId, state: state));
          break;

        case WSMessageType.webrtcOffer:
          _webrtcOfferController.add((
            roomId: json['roomId'] as String,
            fromUserId: json['fromUserId'] as String,
            sdp: json['sdp'] as String,
          ));
          break;

        case WSMessageType.webrtcAnswer:
          _webrtcAnswerController.add((
            roomId: json['roomId'] as String,
            fromUserId: json['fromUserId'] as String,
            sdp: json['sdp'] as String,
          ));
          break;

        case WSMessageType.webrtcIce:
          _webrtcIceController.add((
            roomId: json['roomId'] as String,
            fromUserId: json['fromUserId'] as String,
            candidate: json['candidate'] as String,
            sdpMid: json['sdpMid'] as String,
            sdpMLineIndex: json['sdpMLineIndex'] as int,
          ));
          break;

        case WSMessageType.webrtcIceBatch:
          final roomId = json['roomId'] as String;
          final fromUserId = json['fromUserId'] as String;
          final candidates = json['candidates'] as List;
          for (final c in candidates) {
            final candidate = c as Map<String, dynamic>;
            _webrtcIceController.add((
              roomId: roomId,
              fromUserId: fromUserId,
              candidate: candidate['candidate'] as String,
              sdpMid: candidate['sdpMid'] as String,
              sdpMLineIndex: candidate['sdpMLineIndex'] as int,
            ));
          }
          break;

        case WSMessageType.error:
          Logger.e('WebSocket error: ${json['code']} - ${json['message']}');
          break;

        default:
          break;
      }

      _messageController.add(message);
    } catch (e) {
      Logger.e('Error parsing WebSocket message', error: e);
    }
  }

  /// Handle floor-related messages
  void _handleFloorMessage(WSMessageType type, Map<String, dynamic> json) {
    final roomId = json['roomId'] as String;

    switch (type) {
      case WSMessageType.floorGranted:
        final expiresAt = DateTime.fromMillisecondsSinceEpoch(json['expiresAt'] as int);
        _floorStateController.add((
          roomId: roomId,
          state: WSFloorState(
            speakerId: _userId!,
            speakerName: _displayName ?? 'You',
            startedAt: DateTime.now(),
            expiresAt: expiresAt,
          ),
        ));
        break;

      case WSMessageType.floorTaken:
        final speaker = json['speaker'] as Map<String, dynamic>?;
        if (speaker == null) {
          debugPrint('WS: floorTaken - missing speaker data');
          break;
        }
        final speakerId = speaker['userId'] as String?;
        if (speakerId == null || speakerId.isEmpty) {
          debugPrint('WS: floorTaken - missing speakerId');
          break;
        }
        // Handle empty or missing displayName - use a fallback
        String speakerName = speaker['displayName'] as String? ?? '';
        if (speakerName.isEmpty) {
          // Try to get name from other fields or use a generated name
          // Safe substring - handle IDs shorter than 6 chars
          final idSuffix = speakerId.length >= 6 ? speakerId.substring(0, 6) : speakerId;
          speakerName = speaker['name'] as String? ??
                        speaker['email']?.toString().split('@').first ??
                        'User $idSuffix';
        }
        debugPrint('WS: floorTaken - speakerId: $speakerId, speakerName: $speakerName');
        _floorStateController.add((
          roomId: roomId,
          state: WSFloorState(
            speakerId: speakerId,
            speakerName: speakerName,
            speakerPhotoUrl: speaker['photoUrl'] as String?,
            startedAt: DateTime.fromMillisecondsSinceEpoch(speaker['joinedAt'] as int),
            expiresAt: DateTime.fromMillisecondsSinceEpoch(json['expiresAt'] as int),
          ),
        ));
        break;

      case WSMessageType.floorReleased:
      case WSMessageType.floorTimeout:
        _floorStateController.add((roomId: roomId, state: null));
        break;

      case WSMessageType.floorDenied:
        // Floor denied, current state unchanged
        Logger.w('Floor denied: ${json['reason']}');
        break;

      default:
        break;
    }
  }

  /// Handle WebSocket error
  void _handleError(dynamic error) {
    Logger.e('WebSocket error', error: error);
    _updateState(WSConnectionState.error);
    _scheduleReconnect();
  }

  /// Handle WebSocket close
  void _handleDone() {
    Logger.d('WebSocket connection closed');
    _stopHeartbeat();

    if (_connectionState != WSConnectionState.disconnected) {
      _updateState(WSConnectionState.disconnected);
      _scheduleReconnect();
    }
  }

  /// Schedule reconnection attempt
  void _scheduleReconnect() {
    if (_reconnectTimer != null) return;
    if (_authToken == null) return;
    if (_reconnectAttempts >= _maxReconnectAttempts) {
      Logger.e('Max reconnect attempts reached');
      _updateState(WSConnectionState.error);
      return;
    }

    _reconnectAttempts++;
    final delay = _initialReconnectDelay * (1 << (_reconnectAttempts - 1));

    Logger.d('Scheduling reconnect in ${delay.inSeconds}s (attempt $_reconnectAttempts)');
    _updateState(WSConnectionState.reconnecting);

    _reconnectTimer = Timer(delay, () {
      _reconnectTimer = null;
      if (_authToken != null) {
        connect(_authToken!, displayName: _displayName);
      }
    });
  }

  /// Start heartbeat timer
  void _startHeartbeat() {
    _stopHeartbeat();
    _heartbeatTimer = Timer.periodic(_heartbeatInterval, (_) {
      if (_channel != null && isConnected) {
        _send({'type': _messageTypeToString(WSMessageType.ping)});
      }
    });
  }

  /// Stop heartbeat timer
  void _stopHeartbeat() {
    _heartbeatTimer?.cancel();
    _heartbeatTimer = null;
  }

  /// Send a message
  void _send(Map<String, dynamic> message) {
    if (_channel == null) return;

    message['timestamp'] = DateTime.now().millisecondsSinceEpoch;
    _channel!.sink.add(jsonEncode(message));
  }

  /// Update connection state
  void _updateState(WSConnectionState state) {
    if (_connectionState != state) {
      _connectionState = state;
      _connectionStateController.add(state);
      debugPrint('WebSocket state: $state');
    }
  }

  /// Clean up resources
  void dispose() {
    disconnect();
    _connectionStateController.close();
    _messageController.close();
    _floorStateController.close();
    _roomMembersController.close();
    _webrtcOfferController.close();
    _webrtcAnswerController.close();
    _webrtcIceController.close();
  }
}
