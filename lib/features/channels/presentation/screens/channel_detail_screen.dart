import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../../core/theme/app_colors.dart';
import '../../../../core/utils/extensions.dart';
import '../../../../di/providers.dart';
import '../../../ptt/presentation/widgets/ptt_button.dart';
import '../../domain/models/channel_model.dart';

class ChannelDetailScreen extends ConsumerStatefulWidget {
  final String channelId;

  const ChannelDetailScreen({
    super.key,
    required this.channelId,
  });

  @override
  ConsumerState<ChannelDetailScreen> createState() =>
      _ChannelDetailScreenState();
}

class _ChannelDetailScreenState extends ConsumerState<ChannelDetailScreen> {
  @override
  Widget build(BuildContext context) {
    final channelAsync = ref.watch(channelProvider(widget.channelId));
    final membersAsync = ref.watch(channelMembersProvider(widget.channelId));
    final currentUser = ref.watch(authStateProvider).value;

    return channelAsync.when(
      loading: () => const Scaffold(
        body: Center(child: CircularProgressIndicator()),
      ),
      error: (error, _) => Scaffold(
        appBar: AppBar(),
        body: Center(child: Text('Error: $error')),
      ),
      data: (channel) {
        if (channel == null) {
          return Scaffold(
            appBar: AppBar(),
            body: const Center(child: Text('Channel not found')),
          );
        }

        final isOwner = channel.ownerId == currentUser?.uid;

        return Scaffold(
          appBar: AppBar(
            title: Text(channel.name),
            actions: [
              IconButton(
                icon: const Icon(Icons.info_outline),
                onPressed: () => _showChannelInfo(context, channel),
              ),
              if (isOwner)
                PopupMenuButton<String>(
                  onSelected: (value) => _handleMenuAction(value, channel),
                  itemBuilder: (context) => [
                    const PopupMenuItem(
                      value: 'edit',
                      child: ListTile(
                        leading: Icon(Icons.edit),
                        title: Text('Edit Channel'),
                        contentPadding: EdgeInsets.zero,
                      ),
                    ),
                    const PopupMenuItem(
                      value: 'delete',
                      child: ListTile(
                        leading: Icon(Icons.delete, color: AppColors.error),
                        title:
                            Text('Delete', style: TextStyle(color: AppColors.error)),
                        contentPadding: EdgeInsets.zero,
                      ),
                    ),
                  ],
                )
              else
                PopupMenuButton<String>(
                  onSelected: (value) => _handleMenuAction(value, channel),
                  itemBuilder: (context) => [
                    const PopupMenuItem(
                      value: 'leave',
                      child: ListTile(
                        leading: Icon(Icons.exit_to_app, color: AppColors.error),
                        title:
                            Text('Leave', style: TextStyle(color: AppColors.error)),
                        contentPadding: EdgeInsets.zero,
                      ),
                    ),
                  ],
                ),
            ],
          ),
          body: Column(
            children: [
              // Active speakers area
              Expanded(
                child: _buildActiveSpeakersArea(context, membersAsync),
              ),
              // Messages area (placeholder)
              Expanded(
                child: _buildMessagesArea(context),
              ),
              // PTT button area
              _buildPttArea(context, channel),
            ],
          ),
        );
      },
    );
  }

