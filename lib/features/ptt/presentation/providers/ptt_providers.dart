import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../di/providers.dart';
import '../../../channels/data/channel_repository.dart';
import '../../../messaging/data/message_repository.dart';
import '../../data/audio_recording_service.dart';
import '../../data/audio_storage_service.dart';
import '../../data/ptt_repository.dart';
import '../../data/signaling_repository.dart';
import '../../data/webrtc_service.dart';
import '../../domain/models/floor_control_model.dart';
import '../../domain/models/ptt_session_model.dart';
import '../../domain/models/signaling_model.dart';

/// Stream provider for floor control state
final floorControlProvider =
    StreamProvider.family<FloorControlModel?, String>((ref, channelId) {
  final pttRepo = ref.watch(pttRepositoryProvider);
  return pttRepo.floorControlStream(channelId);
});

/// Provider for current speaker info
final currentSpeakerProvider =
    Provider.family<({String? id, String? name})?, String>((ref, channelId) {
  final floorControl = ref.watch(floorControlProvider(channelId));
  return floorControl.when(
    data: (floor) {
      if (floor == null) return null;
      return (id: floor.speakerId, name: floor.speakerName);
    },
    loading: () => null,
    error: (_, __) => null,
  );
});

/// Check if current user is the speaker
final isCurrentUserSpeakingProvider =
    Provider.family<bool, String>((ref, channelId) {
  final speaker = ref.watch(currentSpeakerProvider(channelId));
  final currentUser = ref.watch(authStateProvider).value;
  if (speaker == null || currentUser == null) return false;
  return speaker.id == currentUser.uid;
});

/// PTT Session state notifier provider
final pttSessionProvider = StateNotifierProvider.autoDispose
    .family<PttSessionNotifier, PttSessionModel, String>((ref, channelId) {
  return PttSessionNotifier(
    ref: ref,
    channelId: channelId,
  );
});

class PttSessionNotifier extends StateNotifier<PttSessionModel> {
  final Ref _ref;
  final String channelId;

  StreamSubscription? _floorControlSubscription;
  StreamSubscription? _signalingSubscription;
  StreamSubscription? _iceCandidatesSubscription;
  StreamSubscription? _remoteStreamSubscription;

  final Set<String> _processedSignalingIds = {};
  final Set<String> _processedIceCandidateIds = {};

  DateTime? _transmissionStartTime;

  PttSessionNotifier({
    required Ref ref,
    required this.channelId,
  })  : _ref = ref,
        super(PttSessionModel(channelId: channelId)) {
    _initListeners();
  }

  void _initListeners() {
    final currentUser = _ref.read(authStateProvider).value;
    if (currentUser == null) return;

    final pttRepo = _ref.read(pttRepositoryProvider);
    final signalingRepo = _ref.read(signalingRepositoryProvider);

    // Listen to floor control changes
    _floorControlSubscription =
        pttRepo.floorControlStream(channelId).listen((floor) {
      _handleFloorControlChange(floor, currentUser.uid);
    });

    // Listen for signaling messages
    _signalingSubscription = signalingRepo
        .listenForSignaling(
      channelId: channelId,
      currentUserId: currentUser.uid,
    )
        .listen((messages) {
      _handleSignalingMessages(messages, currentUser.uid);
    });

    // Listen for ICE candidates
    _iceCandidatesSubscription = signalingRepo
        .listenForIceCandidates(
      channelId: channelId,
      currentUserId: currentUser.uid,
    )
        .listen((candidates) {
      _handleIceCandidates(candidates);
    });
  }

