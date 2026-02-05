import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/constants/app_constants.dart';
import '../../../core/utils/logger.dart';
import '../../../firebase_options.dart';
import '../domain/models/user_model.dart';

final authRepositoryProvider = Provider<AuthRepository>((ref) {
  return AuthRepository(
    auth: FirebaseAuth.instance,
    firestore: FirebaseFirestore.instance,
  );
});

class AuthRepository {
  final FirebaseAuth _auth;
  final FirebaseFirestore _firestore;
  FirebaseApp? _secondaryApp;
  FirebaseAuth? _secondaryAuth;

  AuthRepository({
    required FirebaseAuth auth,
    required FirebaseFirestore firestore,
  })  : _auth = auth,
        _firestore = firestore;

  CollectionReference<Map<String, dynamic>> get _usersRef =>
      _firestore.collection(AppConstants.usersCollection);

  CollectionReference<Map<String, dynamic>> get _channelsRef =>
      _firestore.collection(AppConstants.channelsCollection);

  Stream<User?> get authStateChanges => _auth.authStateChanges();

  User? get currentUser => _auth.currentUser;

  /// Convert phone number to email format for Firebase Auth
  /// Firebase Auth doesn't support username/password, so we use phone@voicely.app
  String _phoneToEmail(String phoneNumber) {
    // Remove any non-numeric characters except + for country code
    final cleanPhone = phoneNumber.replaceAll(RegExp(r'[^\d+]'), '');
    return '$cleanPhone@voicely.app';
  }

  /// Sign in with phone number and password
  Future<UserModel> signInWithPhoneNumber({
    required String phoneNumber,
    required String password,
  }) async {
    try {
      final email = _phoneToEmail(phoneNumber);
      final credential = await _auth.signInWithEmailAndPassword(
        email: email,
        password: password,
      );
      final user = credential.user;
      if (user == null) throw Exception('Sign in failed');

      // Check if user document exists in Firestore, create if not
      final userDoc = await _usersRef.doc(user.uid).get();
      if (!userDoc.exists) {
        // Create user document for users created via Firebase Console
        final userModel = UserModel(
          id: user.uid,
          phoneNumber: phoneNumber,
          displayName: user.displayName ?? phoneNumber,
          email: email,
          status: UserStatus.online,
          createdAt: DateTime.now(),
        );
        await _usersRef.doc(user.uid).set(userModel.toFirestore());
        Logger.d('Created Firestore user document for ${user.uid}');
        return userModel;
      }

      await _updateUserStatus(user.uid, UserStatus.online);

      // Save FCM token for push notifications
      await saveFcmToken();

      return await getUserById(user.uid);
    } on FirebaseAuthException catch (e) {
      Logger.e('Sign in error', error: e);
      rethrow;
    }
  }

  /// Initialize secondary Firebase app for creating users without signing out admin
  Future<FirebaseAuth> _getSecondaryAuth() async {
    if (_secondaryAuth != null) return _secondaryAuth!;

    try {
      _secondaryApp = Firebase.app('SecondaryApp');
    } catch (e) {
      _secondaryApp = await Firebase.initializeApp(
        name: 'SecondaryApp',
        options: DefaultFirebaseOptions.currentPlatform,
      );
    }
    _secondaryAuth = FirebaseAuth.instanceFor(app: _secondaryApp!);
    return _secondaryAuth!;
  }

  /// Create user with phone number (for admin use)
  /// Uses a secondary Firebase app to avoid signing out the current admin
  Future<UserModel> createUserWithPhoneNumber({
    required String phoneNumber,
    required String password,
    required String displayName,
    List<String> channelIds = const [],
  }) async {
    try {
      final email = _phoneToEmail(phoneNumber);

      // Use secondary auth to create user without signing out admin
      final secondaryAuth = await _getSecondaryAuth();
      final credential = await secondaryAuth.createUserWithEmailAndPassword(
        email: email,
        password: password,
      );
      final user = credential.user;
      if (user == null) throw Exception('Sign up failed');

      await user.updateDisplayName(displayName);

      // Create user model
      final userModel = UserModel(
        id: user.uid,
        phoneNumber: phoneNumber,
        displayName: displayName,
        email: email,
        status: UserStatus.offline,
        createdAt: DateTime.now(),
      );

      // Save user to Firestore
      await _usersRef.doc(user.uid).set(userModel.toFirestore());
      Logger.d('Created user document for ${user.uid}');

      // Add user to selected channels
      if (channelIds.isNotEmpty) {
        await _addUserToChannels(user.uid, channelIds);
        Logger.d('Added user ${user.uid} to ${channelIds.length} channels');
      }

      // Sign out from secondary auth instance
      await secondaryAuth.signOut();

      return userModel;
    } on FirebaseAuthException catch (e) {
      Logger.e('Sign up error', error: e);
      rethrow;
    }
  }

