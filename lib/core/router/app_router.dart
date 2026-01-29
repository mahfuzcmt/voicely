import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../features/auth/presentation/screens/login_screen.dart';
import '../../features/auth/presentation/screens/register_screen.dart';
import '../../features/auth/presentation/screens/splash_screen.dart';
import '../../features/channels/presentation/screens/channels_screen.dart';
import '../../features/channels/presentation/screens/channel_detail_screen.dart';
import '../../features/channels/presentation/screens/create_channel_screen.dart';
import '../../features/auth/presentation/screens/profile_screen.dart';
import '../../di/providers.dart';

final routerProvider = Provider<GoRouter>((ref) {
  final authState = ref.watch(authStateProvider);

  return GoRouter(
    initialLocation: '/',
    debugLogDiagnostics: true,
    redirect: (context, state) {
      final isLoading = authState.isLoading;
      final isLoggedIn = authState.value != null;
      final isAuthRoute = state.matchedLocation == '/login' ||
          state.matchedLocation == '/register';
      final isSplash = state.matchedLocation == '/';

      if (isLoading && isSplash) return null;
      if (isLoading) return '/';

      if (!isLoggedIn && !isAuthRoute && !isSplash) return '/login';
      if (isLoggedIn && (isAuthRoute || isSplash)) return '/channels';

      return null;
    },
    routes: [
      GoRoute(
        path: '/',
        name: 'splash',
        builder: (context, state) => const SplashScreen(),
      ),
      GoRoute(
        path: '/login',
        name: 'login',
        builder: (context, state) => const LoginScreen(),
      ),
      GoRoute(
        path: '/register',
        name: 'register',
        builder: (context, state) => const RegisterScreen(),
      ),
      GoRoute(
        path: '/channels',
        name: 'channels',
        builder: (context, state) => const ChannelsScreen(),
        routes: [
          GoRoute(
            path: 'create',
            name: 'createChannel',
            builder: (context, state) => const CreateChannelScreen(),
          ),
          GoRoute(
            path: ':channelId',
            name: 'channelDetail',
            builder: (context, state) {
              final channelId = state.pathParameters['channelId']!;
              return ChannelDetailScreen(channelId: channelId);
            },
          ),
        ],
      ),
      GoRoute(
        path: '/profile',
        name: 'profile',
        builder: (context, state) => const ProfileScreen(),
      ),
    ],
    errorBuilder: (context, state) => Scaffold(
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.error_outline, size: 64, color: Colors.red),
            const SizedBox(height: 16),
            Text(
              'Page not found',
              style: Theme.of(context).textTheme.headlineSmall,
            ),
            const SizedBox(height: 8),
            Text(state.error?.message ?? 'Unknown error'),
            const SizedBox(height: 16),
            ElevatedButton(
              onPressed: () => context.go('/channels'),
              child: const Text('Go Home'),
            ),
          ],
        ),
      ),
    ),
  );
});
