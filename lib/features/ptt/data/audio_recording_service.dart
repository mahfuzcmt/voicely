import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';

import '../../../core/constants/app_constants.dart';

final audioRecordingServiceProvider = Provider<AudioRecordingService>((ref) {
  return AudioRecordingService();
});

class AudioRecordingService {
  AudioRecorder? _recorder;
  String? _currentPath;

  Future<bool> hasPermission() async {
    _recorder ??= AudioRecorder();
    return await _recorder!.hasPermission();
  }

  Future<bool> startRecording() async {
    try {
      _recorder ??= AudioRecorder();

      final dir = await getTemporaryDirectory();
      final timestamp = DateTime.now().millisecondsSinceEpoch;
      _currentPath = '${dir.path}/ptt_$timestamp.m4a';

      const config = RecordConfig(
        encoder: AudioEncoder.aacLc,
        sampleRate: AppConstants.audioSampleRate,
        numChannels: AppConstants.audioChannels,
        bitRate: AppConstants.audioBitRate,
      );

      await _recorder!.start(config, path: _currentPath!);
      debugPrint('AudioRecording: Started recording to $_currentPath');
      return true;
    } catch (e) {
      debugPrint('AudioRecording: Failed to start recording: $e');
      return false;
    }
  }

  Future<String?> stopRecording() async {
    try {
      if (_recorder == null) return null;

      final path = await _recorder!.stop();
      debugPrint('AudioRecording: Stopped recording, path: $path');

      if (path != null && await File(path).exists()) {
        _currentPath = null;
        return path;
      }

      _currentPath = null;
      return null;
    } catch (e) {
      debugPrint('AudioRecording: Failed to stop recording: $e');
      _currentPath = null;
      return null;
    }
  }

  Future<void> cancelRecording() async {
    try {
      if (_recorder != null) {
        await _recorder!.stop();
      }

      // Delete the temp file
      if (_currentPath != null) {
        final file = File(_currentPath!);
        if (await file.exists()) {
          await file.delete();
          debugPrint('AudioRecording: Cancelled and deleted $_currentPath');
        }
      }
    } catch (e) {
      debugPrint('AudioRecording: Failed to cancel recording: $e');
    } finally {
      _currentPath = null;
    }
  }

  Future<void> dispose() async {
    await cancelRecording();
    await _recorder?.dispose();
    _recorder = null;
  }
}
