import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../features/auth/data/auth_repository.dart';
import '../features/auth/domain/models/user_model.dart';
import '../features/channels/data/channel_repository.dart';
import '../features/channels/domain/models/channel_model.dart';

// Auth state provider - listens to Firebase auth state changes
final authStateProvider = StreamProvider<User?>((ref) {
  final authRepo = ref.watch(authRepositoryProvider);
  return authRepo.authStateChanges;
});

// Current user provider - fetches full user data from Firestore (ONE-TIME read, cached)
final currentUserProvider = FutureProvider<UserModel?>((ref) async {
  final authState = ref.watch(authStateProvider);
  final user = authState.value;
  if (user == null) return null;

  final authRepo = ref.watch(authRepositoryProvider);
  return authRepo.getUserById(user.uid);
});

// REMOVED: currentUserStreamProvider - was causing duplicate reads
// Use currentUserProvider instead and invalidate when needed:
// ref.invalidate(currentUserProvider);

// User channels provider - ONE-TIME fetch, not real-time stream (saves reads)
// Invalidate this provider when you need to refresh: ref.invalidate(userChannelsProvider)
final userChannelsProvider = FutureProvider<List<ChannelModel>>((ref) async {
  final authState = ref.watch(authStateProvider);
  final user = authState.value;
  if (user == null) return [];

  final channelRepo = ref.watch(channelRepositoryProvider);
  return channelRepo.getUserChannelsOnce(user.uid);
});

// Single channel provider - for channel detail screen
final channelProvider =
    StreamProvider.family<ChannelModel?, String>((ref, channelId) {
  final channelRepo = ref.watch(channelRepositoryProvider);
  return channelRepo.channelStream(channelId);
});

// Channel members provider
final channelMembersProvider =
    StreamProvider.family<List<ChannelMember>, String>((ref, channelId) {
  final channelRepo = ref.watch(channelRepositoryProvider);
  return channelRepo.getChannelMembers(channelId);
});

// Auth state notifier for login/logout actions
final authNotifierProvider =
    StateNotifierProvider<AuthNotifier, AsyncValue<void>>((ref) {
  return AuthNotifier(ref.watch(authRepositoryProvider));
});

class AuthNotifier extends StateNotifier<AsyncValue<void>> {
  final AuthRepository _authRepo;

  AuthNotifier(this._authRepo) : super(const AsyncValue.data(null));

  Future<void> signIn(String phoneNumber, String password) async {
    state = const AsyncValue.loading();
    state = await AsyncValue.guard(
      () => _authRepo.signInWithPhoneNumber(
        phoneNumber: phoneNumber,
        password: password,
      ),
    );
  }

  Future<void> signOut() async {
    state = const AsyncValue.loading();
    state = await AsyncValue.guard(() => _authRepo.signOut());
  }

  Future<void> resetPassword(String phoneNumber) async {
    state = const AsyncValue.loading();
    state = await AsyncValue.guard(() => _authRepo.resetPassword(phoneNumber));
  }
}

// Channel actions notifier
final channelNotifierProvider =
    StateNotifierProvider<ChannelNotifier, AsyncValue<void>>((ref) {
  return ChannelNotifier(
    ref.watch(channelRepositoryProvider),
    ref.watch(authStateProvider).value?.uid,
  );
});

class ChannelNotifier extends StateNotifier<AsyncValue<void>> {
  final ChannelRepository _channelRepo;
  final String? _userId;

  ChannelNotifier(this._channelRepo, this._userId)
      : super(const AsyncValue.data(null));

  Future<ChannelModel?> createChannel({
    required String name,
    String? description,
    bool isPrivate = false,
  }) async {
    final userId = _userId;
    if (userId == null) return null;

    state = const AsyncValue.loading();
    ChannelModel? channel;

    state = await AsyncValue.guard(() async {
      channel = await _channelRepo.createChannel(
        name: name,
        description: description,
        ownerId: userId,
        isPrivate: isPrivate,
      );
    });

    return channel;
  }

  Future<void> joinChannel(String channelId) async {
    final userId = _userId;
    if (userId == null) return;

    state = const AsyncValue.loading();
    state = await AsyncValue.guard(
      () => _channelRepo.joinChannel(channelId, userId),
    );
  }

  Future<void> leaveChannel(String channelId) async {
    final userId = _userId;
    if (userId == null) return;

    state = const AsyncValue.loading();
    state = await AsyncValue.guard(
      () => _channelRepo.leaveChannel(channelId, userId),
    );
  }

  Future<void> deleteChannel(String channelId) async {
    state = const AsyncValue.loading();
    state = await AsyncValue.guard(
      () => _channelRepo.deleteChannel(channelId),
    );
  }
}