  void _handleFloorControlChange(FloorControlModel? floor, String currentUserId) {
    if (floor == null) {
      // Floor is free - return to idle
      if (state.state != PttSessionState.idle) {
        _stopReceiving();
        state = state.copyWith(
          state: PttSessionState.idle,
          currentSpeakerId: null,
          currentSpeakerName: null,
        );
      }
      return;
    }

    if (floor.speakerId == currentUserId) {
      // Current user is the speaker
      if (state.state != PttSessionState.transmitting) {
        state = state.copyWith(
          state: PttSessionState.transmitting,
          currentSpeakerId: floor.speakerId,
          currentSpeakerName: floor.speakerName,
        );
      }
    } else {
      // Someone else is speaking
      state = state.copyWith(
        state: PttSessionState.receiving,
        currentSpeakerId: floor.speakerId,
        currentSpeakerName: floor.speakerName,
      );
    }
  }

  Future<void> _handleSignalingMessages(
    List<SignalingModel> messages,
    String currentUserId,
  ) async {
    final webrtcService = _ref.read(webrtcServiceProvider(channelId));
    final signalingRepo = _ref.read(signalingRepositoryProvider);

    for (final message in messages) {
      // Skip already processed messages
      if (_processedSignalingIds.contains(message.id)) continue;
      _processedSignalingIds.add(message.id);

      if (message.type == SignalingType.offer) {
        await webrtcService.handleOffer(
          currentUserId: currentUserId,
          fromUserId: message.fromUserId,
          sdp: message.sdp,
        );
      } else if (message.type == SignalingType.answer) {
        await webrtcService.handleAnswer(
          fromUserId: message.fromUserId,
          sdp: message.sdp,
        );
      }

      // Delete processed signaling document
      await signalingRepo.deleteSignaling(
        channelId: channelId,
        signalingId: message.id,
      );
    }
  }

  Future<void> _handleIceCandidates(List<IceCandidateModel> candidates) async {
    final webrtcService = _ref.read(webrtcServiceProvider(channelId));
    final signalingRepo = _ref.read(signalingRepositoryProvider);

    for (final candidate in candidates) {
      // Skip already processed candidates
      if (_processedIceCandidateIds.contains(candidate.id)) continue;
      _processedIceCandidateIds.add(candidate.id);

      await webrtcService.handleIceCandidate(
        fromUserId: candidate.fromUserId,
        candidate: candidate.candidate,
        sdpMid: candidate.sdpMid,
        sdpMLineIndex: candidate.sdpMLineIndex,
      );

      // Delete processed ICE candidate document
      await signalingRepo.deleteIceCandidate(
        channelId: channelId,
        candidateId: candidate.id,
      );
    }
  }

  /// Start PTT transmission
  Future<bool> startPtt() async {
    final currentUser = _ref.read(authStateProvider).value;
    final userProfile = await _ref.read(currentUserProvider.future);

    if (currentUser == null || userProfile == null) {
      state = state.copyWith(
        state: PttSessionState.error,
        errorMessage: 'User not authenticated',
      );
      return false;
    }

    state = state.copyWith(state: PttSessionState.requestingFloor);

    final pttRepo = _ref.read(pttRepositoryProvider);
    final channelRepo = _ref.read(channelRepositoryProvider);
    final webrtcService = _ref.read(webrtcServiceProvider(channelId));
    final audioRecordingService = _ref.read(audioRecordingServiceProvider);

    try {
      // Request floor
      final acquired = await pttRepo.requestFloor(
        channelId: channelId,
        speakerId: currentUser.uid,
        speakerName: userProfile.displayName,
      );

      if (!acquired) {
        state = state.copyWith(
          state: PttSessionState.idle,
          errorMessage: 'Floor is busy',
        );
        return false;
      }

      // Initialize local stream
      final localStream = await webrtcService.initLocalStream();
      if (localStream == null) {
        await pttRepo.releaseFloor(
          channelId: channelId,
          speakerId: currentUser.uid,
        );
        state = state.copyWith(
          state: PttSessionState.error,
          errorMessage: 'Failed to access microphone',
        );
        return false;
      }

      // Start audio recording for storage
      await audioRecordingService.startRecording();

      // Get channel members and create offers
      final members = await channelRepo.getChannelMembers(channelId).first;
      final otherMembers = members
          .where((m) => m.userId != currentUser.uid)
          .map((m) => m.userId)
          .toList();

      // Create offers for all other members
      for (final peerId in otherMembers) {
        await webrtcService.createOfferAndSend(
          currentUserId: currentUser.uid,
          peerId: peerId,
        );
      }

      // Track transmission start time
      _transmissionStartTime = DateTime.now();

      state = state.copyWith(
        state: PttSessionState.transmitting,
        currentSpeakerId: currentUser.uid,
        currentSpeakerName: userProfile.displayName,
      );

      return true;
    } catch (e) {
      // Clean up on error
      await pttRepo.releaseFloor(
        channelId: channelId,
        speakerId: currentUser.uid,
      );
      await webrtcService.dispose();
      await audioRecordingService.cancelRecording();
      state = state.copyWith(
        state: PttSessionState.error,
        errorMessage: 'Failed to start transmission',
      );
      return false;
    }
  }

