import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../../core/theme/app_colors.dart';
import '../../../../core/utils/extensions.dart';
import '../../../../di/providers.dart';
import '../../../../main.dart' show getPendingChannelId, notificationTapStream;
import '../../domain/models/channel_model.dart';
import '../widgets/channel_tile.dart';
import 'dart:async';

class ChannelsScreen extends ConsumerStatefulWidget {
  const ChannelsScreen({super.key});

  @override
  ConsumerState<ChannelsScreen> createState() => _ChannelsScreenState();
}

class _ChannelsScreenState extends ConsumerState<ChannelsScreen> {
  bool _hasAutoNavigated = false;
  bool _hasCheckedPendingChannel = false;
  StreamSubscription<String>? _notificationTapSubscription;

  @override
  void initState() {
    super.initState();
    // Listen for notification taps while app is open
    _notificationTapSubscription = notificationTapStream.listen((channelId) {
      debugPrint('ChannelsScreen: Notification tap received for channel: $channelId');
      if (mounted && channelId.isNotEmpty) {
        // Navigate to the channel
        context.goNamed(
          'channelDetail',
          pathParameters: {'channelId': channelId},
        );
      }
    });
  }

  @override
  void dispose() {
    _notificationTapSubscription?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final channelsAsync = ref.watch(userChannelsProvider);
    final userAsync = ref.watch(currentUserProvider); // Changed from Stream to Future (saves reads)

    // Check for pending channel from notification tap FIRST
    // This takes priority over single-channel auto-navigation
    channelsAsync.whenData((channels) {
      if (!_hasCheckedPendingChannel) {
        _hasCheckedPendingChannel = true;
        final pendingChannelId = getPendingChannelId();

        if (pendingChannelId != null && pendingChannelId.isNotEmpty) {
          // Check if user has access to this channel
          final hasAccess = channels.any((c) => c.id == pendingChannelId);

          if (hasAccess) {
            debugPrint('ChannelsScreen: Auto-navigating to pending channel: $pendingChannelId');
            _hasAutoNavigated = true;
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (mounted) {
                context.goNamed(
                  'channelDetail',
                  pathParameters: {'channelId': pendingChannelId},
                );
              }
            });
            return; // Skip single-channel auto-nav
          } else {
            debugPrint('ChannelsScreen: User has no access to pending channel: $pendingChannelId');
          }
        }
      }

      // Auto-navigate to channel if there's only one (and no pending channel)
      if (channels.length == 1 && !_hasAutoNavigated) {
        _hasAutoNavigated = true;
        // Use addPostFrameCallback to navigate after build completes
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) {
            context.goNamed(
              'channelDetail',
              pathParameters: {'channelId': channels.first.id},
            );
          }
        });
      }
    });

    return Scaffold(
      appBar: AppBar(
        title: const Text('Channels'),
        leading: userAsync.when(
          data: (user) => GestureDetector(
            onTap: () => context.pushNamed('profile'),
            child: Padding(
              padding: const EdgeInsets.all(8.0),
              child: CircleAvatar(
                backgroundColor: AppColors.primary,
                backgroundImage: user?.photoUrl?.isNotEmpty == true
                    ? NetworkImage(user!.photoUrl!)
                    : null,
                child: user?.photoUrl?.isNotEmpty != true
                    ? Text(
                        user?.displayName.isNotEmpty == true
                            ? user!.displayName[0].toUpperCase()
                            : 'U',
                        style: const TextStyle(
                          color: Colors.black,
                          fontWeight: FontWeight.bold,
                        ),
                      )
                    : null,
              ),
            ),
          ),
          loading: () => const Padding(
            padding: EdgeInsets.all(8.0),
            child: CircleAvatar(backgroundColor: AppColors.cardDark),
          ),
          error: (_, __) => const Icon(Icons.person),
        ),
        actions: [
          // Create user button
          IconButton(
            icon: const Icon(Icons.person_add),
            tooltip: 'Create User',
            onPressed: () => context.pushNamed('createUser'),
          ),
        ],
      ),
      body: channelsAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, _) => Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.error_outline, size: 64, color: AppColors.error),
              const SizedBox(height: 16),
              const Text(
                'Unable to load channels',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w500),
              ),
              const SizedBox(height: 8),
              const Text(
                'Please check your connection and try again',
                style: TextStyle(color: Colors.grey),
              ),
              const SizedBox(height: 16),
              ElevatedButton.icon(
                onPressed: () => ref.invalidate(userChannelsProvider),
                icon: const Icon(Icons.refresh),
                label: const Text('Retry'),
              ),
            ],
          ),
        ),
        data: (channels) {
          if (channels.isEmpty) {
            return _buildEmptyState(context);
          }
          return _buildChannelList(context, ref, channels);
        },
      ),
    );
  }

  Widget _buildEmptyState(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              width: 100,
              height: 100,
              decoration: BoxDecoration(
                color: AppColors.cardDark,
                borderRadius: BorderRadius.circular(25),
              ),
              child: const Icon(
                Icons.group_outlined,
                size: 50,
                color: AppColors.textSecondaryDark,
              ),
            ),
            const SizedBox(height: 24),
            Text(
              'No Channels Assigned',
              style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
            ),
            const SizedBox(height: 8),
            Text(
              'Contact your administrator to get assigned to a channel.',
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: AppColors.textSecondaryDark,
                  ),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildChannelList(
      BuildContext context, WidgetRef ref, List<ChannelModel> channels) {
    return RefreshIndicator(
      onRefresh: () async {
        ref.invalidate(userChannelsProvider);
      },
      child: ListView.builder(
        padding: const EdgeInsets.symmetric(vertical: 8),
        itemCount: channels.length,
        itemBuilder: (context, index) {
          final channel = channels[index];
          return ChannelTile(
            channel: channel,
            onTap: () => context.pushNamed(
              'channelDetail',
              pathParameters: {'channelId': channel.id},
            ),
          );
        },
      ),
    );
  }
}
