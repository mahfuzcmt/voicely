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

  AudioStorageService(this._storage);

  /// Upload audio file to Firebase Storage
  /// Returns the download URL on success, null on failure
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

      // Generate unique ID for the audio file
      final audioId = _uuid.v4();
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

      return downloadUrl;
    } catch (e) {
      Logger.e('Failed to upload audio', error: e);
      return null;
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
