import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/constants/app_constants.dart';
import '../../../core/utils/logger.dart';
import '../domain/models/floor_control_model.dart';

final pttRepositoryProvider = Provider<PttRepository>((ref) {
  return PttRepository(firestore: FirebaseFirestore.instance);
});

class PttRepository {
  final FirebaseFirestore _firestore;

  PttRepository({required FirebaseFirestore firestore}) : _firestore = firestore;

  DocumentReference<Map<String, dynamic>> _floorControlRef(String channelId) =>
      _firestore
          .collection(AppConstants.channelsCollection)
          .doc(channelId)
          .collection('floorControl')
          .doc('current');

  /// Request floor control using atomic Firestore transaction
  /// Returns true if floor was acquired, false otherwise
  Future<bool> requestFloor({
    required String channelId,
    required String speakerId,
    required String speakerName,
  }) async {
    try {
      final floorRef = _floorControlRef(channelId);

      return await _firestore.runTransaction<bool>((transaction) async {
        final floorDoc = await transaction.get(floorRef);

        if (floorDoc.exists) {
          final currentFloor = FloorControlModel.fromFirestore(floorDoc);

          // Check if floor is currently held by someone else and not expired
          if (currentFloor.speakerId != speakerId && !currentFloor.isExpired) {
            return false; // Floor is busy
          }
        }

        // Acquire floor
        final now = DateTime.now();
        final floor = FloorControlModel(
          speakerId: speakerId,
          speakerName: speakerName,
          startedAt: now,
          expiresAt: now.add(AppConstants.pttMaxDuration),
        );

        transaction.set(floorRef, floor.toFirestore());
        return true;
      });
    } catch (e) {
      Logger.e('Request floor error', error: e);
      return false;
    }
  }

  /// Release floor control (only owner can release)
  Future<void> releaseFloor({
    required String channelId,
    required String speakerId,
  }) async {
    try {
      final floorRef = _floorControlRef(channelId);

      await _firestore.runTransaction((transaction) async {
        final floorDoc = await transaction.get(floorRef);

        if (floorDoc.exists) {
          final currentFloor = FloorControlModel.fromFirestore(floorDoc);

          // Only the current speaker can release the floor
          if (currentFloor.speakerId == speakerId) {
            transaction.delete(floorRef);
          }
        }
      });
    } catch (e) {
      Logger.e('Release floor error', error: e);
    }
  }

  /// Stream floor control state for a channel
  Stream<FloorControlModel?> floorControlStream(String channelId) {
    return _floorControlRef(channelId).snapshots().map((snapshot) {
      if (!snapshot.exists) return null;

      try {
        final floor = FloorControlModel.fromFirestore(snapshot);
        // Return null if floor is expired
        if (floor.isExpired) return null;
        return floor;
      } catch (e) {
        Logger.e('Parse floor control error', error: e);
        return null;
      }
    });
  }

  /// Force release floor (for admin use or cleanup)
  Future<void> forceReleaseFloor(String channelId) async {
    try {
      await _floorControlRef(channelId).delete();
    } catch (e) {
      Logger.e('Force release floor error', error: e);
    }
  }

  /// Extend floor time (renew expiration)
  Future<bool> extendFloor({
    required String channelId,
    required String speakerId,
    required Duration extension,
  }) async {
    try {
      final floorRef = _floorControlRef(channelId);

      return await _firestore.runTransaction<bool>((transaction) async {
        final floorDoc = await transaction.get(floorRef);

        if (!floorDoc.exists) return false;

        final currentFloor = FloorControlModel.fromFirestore(floorDoc);

        // Only current speaker can extend
        if (currentFloor.speakerId != speakerId) return false;

        final newExpiry = DateTime.now().add(extension);
        transaction.update(floorRef, {
          'expiresAt': Timestamp.fromDate(newExpiry),
        });

        return true;
      });
    } catch (e) {
      Logger.e('Extend floor error', error: e);
      return false;
    }
  }
}
