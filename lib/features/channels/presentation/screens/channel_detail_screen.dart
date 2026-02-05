import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/utils/extensions.dart';
import '../../../../di/providers.dart';
import '../../../messaging/presentation/widgets/messages_list.dart';
import '../../../ptt/domain/models/ptt_session_model.dart';
import '../../../ptt/presentation/providers/ptt_providers.dart';
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

        return Scaffold(
          appBar: AppBar(
            title: Text(channel.name),
            actions: [
              IconButton(
                icon: const Icon(Icons.info_outline),
                onPressed: () => _showChannelInfo(context, channel),
              ),
            ],
          ),
          body: Column(
            children: [
              // Active speaker banner
              _buildActiveSpeakerBanner(channel.id),
              // Active speakers area
              Expanded(
                child: _buildActiveSpeakersArea(context, membersAsync),
              ),
              // Messages area
              Expanded(
                child: _buildMessagesArea(context, channel.id),
              ),
              // PTT button area
              _buildPttArea(context, channel),
            ],
          ),
        );
      },
    );
  }

  Widget _buildActiveSpeakerBanner(String channelId) {
    final speaker = ref.watch(currentSpeakerProvider(channelId));
    final isCurrentUser = ref.watch(isCurrentUserSpeakingProvider(channelId));

    if (speaker == null) {
      return const SizedBox.shrink();
    }

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: isCurrentUser ? AppColors.pttActive : AppColors.pttReceiving,
        boxShadow: [
          BoxShadow(
            color: (isCurrentUser ? AppColors.pttActive : AppColors.pttReceiving)
                .withValues(alpha: 0.3),
            blurRadius: 8,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Row(
        children: [
          Icon(
            isCurrentUser ? Icons.mic : Icons.volume_up,
            color: Colors.white,
            size: 20,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              isCurrentUser
                  ? 'You are speaking'
                  : '${speaker.name} is speaking',
              style: const TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.w600,
                fontSize: 14,
              ),
            ),
          ),
          if (!isCurrentUser)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.2),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _buildSpeakingIndicator(),
                  const SizedBox(width: 6),
                  const Text(
                    'LIVE',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 10,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildSpeakingIndicator() {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: List.generate(3, (index) {
        return TweenAnimationBuilder<double>(
          tween: Tween(begin: 4, end: 10),
          duration: Duration(milliseconds: 300 + (index * 100)),
          builder: (context, value, child) {
            return Container(
              width: 3,
              height: value,
              margin: const EdgeInsets.symmetric(horizontal: 1),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(2),
              ),
            );
          },
        );
      }),
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

  Widget _buildMessagesArea(BuildContext context, String channelId) {
    return Container(
      decoration: BoxDecoration(
        color: AppColors.cardDark,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
      ),
      child: MessagesList(channelId: channelId),
    );
  }

  Widget _buildPttArea(BuildContext context, ChannelModel channel) {
    final session = ref.watch(pttSessionProvider(channel.id));
    final statusText = switch (session.state) {
      PttSessionState.idle => 'Hold to talk (long-press to reset)',
      PttSessionState.requestingFloor => 'Requesting floor...',
      PttSessionState.transmitting => 'Release to stop',
      PttSessionState.receiving => 'Listening...',
      PttSessionState.error => session.errorMessage ?? 'Error occurred',
    };

    return Container(
      padding: const EdgeInsets.all(24),
      color: AppColors.surfaceDark,
      child: Column(
        children: [
          // PTT button
          PttButton(
            channelId: channel.id,
          ),
          const SizedBox(height: 12),
          Text(
            statusText,
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: AppColors.textSecondaryDark,
                ),
            textAlign: TextAlign.center,
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

}
