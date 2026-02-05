import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/constants/app_constants.dart';
import '../../../core/utils/logger.dart';
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

  AuthRepository({
    required FirebaseAuth auth,
    required FirebaseFirestore firestore,
  })  : _auth = auth,
        _firestore = firestore;

  CollectionReference<Map<String, dynamic>> get _usersRef =>
      _firestore.collection(AppConstants.usersCollection);

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

      await _updateUserStatus(user.uid, UserStatus.online);
      return await getUserById(user.uid);
    } on FirebaseAuthException catch (e) {
      Logger.e('Sign in error', error: e);
      rethrow;
    }
  }

  /// Create user with phone number (for admin use)
  Future<UserModel> createUserWithPhoneNumber({
    required String phoneNumber,
    required String password,
    required String displayName,
  }) async {
    try {
      final email = _phoneToEmail(phoneNumber);
      final credential = await _auth.createUserWithEmailAndPassword(
        email: email,
        password: password,
      );
      final user = credential.user;
      if (user == null) throw Exception('Sign up failed');

      await user.updateDisplayName(displayName);

      final userModel = UserModel(
        id: user.uid,
        phoneNumber: phoneNumber,
        displayName: displayName,
        email: email,
        status: UserStatus.online,
        createdAt: DateTime.now(),
      );

      await _usersRef.doc(user.uid).set(userModel.toFirestore());

      return userModel;
    } on FirebaseAuthException catch (e) {
      Logger.e('Sign up error', error: e);
      rethrow;
    }
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
}
