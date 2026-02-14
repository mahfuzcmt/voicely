import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';

import '../../../core/utils/logger.dart';

final audioRecordingServiceProvider = Provider<AudioRecordingService>((ref) {
  final service = AudioRecordingService();
  ref.onDispose(() => service.dispose());
  return service;
});

class AudioRecordingService {
  final AudioRecorder _recorder = AudioRecorder();
  String? _currentRecordingPath;

  /// Check if we have microphone permission
  Future<bool> hasPermission() async {
    return await _recorder.hasPermission();
  }

  /// Start recording to a temporary file
  /// Returns true if recording started successfully
  Future<bool> startRecording() async {
    try {
      if (!await hasPermission()) {
        Logger.e('Microphone permission not granted');
        return false;
      }

      // Get temporary directory for the recording
      final tempDir = await getTemporaryDirectory();
      final timestamp = DateTime.now().millisecondsSinceEpoch;
      _currentRecordingPath = '${tempDir.path}/ptt_$timestamp.m4a';

      // Configure recorder for high-quality voice
      const config = RecordConfig(
        encoder: AudioEncoder.aacLc,
        sampleRate: 48000,
        bitRate: 128000,
        numChannels: 1, // Mono for voice
      );

      await _recorder.start(config, path: _currentRecordingPath!);
      Logger.d('Started recording to: $_currentRecordingPath');
      return true;
    } catch (e) {
      Logger.e('Failed to start recording', error: e);
      _currentRecordingPath = null;
      return false;
    }
  }

  /// Stop recording and return the file path
  /// Returns null if recording failed or wasn't started
  Future<String?> stopRecording() async {
    try {
      if (!await _recorder.isRecording()) {
        Logger.w('Recorder is not recording');
        return null;
      }

      final path = await _recorder.stop();
      Logger.d('Stopped recording, file at: $path');

      // Verify the file exists and has content
      if (path != null) {
        final file = File(path);
        if (await file.exists()) {
          final size = await file.length();
          Logger.d('Recording file size: $size bytes');
          if (size > 0) {
            _currentRecordingPath = null;
            return path;
          }
        }
      }

      Logger.w('Recording file invalid or empty');
      _currentRecordingPath = null;
      return null;
    } catch (e) {
      Logger.e('Failed to stop recording', error: e);
      _currentRecordingPath = null;
      return null;
    }
  }

  /// Cancel current recording without saving
  Future<void> cancelRecording() async {
    try {
      if (await _recorder.isRecording()) {
        await _recorder.stop();
      }

      // Delete the temp file if it exists
      if (_currentRecordingPath != null) {
        final file = File(_currentRecordingPath!);
        if (await file.exists()) {
          await file.delete();
        }
      }
      _currentRecordingPath = null;
    } catch (e) {
      Logger.e('Failed to cancel recording', error: e);
    }
  }

  /// Check if currently recording
  Future<bool> isRecording() async {
    return await _recorder.isRecording();
  }

  /// Clean up resources
  void dispose() {
    _recorder.dispose();
  }
}