  /// Stop PTT transmission
  Future<void> stopPtt() async {
    final currentUser = _ref.read(authStateProvider).value;
    if (currentUser == null) return;

    final pttRepo = _ref.read(pttRepositoryProvider);
    final signalingRepo = _ref.read(signalingRepositoryProvider);
    final webrtcService = _ref.read(webrtcServiceProvider(channelId));
    final messageRepo = _ref.read(messageRepositoryProvider);
    final audioRecordingService = _ref.read(audioRecordingServiceProvider);
    final audioStorageService = _ref.read(audioStorageServiceProvider);

    // Calculate transmission duration
    int durationSeconds = 0;
    if (_transmissionStartTime != null) {
      durationSeconds =
          DateTime.now().difference(_transmissionStartTime!).inSeconds;
    }

    // Stop recording and get file path
    final audioFilePath = await audioRecordingService.stopRecording();

    // Upload to Firebase Storage
    String? audioUrl;
    if (audioFilePath != null) {
      audioUrl = await audioStorageService.uploadAudio(
        filePath: audioFilePath,
        channelId: channelId,
      );
    }

    // Save audio message record (minimum 1 second)
    if (durationSeconds >= 1) {
      final userProfile = await _ref.read(currentUserProvider.future);
      if (userProfile != null) {
        await messageRepo.sendAudioMessage(
          channelId: channelId,
          senderId: currentUser.uid,
          senderName: userProfile.displayName,
          senderPhotoUrl: userProfile.photoUrl,
          durationSeconds: durationSeconds,
          audioUrl: audioUrl,
        );
      }
    }

    _transmissionStartTime = null;

    // Release floor
    await pttRepo.releaseFloor(
      channelId: channelId,
      speakerId: currentUser.uid,
    );

    // Dispose WebRTC resources
    await webrtcService.dispose();

    // Clean up all signaling
    await signalingRepo.cleanupAllSignaling(channelId);

    state = state.copyWith(
      state: PttSessionState.idle,
      currentSpeakerId: null,
      currentSpeakerName: null,
    );
  }

  void _stopReceiving() {
    final webrtcService = _ref.read(webrtcServiceProvider(channelId));
    webrtcService.dispose();
  }

  void clearError() {
    state = state.copyWith(
      state: PttSessionState.idle,
      errorMessage: null,
    );
  }

  /// Reset stuck state and force release floor
  Future<void> forceReset() async {
    final currentUser = _ref.read(authStateProvider).value;
    if (currentUser == null) return;

    final pttRepo = _ref.read(pttRepositoryProvider);
    final webrtcService = _ref.read(webrtcServiceProvider(channelId));

    // Force release the floor
    await pttRepo.forceReleaseFloor(channelId);
    await webrtcService.dispose();

    state = state.copyWith(
      state: PttSessionState.idle,
      currentSpeakerId: null,
      currentSpeakerName: null,
      errorMessage: null,
    );
  }

  @override
  void dispose() {
    _floorControlSubscription?.cancel();
    _signalingSubscription?.cancel();
    _iceCandidatesSubscription?.cancel();
    _remoteStreamSubscription?.cancel();
    super.dispose();
  }
}
