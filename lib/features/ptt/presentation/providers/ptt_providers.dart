import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../di/providers.dart';
import '../../../messaging/data/message_repository.dart';
import '../../data/audio_recording_service.dart';
import '../../data/audio_storage_service.dart';

/// Simple PTT state
enum PttState {
  idle,
  recording,
  uploading,
  error,
}

/// PTT Session model
class PttSessionState {
  final PttState state;
  final String? errorMessage;
  final DateTime? recordingStartTime;

  const PttSessionState({
    this.state = PttState.idle,
    this.errorMessage,
    this.recordingStartTime,
  });

  PttSessionState copyWith({
    PttState? state,
    String? errorMessage,
    DateTime? recordingStartTime,
  }) {
    return PttSessionState(
      state: state ?? this.state,
      errorMessage: errorMessage,
      recordingStartTime: recordingStartTime ?? this.recordingStartTime,
    );
  }

  bool get canRecord => state == PttState.idle;
  bool get isRecording => state == PttState.recording;
  bool get isUploading => state == PttState.uploading;
}

/// PTT Session provider
final pttSessionProvider = StateNotifierProvider.autoDispose
    .family<PttSessionNotifier, PttSessionState, String>((ref, channelId) {
  return PttSessionNotifier(
    ref: ref,
    channelId: channelId,
  );
});

class PttSessionNotifier extends StateNotifier<PttSessionState> {
  final Ref _ref;
  final String channelId;

  PttSessionNotifier({
    required Ref ref,
    required this.channelId,
  })  : _ref = ref,
        super(const PttSessionState());

  /// Start recording
  Future<bool> startRecording() async {
    if (!state.canRecord) return false;

    final audioRecordingService = _ref.read(audioRecordingServiceProvider);

    // Check permission
    final hasPermission = await audioRecordingService.hasPermission();
    if (!hasPermission) {
      state = state.copyWith(
        state: PttState.error,
        errorMessage: 'Microphone permission required',
      );
      return false;
    }

    // Start recording
    final started = await audioRecordingService.startRecording();
    if (!started) {
      state = state.copyWith(
        state: PttState.error,
        errorMessage: 'Failed to start recording',
      );
      return false;
    }

    state = PttSessionState(
      state: PttState.recording,
      recordingStartTime: DateTime.now(),
    );

    debugPrint('PTT: Recording started');
    return true;
  }

  /// Stop recording and send
  Future<bool> stopRecordingAndSend() async {
    if (!state.isRecording) return false;

    final currentUser = _ref.read(authStateProvider).value;
    if (currentUser == null) {
      state = state.copyWith(
        state: PttState.error,
        errorMessage: 'Not logged in',
      );
      return false;
    }

    // Calculate duration
    int durationSeconds = 0;
    if (state.recordingStartTime != null) {
      durationSeconds = DateTime.now().difference(state.recordingStartTime!).inSeconds;
    }

    // Update state to uploading
    state = state.copyWith(state: PttState.uploading);

    final audioRecordingService = _ref.read(audioRecordingServiceProvider);
    final audioStorageService = _ref.read(audioStorageServiceProvider);
    final messageRepo = _ref.read(messageRepositoryProvider);

    try {
      // Stop recording
      final audioFilePath = await audioRecordingService.stopRecording();
      debugPrint('PTT: Recording stopped, file: $audioFilePath');

      if (audioFilePath == null) {
        debugPrint('PTT: No audio file recorded');
        state = const PttSessionState(state: PttState.idle);
        return false;
      }

      // Upload to Firebase Storage
      debugPrint('PTT: Uploading audio...');
      final audioUrl = await audioStorageService.uploadAudio(
        filePath: audioFilePath,
        channelId: channelId,
      );
      debugPrint('PTT: Audio uploaded, URL: $audioUrl');

      // Get user profile for sender name
      final userProfile = await _ref.read(currentUserProvider.future);
      final senderName = userProfile?.displayName ??
                         currentUser.displayName ??
                         'User';

      // Create message
      debugPrint('PTT: Creating message...');
      await messageRepo.sendAudioMessage(
        channelId: channelId,
        senderId: currentUser.uid,
        senderName: senderName,
        senderPhotoUrl: userProfile?.photoUrl,
        durationSeconds: durationSeconds > 0 ? durationSeconds : 1,
        audioUrl: audioUrl,
      );
      debugPrint('PTT: Message created successfully');

      state = const PttSessionState(state: PttState.idle);
      return true;
    } catch (e) {
      debugPrint('PTT: Error - $e');
      state = state.copyWith(
        state: PttState.error,
        errorMessage: 'Failed to send voice message',
      );
      return false;
    }
  }

  /// Cancel recording
  Future<void> cancelRecording() async {
    if (!state.isRecording) return;

    final audioRecordingService = _ref.read(audioRecordingServiceProvider);
    await audioRecordingService.cancelRecording();

    state = const PttSessionState(state: PttState.idle);
    debugPrint('PTT: Recording cancelled');
  }

  void clearError() {
    state = const PttSessionState(state: PttState.idle);
  }
}

// Keep these for compatibility but they're not used in simplified flow
final floorControlProvider =
    StreamProvider.family<dynamic, String>((ref, channelId) {
  return Stream.value(null);
});

final currentSpeakerProvider =
    Provider.family<({String? id, String? name})?, String>((ref, channelId) {
  return null;
});

final isCurrentUserSpeakingProvider =
    Provider.family<bool, String>((ref, channelId) {
  return false;
});
