import 'dart:io';

import 'package:firebase_storage/firebase_storage.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../../../core/utils/logger.dart';

final audioStorageServiceProvider = Provider<AudioStorageService>((ref) {
  return AudioStorageService(FirebaseStorage.instance);
});

class AudioStorageService {
  final FirebaseStorage _storage;
  static const _uuid = Uuid();

  /// Maximum number of audio files to keep per channel
  /// Older files are automatically deleted to save storage costs
  static const int maxAudiosPerChannel = 5;

  AudioStorageService(this._storage);

  /// Upload audio file to Firebase Storage
  /// Returns the download URL on success, null on failure
  /// OPTIMIZED: Automatically deletes old audios to keep only last 5
  Future<String?> uploadAudio({
    required String filePath,
    required String channelId,
  }) async {
    try {
      final file = File(filePath);
      if (!await file.exists()) {
        Logger.e('Audio file does not exist: $filePath');
        return null;
      }

      // Generate unique ID with timestamp for sorting
      final timestamp = DateTime.now().millisecondsSinceEpoch;
      final audioId = '${timestamp}_${_uuid.v4().substring(0, 8)}';
      final storagePath = 'audio/$channelId/$audioId.m4a';

      Logger.d('Uploading audio to: $storagePath');

      // Upload file
      final ref = _storage.ref().child(storagePath);
      final uploadTask = ref.putFile(
        file,
        SettableMetadata(
          contentType: 'audio/mp4',
          customMetadata: {
            'channelId': channelId,
            'uploadedAt': DateTime.now().toIso8601String(),
          },
        ),
      );

      // Wait for upload to complete
      final snapshot = await uploadTask;

      // Get download URL
      final downloadUrl = await snapshot.ref.getDownloadURL();
      Logger.d('Audio uploaded successfully: $downloadUrl');

      // Delete local temp file after successful upload
      try {
        await file.delete();
        Logger.d('Deleted temp file: $filePath');
      } catch (e) {
        Logger.w('Failed to delete temp file: $e');
      }

      // COST OPTIMIZATION: Clean up old audios (keep only last 5)
      _cleanupOldAudios(channelId);

      return downloadUrl;
    } catch (e) {
      Logger.e('Failed to upload audio', error: e);
      return null;
    }
  }

  /// Delete old audio files, keeping only the most recent ones
  /// Runs in background (fire-and-forget) to not block upload
  Future<void> _cleanupOldAudios(String channelId) async {
    try {
      final channelRef = _storage.ref().child('audio/$channelId');
      final listResult = await channelRef.listAll();

      if (listResult.items.length <= maxAudiosPerChannel) {
        Logger.d('AudioStorage: Channel has ${listResult.items.length} audios, no cleanup needed');
        return;
      }

      // Sort by name (contains timestamp) - oldest first
      final sortedItems = listResult.items.toList()
        ..sort((a, b) => a.name.compareTo(b.name));

      // Delete oldest files, keep only last 5
      final itemsToDelete = sortedItems.length - maxAudiosPerChannel;
      Logger.d('AudioStorage: Deleting $itemsToDelete old audios from channel $channelId');

      for (var i = 0; i < itemsToDelete; i++) {
        try {
          await sortedItems[i].delete();
          Logger.d('AudioStorage: Deleted old audio: ${sortedItems[i].name}');
        } catch (e) {
          Logger.w('AudioStorage: Failed to delete ${sortedItems[i].name}: $e');
        }
      }

      Logger.d('AudioStorage: Cleanup complete, kept last $maxAudiosPerChannel audios');
    } catch (e) {
      // Don't fail the upload if cleanup fails
      Logger.w('AudioStorage: Cleanup failed (non-critical): $e');
    }
  }

  /// Delete an audio file from storage
  Future<void> deleteAudio(String audioUrl) async {
    try {
      final ref = _storage.refFromURL(audioUrl);
      await ref.delete();
      Logger.d('Deleted audio: $audioUrl');
    } catch (e) {
      Logger.e('Failed to delete audio', error: e);
    }
  }
}
