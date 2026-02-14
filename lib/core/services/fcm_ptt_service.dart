import 'dart:async';
import 'dart:convert';

import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// FCM message types for PTT
enum FcmPttMessageType {
  /// Someone started speaking in a channel (high priority wake-up)
  liveBroadcastStarted,

  /// Someone stopped speaking
  liveBroadcastEnded,

  /// New recorded voice message available
  voiceMessage,
}

/// FCM PTT message data
class FcmPttMessage {
  final FcmPttMessageType type;
  final String channelId;
  final String channelName;
  final String? speakerId;
  final String? speakerName;
  final String? audioUrl;
  final DateTime timestamp;

  FcmPttMessage({
    required this.type,
    required this.channelId,
    required this.channelName,
    this.speakerId,
    this.speakerName,
    this.audioUrl,
    DateTime? timestamp,
  }) : timestamp = timestamp ?? DateTime.now();

  factory FcmPttMessage.fromRemoteMessage(RemoteMessage message) {
    final data = message.data;
    final typeStr = data['type'] as String? ?? '';

    FcmPttMessageType type;
    switch (typeStr) {
      case 'live_broadcast_started':
        type = FcmPttMessageType.liveBroadcastStarted;
        break;
      case 'live_broadcast_ended':
        type = FcmPttMessageType.liveBroadcastEnded;
        break;
      case 'voice_message':
        type = FcmPttMessageType.voiceMessage;
        break;
      default:
        type = FcmPttMessageType.voiceMessage;
    }

    return FcmPttMessage(
      type: type,
      channelId: data['channelId'] as String? ?? '',
      channelName: data['channelName'] as String? ?? 'Channel',
      speakerId: data['speakerId'] as String?,
      speakerName: data['speakerName'] as String?,
      audioUrl: data['audioUrl'] as String?,
      timestamp: DateTime.now(),
    );
  }

  Map<String, dynamic> toJson() => {
        'type': type.name,
        'channelId': channelId,
        'channelName': channelName,
        'speakerId': speakerId,
        'speakerName': speakerName,
        'audioUrl': audioUrl,
        'timestamp': timestamp.toIso8601String(),
      };
}

/// Service to handle FCM messages for PTT wake-up
///
/// This service handles high-priority FCM data messages that wake up
/// the app when someone starts speaking in a channel.
class FcmPttService {
  static final FcmPttService _instance = FcmPttService._internal();
  factory FcmPttService() => _instance;
  FcmPttService._internal();

  /// Key for storing pending wake-up message in SharedPreferences
  static const String _pendingMessageKey = 'fcm_pending_ptt_message';

  /// Stream controller for live broadcast notifications
  final _liveBroadcastController = StreamController<FcmPttMessage>.broadcast();

  /// Stream of live broadcast started notifications
  Stream<FcmPttMessage> get onLiveBroadcastStarted =>
      _liveBroadcastController.stream
          .where((m) => m.type == FcmPttMessageType.liveBroadcastStarted);

  /// Stream of all PTT messages
  Stream<FcmPttMessage> get onPttMessage => _liveBroadcastController.stream;

  /// Callback to connect WebSocket (set by app)
  Future<bool> Function(String channelId)? onWakeUpForBroadcast;

  /// Handle incoming FCM message (can be called from foreground or background)
  Future<void> handleMessage(RemoteMessage message) async {
    debugPrint('FcmPttService: Handling message: ${message.data}');

    final pttMessage = FcmPttMessage.fromRemoteMessage(message);

    if (pttMessage.channelId.isEmpty) {
      debugPrint('FcmPttService: Invalid message - no channelId');
      return;
    }

    switch (pttMessage.type) {
      case FcmPttMessageType.liveBroadcastStarted:
        await _handleLiveBroadcastStarted(pttMessage);
        break;
      case FcmPttMessageType.liveBroadcastEnded:
        debugPrint('FcmPttService: Broadcast ended in ${pttMessage.channelName}');
        _liveBroadcastController.add(pttMessage);
        break;
      case FcmPttMessageType.voiceMessage:
        debugPrint('FcmPttService: Voice message in ${pttMessage.channelName}');
        _liveBroadcastController.add(pttMessage);
        break;
    }
  }

  /// Handle live broadcast started - this is the critical wake-up path
  Future<void> _handleLiveBroadcastStarted(FcmPttMessage message) async {
    debugPrint('FcmPttService: *** LIVE BROADCAST STARTED ***');
    debugPrint('FcmPttService: Channel: ${message.channelName} (${message.channelId})');
    debugPrint('FcmPttService: Speaker: ${message.speakerName}');

    // Emit to listeners
    _liveBroadcastController.add(message);

    // If we have a wake-up callback, use it to connect
    if (onWakeUpForBroadcast != null) {
      debugPrint('FcmPttService: Triggering wake-up callback');
      try {
        final success = await onWakeUpForBroadcast!(message.channelId);
        debugPrint('FcmPttService: Wake-up callback result: $success');
      } catch (e) {
        debugPrint('FcmPttService: Wake-up callback error: $e');
      }
    } else {
      // Store message for when app is ready
      debugPrint('FcmPttService: No wake-up callback, storing pending message');
      await _storePendingMessage(message);
    }
  }

  /// Store a pending message for when the app initializes
  Future<void> _storePendingMessage(FcmPttMessage message) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_pendingMessageKey, jsonEncode(message.toJson()));
    } catch (e) {
      debugPrint('FcmPttService: Error storing pending message: $e');
    }
  }

  /// Check for and handle any pending wake-up message
  /// Call this when the app initializes and WebSocket is ready
  Future<FcmPttMessage?> checkPendingMessage() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final messageJson = prefs.getString(_pendingMessageKey);

      if (messageJson != null) {
        await prefs.remove(_pendingMessageKey);

        final data = jsonDecode(messageJson) as Map<String, dynamic>;
        final message = FcmPttMessage(
          type: FcmPttMessageType.values.firstWhere(
            (t) => t.name == data['type'],
            orElse: () => FcmPttMessageType.voiceMessage,
          ),
          channelId: data['channelId'] as String,
          channelName: data['channelName'] as String,
          speakerId: data['speakerId'] as String?,
          speakerName: data['speakerName'] as String?,
          audioUrl: data['audioUrl'] as String?,
          timestamp: DateTime.parse(data['timestamp'] as String),
        );

        // Only process if message is recent (within last 30 seconds)
        final age = DateTime.now().difference(message.timestamp);
        if (age.inSeconds < 30) {
          debugPrint('FcmPttService: Found pending message (${age.inSeconds}s old)');
          return message;
        } else {
          debugPrint('FcmPttService: Pending message too old (${age.inSeconds}s), discarding');
        }
      }
    } catch (e) {
      debugPrint('FcmPttService: Error checking pending message: $e');
    }
    return null;
  }

  /// Dispose resources
  void dispose() {
    _liveBroadcastController.close();
  }
}

/// Top-level function to handle FCM background messages for PTT
/// Must be a top-level function (not a class method)
@pragma('vm:entry-point')
Future<void> handleFcmPttBackgroundMessage(RemoteMessage message) async {
  debugPrint('FCM Background: Received message');
  debugPrint('FCM Background: Data: ${message.data}');

  // Handle the PTT message
  final fcmService = FcmPttService();
  await fcmService.handleMessage(message);
}
