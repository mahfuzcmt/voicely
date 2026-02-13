import 'dart:io';

import 'package:firebase_storage/firebase_storage.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

final audioStorageServiceProvider = Provider<AudioStorageService>((ref) {
  return AudioStorageService(storage: FirebaseStorage.instance);
});

class AudioStorageService {
  final FirebaseStorage _storage;

  AudioStorageService({required FirebaseStorage storage}) : _storage = storage;

  Future<String> uploadAudio({
    required String filePath,
    required String channelId,
  }) async {
    final file = File(filePath);
    final timestamp = DateTime.now().millisecondsSinceEpoch;
    final storagePath = 'channels/$channelId/audio/${timestamp}_audio.m4a';

    debugPrint('AudioStorage: Uploading $filePath to $storagePath');

    final ref = _storage.ref().child(storagePath);
    final metadata = SettableMetadata(contentType: 'audio/mp4');

    await ref.putFile(file, metadata);
    final downloadUrl = await ref.getDownloadURL();

    debugPrint('AudioStorage: Upload complete, URL: $downloadUrl');

    // Delete local temp file
    try {
      if (await file.exists()) {
        await file.delete();
        debugPrint('AudioStorage: Deleted local temp file');
      }
    } catch (e) {
      debugPrint('AudioStorage: Failed to delete temp file: $e');
    }

    return downloadUrl;
  }
}