  Widget _buildActiveSpeakersArea(
      BuildContext context, AsyncValue<List<ChannelMember>> membersAsync) {
    return Container(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Active Now',
            style: Theme.of(context).textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.bold,
                ),
          ),
          const SizedBox(height: 12),
          membersAsync.when(
            loading: () => const Center(child: CircularProgressIndicator()),
            error: (_, __) => const Text('Error loading members'),
            data: (members) {
              if (members.isEmpty) {
                return const Text(
                  'No active members',
                  style: TextStyle(color: AppColors.textSecondaryDark),
                );
              }
              return SizedBox(
                height: 80,
                child: ListView.builder(
                  scrollDirection: Axis.horizontal,
                  itemCount: members.length,
                  itemBuilder: (context, index) {
                    final member = members[index];
                    return Padding(
                      padding: const EdgeInsets.only(right: 16),
                      child: Column(
                        children: [
                          Stack(
                            children: [
                              CircleAvatar(
                                radius: 25,
                                backgroundColor: AppColors.cardDark,
                                child: Text(
                                  member.userId[0].toUpperCase(),
                                  style: const TextStyle(
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                              ),
                              Positioned(
                                right: 0,
                                bottom: 0,
                                child: Container(
                                  width: 12,
                                  height: 12,
                                  decoration: BoxDecoration(
                                    color: AppColors.online,
                                    shape: BoxShape.circle,
                                    border: Border.all(
                                      color: AppColors.backgroundDark,
                                      width: 2,
                                    ),
                                  ),
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 4),
                          Text(
                            member.role.name.capitalize,
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                        ],
                      ),
                    );
                  },
                ),
              );
            },
          ),
        ],
      ),
    );
  }

  Widget _buildMessagesArea(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.cardDark,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                'Messages',
                style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
              ),
              TextButton.icon(
                onPressed: () {
                  // TODO: Navigate to full chat
                  context.showSnackBar('Full chat coming soon');
                },
                icon: const Icon(Icons.chat_bubble_outline, size: 18),
                label: const Text('View All'),
              ),
            ],
          ),
          const Expanded(
            child: Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(
                    Icons.chat_bubble_outline,
                    size: 48,
                    color: AppColors.textSecondaryDark,
                  ),
                  SizedBox(height: 12),
                  Text(
                    'No messages yet',
                    style: TextStyle(color: AppColors.textSecondaryDark),
                  ),
                  SizedBox(height: 4),
                  Text(
                    'Start a conversation or use PTT',
                    style: TextStyle(
                      color: AppColors.textSecondaryDark,
                      fontSize: 12,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPttArea(BuildContext context, ChannelModel channel) {
    return Container(
      padding: const EdgeInsets.all(24),
      color: AppColors.surfaceDark,
      child: Column(
        children: [
          // PTT button
          PttButton(
            channelId: channel.id,
            onPttStart: () {
              // TODO: Start PTT transmission
            },
            onPttEnd: () {
              // TODO: End PTT transmission
            },
          ),
          const SizedBox(height: 12),
          Text(
            'Hold to talk',
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: AppColors.textSecondaryDark,
                ),
          ),
        ],
      ),
    );
  }

  void _showChannelInfo(BuildContext context, ChannelModel channel) {
    showModalBottomSheet(
      context: context,
      backgroundColor: AppColors.surfaceDark,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (context) => Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
              child: Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: AppColors.textSecondaryDark,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            const SizedBox(height: 24),
            Text(
              channel.name,
              style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
            ),
            if (channel.description != null) ...[
              const SizedBox(height: 8),
              Text(
                channel.description!,
                style: const TextStyle(color: AppColors.textSecondaryDark),
              ),
            ],
            const SizedBox(height: 16),
            Row(
              children: [
                const Icon(Icons.people_outline, size: 20),
                const SizedBox(width: 8),
                Text('${channel.memberCount} members'),
              ],
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Icon(
                  channel.isPrivate ? Icons.lock_outline : Icons.public,
                  size: 20,
                ),
                const SizedBox(width: 8),
                Text(channel.isPrivate ? 'Private channel' : 'Public channel'),
              ],
            ),
            if (channel.createdAt != null) ...[
              const SizedBox(height: 8),
              Row(
                children: [
                  const Icon(Icons.calendar_today_outlined, size: 20),
                  const SizedBox(width: 8),
                  Text('Created ${channel.createdAt!.formattedDate}'),
                ],
              ),
            ],
            const SizedBox(height: 24),
          ],
        ),
      ),
    );
  }

  void _handleMenuAction(String action, ChannelModel channel) {
    switch (action) {
      case 'edit':
        // TODO: Navigate to edit screen
        context.showSnackBar('Edit channel coming soon');
        break;
      case 'delete':
        _showDeleteDialog(channel);
        break;
      case 'leave':
        _showLeaveDialog(channel);
        break;
    }
  }

  void _showDeleteDialog(ChannelModel channel) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete Channel'),
        content: Text(
          'Are you sure you want to delete "${channel.name}"? This action cannot be undone.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () async {
              Navigator.pop(context);
              await ref
                  .read(channelNotifierProvider.notifier)
                  .deleteChannel(channel.id);
              if (mounted) {
                context.go('/channels');
              }
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: AppColors.error,
            ),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
  }

  void _showLeaveDialog(ChannelModel channel) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Leave Channel'),
        content: Text('Are you sure you want to leave "${channel.name}"?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () async {
              Navigator.pop(context);
              await ref
                  .read(channelNotifierProvider.notifier)
                  .leaveChannel(channel.id);
              if (mounted) {
                context.go('/channels');
              }
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: AppColors.error,
            ),
            child: const Text('Leave'),
          ),
        ],
      ),
    );
  }
}