  /// Add a user to multiple channels
  Future<void> _addUserToChannels(String userId, List<String> channelIds) async {
    final batch = _firestore.batch();

    for (final channelId in channelIds) {
      final channelRef = _channelsRef.doc(channelId);

      // Update channel's memberIds array and count
      batch.update(channelRef, {
        'memberIds': FieldValue.arrayUnion([userId]),
        'memberCount': FieldValue.increment(1),
        'updatedAt': FieldValue.serverTimestamp(),
      });

      // Add member document in subcollection
      final memberRef = channelRef.collection('members').doc(userId);
      batch.set(memberRef, {
        'userId': userId,
        'channelId': channelId,
        'role': 'member',
        'isMuted': false,
        'joinedAt': FieldValue.serverTimestamp(),
      });
    }

    await batch.commit();
  }

  /// Get channels owned by a user
  Future<List<Map<String, dynamic>>> getOwnedChannels(String userId) async {
    final snapshot = await _channelsRef
        .where('ownerId', isEqualTo: userId)
        .get();

    return snapshot.docs.map((doc) {
      final data = doc.data();
      return {
        'id': doc.id,
        'name': data['name'] ?? '',
        'description': data['description'],
        'memberCount': data['memberCount'] ?? 0,
      };
    }).toList();
  }

  Future<void> signOut() async {
    try {
      final userId = _auth.currentUser?.uid;
      if (userId != null) {
        await _updateUserStatus(userId, UserStatus.offline);
      }
      await _auth.signOut();
    } catch (e) {
      Logger.e('Sign out error', error: e);
      rethrow;
    }
  }

  Future<UserModel> getUserById(String userId) async {
    final doc = await _usersRef.doc(userId).get();
    if (!doc.exists) throw Exception('User not found');
    return UserModel.fromFirestore(doc);
  }

  Future<void> updateUser(UserModel user) async {
    await _usersRef.doc(user.id).update(user.toFirestore());
  }

  Future<void> _updateUserStatus(String userId, UserStatus status) async {
    await _usersRef.doc(userId).update({
      'status': status.name,
      'lastSeen': FieldValue.serverTimestamp(),
    });
  }

  Future<void> updateUserStatus(UserStatus status) async {
    final userId = _auth.currentUser?.uid;
    if (userId != null) {
      await _updateUserStatus(userId, status);
    }
  }

  Future<void> resetPassword(String phoneNumber) async {
    final email = _phoneToEmail(phoneNumber);
    await _auth.sendPasswordResetEmail(email: email);
  }

  Stream<UserModel?> userStream(String userId) {
    return _usersRef.doc(userId).snapshots().map((doc) {
      if (!doc.exists) return null;
      return UserModel.fromFirestore(doc);
    });
  }

  /// Save FCM token to user document for push notifications
  Future<void> saveFcmToken() async {
    final userId = _auth.currentUser?.uid;
    if (userId == null) return;

    try {
      final token = await FirebaseMessaging.instance.getToken();
      if (token != null) {
        await _usersRef.doc(userId).update({
          'fcmToken': token,
          'fcmTokenUpdatedAt': FieldValue.serverTimestamp(),
        });
        Logger.d('Saved FCM token for user $userId');
      }
    } catch (e) {
      Logger.e('Failed to save FCM token', error: e);
    }
  }

  /// Get FCM tokens for channel members (for sending notifications)
  Future<List<String>> getChannelMemberTokens(String channelId, String excludeUserId) async {
    final channelDoc = await _channelsRef.doc(channelId).get();
    if (!channelDoc.exists) return [];

    final memberIds = List<String>.from(channelDoc.data()?['memberIds'] ?? []);
    memberIds.remove(excludeUserId);

    final tokens = <String>[];
    for (final memberId in memberIds) {
      final userDoc = await _usersRef.doc(memberId).get();
      final token = userDoc.data()?['fcmToken'] as String?;
      if (token != null && token.isNotEmpty) {
        tokens.add(token);
      }
    }

    return tokens;
  }
}
