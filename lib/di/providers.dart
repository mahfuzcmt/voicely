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

// Current user provider - fetches full user data from Firestore
final currentUserProvider = FutureProvider<UserModel?>((ref) async {
  final authState = ref.watch(authStateProvider);
  final user = authState.value;
  if (user == null) return null;

  final authRepo = ref.watch(authRepositoryProvider);
  return authRepo.getUserById(user.uid);
});

// User stream provider - real-time updates for current user
final currentUserStreamProvider = StreamProvider<UserModel?>((ref) {
  final authState = ref.watch(authStateProvider);
  final user = authState.value;
  if (user == null) return Stream.value(null);

  final authRepo = ref.watch(authRepositoryProvider);
  return authRepo.userStream(user.uid);
});

// User channels provider - real-time list of user's channels
final userChannelsProvider = StreamProvider<List<ChannelModel>>((ref) {
  final authState = ref.watch(authStateProvider);
  final user = authState.value;
  if (user == null) return Stream.value([]);

  final channelRepo = ref.watch(channelRepositoryProvider);
  return channelRepo.getUserChannels(user.uid);
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

  Future<void> signIn(String email, String password) async {
    state = const AsyncValue.loading();
    state = await AsyncValue.guard(
      () => _authRepo.signInWithEmailAndPassword(
        email: email,
        password: password,
      ),
    );
  }

  Future<void> signUp(String email, String password, String displayName) async {
    state = const AsyncValue.loading();
    state = await AsyncValue.guard(
      () => _authRepo.createUserWithEmailAndPassword(
        email: email,
        password: password,
        displayName: displayName,
      ),
    );
  }

  Future<void> signOut() async {
    state = const AsyncValue.loading();
    state = await AsyncValue.guard(() => _authRepo.signOut());
  }

  Future<void> resetPassword(String email) async {
    state = const AsyncValue.loading();
    state = await AsyncValue.guard(() => _authRepo.resetPassword(email));
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
