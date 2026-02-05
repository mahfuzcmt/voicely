import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../../core/theme/app_colors.dart';
import '../../../../core/utils/extensions.dart';
import '../../../../di/providers.dart';
import '../../domain/models/channel_model.dart';
import '../widgets/channel_tile.dart';

class ChannelsScreen extends ConsumerWidget {
  const ChannelsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final channelsAsync = ref.watch(userChannelsProvider);
    final userAsync = ref.watch(currentUserStreamProvider);

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
                backgroundImage: user?.photoUrl != null
                    ? NetworkImage(user!.photoUrl!)
                    : null,
                child: user?.photoUrl == null
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
              Text('Error loading channels'),
              const SizedBox(height: 8),
              Text(error.toString()),
              const SizedBox(height: 16),
              ElevatedButton(
                onPressed: () => ref.invalidate(userChannelsProvider),
                child: const Text('Retry'),
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
