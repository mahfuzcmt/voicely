import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:just_audio/just_audio.dart';
import 'package:intl/intl.dart';
import '../../../../core/constants/app_constants.dart';
import '../../../../core/services/background_audio_service.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/utils/extensions.dart';
import '../../../../di/providers.dart';
import '../../../auth/presentation/screens/profile_screen.dart';
import '../../../messaging/data/message_repository.dart';
import '../../../messaging/domain/models/message_model.dart';
import '../../../ptt/presentation/providers/live_ptt_providers.dart';
import '../../../ptt/presentation/providers/ptt_providers.dart';
import '../../../ptt/presentation/widgets/live_ptt_button.dart';
import '../../../ptt/presentation/widgets/ptt_button.dart';
import '../../domain/models/channel_model.dart';

// Provider for messages stream
final channelMessagesProvider = StreamProvider.family<List<MessageModel>, String>((ref, channelId) {
  final messageRepo = ref.watch(messageRepositoryProvider);
  return messageRepo.getChannelMessages(channelId);
});

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
  AudioPlayer? _audioPlayer;
  String? _currentlyPlayingId;
  String? _lastAutoPlayedMessageId;
  StreamSubscription? _messageSubscription;
  final BackgroundAudioService _backgroundService = BackgroundAudioService();
  String? _channelName;

  @override
  void initState() {
    super.initState();
    _audioPlayer = AudioPlayer();
    _backgroundService.initialize();
    _setupAutoPlayListener();
  }

  @override
  void dispose() {
    _messageSubscription?.cancel();
    _audioPlayer?.dispose();
    super.dispose();
  }

  void _setupAutoPlayListener() {
    final currentUser = ref.read(authStateProvider).value;
    if (currentUser == null) return;

    final messageRepo = ref.read(messageRepositoryProvider);
    _messageSubscription = messageRepo.getChannelMessages(widget.channelId).listen((messages) {
      if (messages.isEmpty) return;

      final latestMessage = messages.first;

      // Skip if it's our own message or already auto-played
      if (latestMessage.senderId == currentUser.uid ||
          latestMessage.id == _lastAutoPlayedMessageId) {
        return;
      }

      // Check if auto-play is enabled
      final autoPlayEnabled = ref.read(autoPlayEnabledProvider);
      debugPrint('Auto-play check: enabled=$autoPlayEnabled, audioUrl=${latestMessage.audioUrl}, type=${latestMessage.type}');

      if (autoPlayEnabled &&
          latestMessage.audioUrl != null &&
          latestMessage.type == MessageType.audio) {
        debugPrint('Auto-playing message: ${latestMessage.id}');
        _lastAutoPlayedMessageId = latestMessage.id;
        // Use background service for auto-play (works when screen is locked)
        _backgroundService.playAudio(
          audioUrl: latestMessage.audioUrl!,
          senderName: latestMessage.senderName,
          channelName: _channelName ?? 'Channel',
        );
        if (mounted) {
          setState(() => _currentlyPlayingId = latestMessage.id);
        }
      }
    });
  }

  Future<void> _playAudio(MessageModel message) async {
    if (message.audioUrl == null) return;

    // If already playing this message, stop it
    if (_currentlyPlayingId == message.id) {
      await _audioPlayer?.stop();
      setState(() => _currentlyPlayingId = null);
      return;
    }

    try {
      setState(() => _currentlyPlayingId = message.id);

      await _audioPlayer?.stop();
      await _audioPlayer?.setUrl(message.audioUrl!);
      await _audioPlayer?.play();

      // Wait for playback to complete
      _audioPlayer?.playerStateStream.listen((state) {
        if (state.processingState == ProcessingState.completed) {
          if (mounted) {
            setState(() => _currentlyPlayingId = null);
          }
        }
      });
    } catch (e) {
      debugPrint('Error playing audio: $e');
      if (mounted) {
        setState(() => _currentlyPlayingId = null);
        context.showSnackBar('Failed to play audio', isError: true);
      }
    }
  }

  void _showMessageHistory() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) => _MessageHistorySheet(
        channelId: widget.channelId,
        channelName: _channelName ?? 'Channel',
        onPlayMessage: _playAudio,
        currentlyPlayingId: _currentlyPlayingId,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final channelAsync = ref.watch(channelProvider(widget.channelId));
    final autoPlayEnabled = ref.watch(autoPlayEnabledProvider);

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

        // Save channel name for notifications
        _channelName = channel.name;

        return Scaffold(
          backgroundColor: Colors.white,
          body: SafeArea(
            child: Column(
              children: [
                // Top bar with back, title, and archive button
                _buildTopBar(channel, autoPlayEnabled),

                // User/Channel info section
                _buildChannelInfo(channel),

                // Action buttons (camera, emergency, mute)
                _buildActionButtons(channel),

                // Main PTT area - takes most of the space
                Expanded(
                  child: _buildFullPagePttArea(channel),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildTopBar(ChannelModel channel, bool autoPlayEnabled) {
    final session = AppConstants.useLiveStreaming
        ? ref.watch(livePttSessionProvider(channel.id))
        : null;

    final isActive = session?.isBroadcasting == true || session?.isListening == true;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
      child: Row(
        children: [
          // Back button
          IconButton(
            icon: const Icon(Icons.arrow_back_ios, color: AppColors.primary),
            onPressed: () => Navigator.pop(context),
          ),
          const Spacer(),
          // Timer when broadcasting or speaker name when listening
          if (isActive && session != null)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              decoration: BoxDecoration(
                color: session.isBroadcasting
                    ? (session.isBroadcastTimeWarning
                        ? Colors.red.withValues(alpha: 0.1)
                        : Colors.orange.withValues(alpha: 0.1))
                    : Colors.green.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(20),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 10,
                    height: 10,
                    decoration: BoxDecoration(
                      color: session.isBroadcasting
                          ? (session.isBroadcastTimeWarning ? Colors.red : Colors.orange)
                          : Colors.green,
                      shape: BoxShape.circle,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    session.isBroadcasting
                        ? 'LIVE ${_formatDuration(session.broadcastDuration)} (${session.remainingBroadcastSeconds}s)'
                        : (session.currentSpeakerName?.isNotEmpty == true)
                            ? session.currentSpeakerName!
                            : 'Listening...',
                    style: TextStyle(
                      color: session.isBroadcasting
                          ? (session.isBroadcastTimeWarning ? Colors.red : Colors.orange)
                          : Colors.green,
                      fontWeight: FontWeight.bold,
                      fontSize: 16,
                    ),
                  ),
                ],
              ),
            ),
          const Spacer(),
          // Archive/Message history button
          IconButton(
            icon: Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: AppColors.primary,
                shape: BoxShape.circle,
              ),
              child: const Icon(
                Icons.chat_bubble,
                color: Colors.white,
                size: 20,
              ),
            ),
            onPressed: _showMessageHistory,
          ),
        ],
      ),
    );
  }

  Widget _buildChannelInfo(ChannelModel channel) {
    final session = AppConstants.useLiveStreaming
        ? ref.watch(livePttSessionProvider(channel.id))
        : null;

    // Watch online members count - exclude current user
    final currentUser = ref.watch(authStateProvider).value;
    final membersAsync = AppConstants.useLiveStreaming
        ? ref.watch(liveRoomMembersProvider(channel.id))
        : null;
    final members = membersAsync?.valueOrNull ?? [];
    // Filter out current user from online count
    final onlineCount = members.where((m) => m.userId != currentUser?.uid).length;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 8),
      child: Row(
        children: [
          // Channel avatar
          Stack(
            children: [
              CircleAvatar(
                radius: 28,
                backgroundColor: AppColors.surfaceDark,
                child: Text(
                  channel.name.isNotEmpty ? channel.name[0].toUpperCase() : 'C',
                  style: const TextStyle(
                    fontSize: 24,
                    fontWeight: FontWeight.bold,
                    color: Colors.white,
                  ),
                ),
              ),
              // Online indicator
              if (session?.isConnected ?? false)
                Positioned(
                  bottom: 2,
                  left: 2,
                  child: Container(
                    width: 14,
                    height: 14,
                    decoration: BoxDecoration(
                      color: Colors.green,
                      shape: BoxShape.circle,
                      border: Border.all(color: Colors.white, width: 2),
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(width: 12),
          // Channel name and status
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  channel.name,
                  style: const TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                    color: Colors.black87,
                  ),
                ),
                Row(
                  children: [
                    // Connection status dot
                    Container(
                      width: 8,
                      height: 8,
                      decoration: BoxDecoration(
                        color: (session?.isConnected ?? false)
                            ? Colors.green
                            : (session?.isConnecting ?? false)
                                ? Colors.yellow[700]
                                : Colors.grey,
                        shape: BoxShape.circle,
                      ),
                    ),
                    const SizedBox(width: 4),
                    // Show user count or connection status
                    Text(
                      (session?.isConnected ?? false)
                          ? (onlineCount > 0 ? '$onlineCount online' : 'Available')
                          : (session?.isConnecting ?? false)
                              ? 'Connecting...'
                              : 'Disconnected',
                      style: TextStyle(
                        fontSize: 14,
                        color: (session?.isConnected ?? false)
                            ? Colors.green
                            : (session?.isConnecting ?? false)
                                ? Colors.yellow[700]
                                : Colors.grey,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          // More options
          IconButton(
            icon: const Icon(Icons.more_horiz, color: Colors.grey),
            onPressed: () {
              // Show channel options
            },
          ),
        ],
      ),
    );
  }

  Widget _buildActionButtons(ChannelModel channel) {
    final session = AppConstants.useLiveStreaming
        ? ref.watch(livePttSessionProvider(channel.id))
        : null;
    final isMuted = session?.isMuted ?? false;

    // Get online users count (excluding current user)
    final currentUser = ref.watch(authStateProvider).value;
    final membersAsync = AppConstants.useLiveStreaming
        ? ref.watch(liveRoomMembersProvider(channel.id))
        : null;
    final members = membersAsync?.valueOrNull ?? [];
    final onlineCount = members.where((m) => m.userId != currentUser?.uid).length;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: [
          // Mute button for live audio
          _ActionButton(
            icon: isMuted ? Icons.volume_off : Icons.volume_up,
            color: isMuted ? Colors.red : AppColors.primary,
            onTap: () {
              ref.read(livePttSessionProvider(channel.id).notifier).toggleMute();
              context.showSnackBar(
                isMuted ? 'Audio unmuted' : 'Audio muted',
              );
            },
          ),
          // Online users count in the middle
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            decoration: BoxDecoration(
              color: Colors.green.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(20),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.people, color: Colors.green, size: 18),
                const SizedBox(width: 6),
                Text(
                  '$onlineCount online',
                  style: const TextStyle(
                    color: Colors.green,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
          // Emergency button
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            decoration: BoxDecoration(
              color: Colors.red.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(20),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.warning, color: Colors.red, size: 18),
                const SizedBox(width: 6),
                const Text(
                  'Emergency',
                  style: TextStyle(
                    color: Colors.red,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(width: 4),
                Container(
                  padding: const EdgeInsets.all(2),
                  decoration: BoxDecoration(
                    color: Colors.orange,
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(Icons.lock, color: Colors.white, size: 12),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildFullPagePttArea(ChannelModel channel) {
    if (AppConstants.useLiveStreaming) {
      return _buildLiveFullPagePtt(channel);
    }
    return _buildLegacyFullPagePtt(channel);
  }

  Widget _buildLiveFullPagePtt(ChannelModel channel) {
    return Center(
      child: LivePttButton(
        channelId: channel.id,
        size: 320,
      ),
    );
  }

  String _formatDuration(Duration duration) {
    final minutes = duration.inMinutes;
    final seconds = duration.inSeconds % 60;
    return '${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}';
  }

  Widget _buildLegacyFullPagePtt(ChannelModel channel) {
    return Center(
      child: PttButton(
        channelId: channel.id,
        size: 320,
      ),
    );
  }

  String _getLiveStatusText(LivePttSessionState session) {
    switch (session.state) {
      case LivePttState.idle:
        return 'Hold to talk';
      case LivePttState.connecting:
        return 'Connecting...';
      case LivePttState.requestingFloor:
        return 'Requesting...';
      case LivePttState.broadcasting:
        return 'Broadcasting live';
      case LivePttState.listening:
        return 'Listening...';
      case LivePttState.error:
        return session.errorMessage ?? 'Error';
      case LivePttState.disconnected:
        return 'Tap to reconnect';
    }
  }

  String _getLegacyStatusText(PttSessionState session) {
    switch (session.state) {
      case PttState.idle:
        return 'Hold to record';
      case PttState.recording:
        return 'Recording...';
      case PttState.uploading:
        return 'Sending...';
      case PttState.error:
        return session.errorMessage ?? 'Error';
    }
  }

  Color _getLiveStatusColor(LivePttState state) {
    switch (state) {
      case LivePttState.idle:
        return Colors.grey;
      case LivePttState.connecting:
      case LivePttState.requestingFloor:
        return Colors.orange;
      case LivePttState.broadcasting:
        return Colors.red;
      case LivePttState.listening:
        return Colors.green;
      case LivePttState.error:
      case LivePttState.disconnected:
        return AppColors.error;
    }
  }
}

// Action button widget
class _ActionButton extends StatelessWidget {
  final IconData icon;
  final Color color;
  final VoidCallback onTap;

  const _ActionButton({
    required this.icon,
    required this.color,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.1),
          shape: BoxShape.circle,
        ),
        child: Icon(icon, color: color, size: 24),
      ),
    );
  }
}

// Message history bottom sheet
class _MessageHistorySheet extends ConsumerWidget {
  final String channelId;
  final String channelName;
  final Function(MessageModel) onPlayMessage;
  final String? currentlyPlayingId;

  const _MessageHistorySheet({
    required this.channelId,
    required this.channelName,
    required this.onPlayMessage,
    this.currentlyPlayingId,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final messagesAsync = ref.watch(channelMessagesProvider(channelId));
    final currentUser = ref.read(authStateProvider).value;

    return DraggableScrollableSheet(
      initialChildSize: 0.9,
      minChildSize: 0.5,
      maxChildSize: 0.95,
      builder: (context, scrollController) {
        return Container(
          decoration: const BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
          ),
          child: Column(
            children: [
              // Handle bar
              Container(
                margin: const EdgeInsets.only(top: 12),
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: Colors.grey[300],
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              // Header
              Padding(
                padding: const EdgeInsets.all(16),
                child: Row(
                  children: [
                    IconButton(
                      icon: const Icon(Icons.close),
                      onPressed: () => Navigator.pop(context),
                    ),
                    // Channel avatar
                    CircleAvatar(
                      radius: 18,
                      backgroundColor: AppColors.surfaceDark,
                      child: Text(
                        channelName.isNotEmpty ? channelName[0].toUpperCase() : 'C',
                        style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          channelName,
                          style: const TextStyle(
                            fontWeight: FontWeight.bold,
                            fontSize: 16,
                          ),
                        ),
                        const Text(
                          'Available',
                          style: TextStyle(
                            color: Colors.green,
                            fontSize: 12,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              const Divider(height: 1),
              // Messages list
              Expanded(
                child: messagesAsync.when(
                  loading: () => const Center(child: CircularProgressIndicator()),
                  error: (error, _) => Center(
                    child: Text('Error: $error'),
                  ),
                  data: (messages) {
                    if (messages.isEmpty) {
                      return const Center(
                        child: Text(
                          'No messages yet',
                          style: TextStyle(color: Colors.grey),
                        ),
                      );
                    }
                    return ListView.builder(
                      controller: scrollController,
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                      itemCount: messages.length,
                      itemBuilder: (context, index) {
                        final message = messages[index];
                        final isMe = message.senderId == currentUser?.uid;
                        final isPlaying = currentlyPlayingId == message.id;

                        return _buildMessageBubble(context, message, isMe, isPlaying);
                      },
                    );
                  },
                ),
              ),
              // Playback controls
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                decoration: BoxDecoration(
                  border: Border(top: BorderSide(color: Colors.grey[200]!)),
                ),
                child: Row(
                  children: [
                    IconButton(
                      icon: const Icon(Icons.skip_previous),
                      color: Colors.grey,
                      onPressed: () {},
                    ),
                    IconButton(
                      icon: const Icon(Icons.play_arrow),
                      color: Colors.grey,
                      onPressed: () {},
                    ),
                    IconButton(
                      icon: const Icon(Icons.skip_next),
                      color: Colors.grey,
                      onPressed: () {},
                    ),
                    const Spacer(),
                    const Text('1x', style: TextStyle(color: Colors.grey)),
                  ],
                ),
              ),
              // Input area
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  border: Border(top: BorderSide(color: Colors.grey[200]!)),
                ),
                child: Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                        color: Colors.grey[100],
                        shape: BoxShape.circle,
                      ),
                      child: const Icon(Icons.add, color: Colors.grey),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                        decoration: BoxDecoration(
                          color: Colors.grey[100],
                          borderRadius: BorderRadius.circular(24),
                        ),
                        child: const Text(
                          'Message',
                          style: TextStyle(color: Colors.grey),
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: Colors.orange.withValues(alpha: 0.1),
                        shape: BoxShape.circle,
                        border: Border.all(color: Colors.orange, width: 2),
                      ),
                      child: const Icon(Icons.mic, color: Colors.orange),
                    ),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildMessageBubble(BuildContext context, MessageModel message, bool isMe, bool isPlaying) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Column(
        crossAxisAlignment: isMe ? CrossAxisAlignment.end : CrossAxisAlignment.start,
        children: [
          // Date separator (simplified)
          if (message == message) // Placeholder for actual date logic
            Container(),

          Row(
            mainAxisAlignment: isMe ? MainAxisAlignment.end : MainAxisAlignment.start,
            children: [
              GestureDetector(
                onTap: () => onPlayMessage(message),
                child: Container(
                  constraints: BoxConstraints(
                    maxWidth: MediaQuery.of(context).size.width * 0.7,
                  ),
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: isMe ? AppColors.primary : Colors.grey[200],
                    borderRadius: BorderRadius.circular(20),
                    border: isPlaying ? Border.all(color: AppColors.primary, width: 2) : null,
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        isPlaying ? Icons.stop : Icons.play_arrow,
                        color: isMe ? Colors.white : Colors.black54,
                        size: 20,
                      ),
                      const SizedBox(width: 8),
                      // Waveform placeholder
                      Flexible(
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: List.generate(15, (i) => Container(
                            width: 2,
                            height: (i % 3 + 1) * 4.0 + 4,
                            margin: const EdgeInsets.symmetric(horizontal: 1),
                            decoration: BoxDecoration(
                              color: isMe ? Colors.white.withValues(alpha: 0.7) : Colors.black38,
                              borderRadius: BorderRadius.circular(1),
                            ),
                          )),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Text(
                        '${(message.audioDuration ?? 0) ~/ 60}:${((message.audioDuration ?? 0) % 60).toString().padLeft(2, '0')}',
                        style: TextStyle(
                          color: isMe ? Colors.white : Colors.black87,
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
          // Time
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              _formatTime(message.timestamp),
              style: TextStyle(
                fontSize: 11,
                color: Colors.grey[500],
              ),
            ),
          ),
        ],
      ),
    );
  }

  String _formatTime(DateTime? timestamp) {
    if (timestamp == null) return '';
    return DateFormat('h:mm a').format(timestamp);
  }
}

// Animated speaker icon with sound waves
class _AnimatedSpeakerIcon extends StatefulWidget {
  final bool isActive;
  final Color color;

  const _AnimatedSpeakerIcon({
    required this.isActive,
    required this.color,
  });

  @override
  State<_AnimatedSpeakerIcon> createState() => _AnimatedSpeakerIconState();
}

class _AnimatedSpeakerIconState extends State<_AnimatedSpeakerIcon>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<double> _animation;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 800),
    );
    _animation = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(parent: _controller, curve: Curves.easeInOut),
    );

    if (widget.isActive) {
      _controller.repeat(reverse: true);
    }
  }

  @override
  void didUpdateWidget(_AnimatedSpeakerIcon oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.isActive && !_controller.isAnimating) {
      _controller.repeat(reverse: true);
    } else if (!widget.isActive && _controller.isAnimating) {
      _controller.stop();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _animation,
      builder: (context, child) {
        return SizedBox(
          width: 32,
          height: 32,
          child: Stack(
            alignment: Alignment.center,
            children: [
              Icon(Icons.volume_up, color: widget.color, size: 24),
              // Sound wave indicators
              if (widget.isActive) ...[
                Positioned(
                  right: 0,
                  child: Transform.scale(
                    scale: 0.8 + (_animation.value * 0.2),
                    child: Opacity(
                      opacity: 1.0 - (_animation.value * 0.5),
                      child: Container(
                        width: 4,
                        height: 12,
                        decoration: BoxDecoration(
                          color: widget.color,
                          borderRadius: BorderRadius.circular(2),
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ],
          ),
        );
      },
    );
  }
}
