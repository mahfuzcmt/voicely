import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:just_audio/just_audio.dart';
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

class _ChannelDetailScreenState extends ConsumerState<ChannelDetailScreen>
    with WidgetsBindingObserver {
  AudioPlayer? _audioPlayer;
  String? _currentlyPlayingId;
  String? _lastAutoPlayedMessageId;
  DateTime? _lastAutoPlayedTimestamp; // Track timestamp to handle message ordering
  StreamSubscription? _messageSubscription;
  StreamSubscription? _playerStateSubscription;
  final BackgroundAudioService _backgroundService = BackgroundAudioService();
  String? _channelName;
  bool _isPlayingArchivedMessage = false;
  bool _autoPlayListenerSetup = false; // Guard against duplicate setup

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _audioPlayer = AudioPlayer();
    _backgroundService.initialize();
    _setupAutoPlayListener();
    _setupPlayerStateListener();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _messageSubscription?.cancel();
    _messageSubscription = null;
    _playerStateSubscription?.cancel();
    _playerStateSubscription = null;
    _audioPlayer?.dispose();
    _audioPlayer = null;
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      debugPrint('ChannelDetail: App resumed, refreshing messages');
      // Invalidate the messages provider to force a fresh fetch
      ref.invalidate(channelMessagesProvider(widget.channelId));
      // Reset auto-play listener to pick up new messages
      _autoPlayListenerSetup = false;
      _setupAutoPlayListener();
    }
  }

  void _setupPlayerStateListener() {
    _playerStateSubscription = _audioPlayer?.playerStateStream.listen((state) {
      if (state.processingState == ProcessingState.completed) {
        if (mounted) {
          setState(() {
            _currentlyPlayingId = null;
            _isPlayingArchivedMessage = false;
          });
        }
      }
    });
  }

  void _setupAutoPlayListener() {
    // Always cancel any existing subscription first to prevent leaks
    _messageSubscription?.cancel();
    _messageSubscription = null;

    // Guard against duplicate subscription within same lifecycle
    if (_autoPlayListenerSetup) {
      debugPrint('Auto-play listener already set up, skipping');
      return;
    }
    _autoPlayListenerSetup = true;

    final currentUser = ref.read(authStateProvider).value;
    if (currentUser == null) return;

    final messageRepo = ref.read(messageRepositoryProvider);
    _messageSubscription = messageRepo.getChannelMessages(widget.channelId).listen((messages) {
      if (messages.isEmpty) return;

      // Find the actual latest message by timestamp (don't assume ordering)
      MessageModel? latestMessage;
      for (final msg in messages) {
        final msgTimestamp = msg.timestamp;
        if (msgTimestamp == null) continue;
        final latestTimestamp = latestMessage?.timestamp;
        if (latestMessage == null || latestTimestamp == null || msgTimestamp.isAfter(latestTimestamp)) {
          latestMessage = msg;
        }
      }
      if (latestMessage == null || latestMessage.timestamp == null) return;

      // Skip if it's our own message or already auto-played (by ID or timestamp)
      if (latestMessage.senderId == currentUser.uid ||
          latestMessage.id == _lastAutoPlayedMessageId) {
        return;
      }

      // Skip if this message is older than or equal to the last auto-played
      if (_lastAutoPlayedTimestamp != null &&
          !latestMessage.timestamp!.isAfter(_lastAutoPlayedTimestamp!)) {
        return;
      }

      // Skip if currently in a live broadcast (listening or broadcasting)
      final session = ref.read(livePttSessionProvider(widget.channelId));
      if (session.isListening || session.isBroadcasting) {
        debugPrint('Auto-play skipped: currently in live broadcast');
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
        _lastAutoPlayedTimestamp = latestMessage.timestamp;
        // Use background service for auto-play (works when screen is locked)
        _backgroundService.playAudio(
          audioUrl: latestMessage.audioUrl!,
          senderName: latestMessage.senderName,
          channelName: _channelName ?? 'Channel',
        );
        if (mounted) {
          setState(() => _currentlyPlayingId = latestMessage!.id);
        }
      }
    });
  }

  Future<void> _playAudio(MessageModel message, {bool isArchived = false}) async {
    if (message.audioUrl == null) return;

    // If already playing this message, stop it
    if (_currentlyPlayingId == message.id) {
      await _audioPlayer?.stop();
      setState(() {
        _currentlyPlayingId = null;
        _isPlayingArchivedMessage = false;
      });
      return;
    }

    try {
      setState(() {
        _currentlyPlayingId = message.id;
        _isPlayingArchivedMessage = isArchived;
      });

      await _audioPlayer?.stop();
      await _audioPlayer?.setUrl(message.audioUrl!);
      await _audioPlayer?.play();
    } catch (e) {
      debugPrint('Error playing audio: $e');
      if (mounted) {
        setState(() {
          _currentlyPlayingId = null;
          _isPlayingArchivedMessage = false;
        });
        context.showSnackBar('Failed to play audio', isError: true);
      }
    }
  }

  /// Stop ALL audio playback when live broadcast starts
  /// This includes both the replay audio player and the background service auto-play
  Future<void> _stopAllAudioPlayback() async {
    debugPrint('Stopping all audio playback for incoming broadcast');

    // Stop the replay audio player
    if (_audioPlayer?.playing == true) {
      await _audioPlayer?.stop();
    }

    // Stop the background service audio (auto-play)
    if (_backgroundService.isPlaying) {
      await _backgroundService.stop();
    }

    // Reset state
    if (mounted) {
      setState(() {
        _currentlyPlayingId = null;
        _isPlayingArchivedMessage = false;
      });
    }
  }

  /// Play the last recorded message
  Future<void> _playLastMessage() async {
    final messageRepo = ref.read(messageRepositoryProvider);

    try {
      // Get the last audio message from the channel
      final messages = await messageRepo.getChannelMessages(widget.channelId).first;

      if (messages.isEmpty) {
        if (mounted) {
          context.showSnackBar('No messages to replay');
        }
        return;
      }

      // Find the last audio message
      final lastAudioMessage = messages.firstWhere(
        (m) => m.type == MessageType.audio && m.audioUrl != null,
        orElse: () => messages.first,
      );

      if (lastAudioMessage.audioUrl == null) {
        if (mounted) {
          context.showSnackBar('No audio messages to replay');
        }
        return;
      }

      // Check if currently in a live broadcast - don't play if listening
      final session = ref.read(livePttSessionProvider(widget.channelId));
      if (session.isListening) {
        if (mounted) {
          context.showSnackBar('Cannot replay during live broadcast');
        }
        return;
      }

      await _playAudio(lastAudioMessage, isArchived: true);
    } catch (e) {
      debugPrint('Error getting last message: $e');
      if (mounted) {
        context.showSnackBar('Failed to get last message', isError: true);
      }
    }
  }

  /// Show bottom sheet with online users list
  void _showOnlineUsersSheet(String channelId) {
    final currentUser = ref.read(authStateProvider).value;
    final membersAsync = ref.read(liveRoomMembersProvider(channelId));
    final members = membersAsync.valueOrNull ?? [];

    // Filter out current user
    final onlineMembers = members.where((m) => m.userId != currentUser?.uid).toList();

    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (context) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
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
              // Title
              Padding(
                padding: const EdgeInsets.all(16),
                child: Row(
                  children: [
                    const Icon(Icons.people, color: Colors.green),
                    const SizedBox(width: 8),
                    Text(
                      'Online Users (${onlineMembers.length})',
                      style: const TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ],
                ),
              ),
              const Divider(height: 1),
              // User list
              if (onlineMembers.isEmpty)
                const Padding(
                  padding: EdgeInsets.all(32),
                  child: Text(
                    'No other users online',
                    style: TextStyle(
                      color: Colors.grey,
                      fontSize: 16,
                    ),
                  ),
                )
              else
                ConstrainedBox(
                  constraints: BoxConstraints(
                    maxHeight: MediaQuery.of(context).size.height * 0.4,
                  ),
                  child: ListView.builder(
                    shrinkWrap: true,
                    itemCount: onlineMembers.length,
                    itemBuilder: (context, index) {
                      final member = onlineMembers[index];
                      return ListTile(
                        leading: CircleAvatar(
                          backgroundColor: AppColors.primary,
                          backgroundImage: member.photoUrl?.isNotEmpty == true
                              ? NetworkImage(member.photoUrl!)
                              : null,
                          child: member.photoUrl?.isNotEmpty != true
                              ? Text(
                                  member.displayName.isNotEmpty
                                      ? member.displayName[0].toUpperCase()
                                      : '?',
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontWeight: FontWeight.bold,
                                  ),
                                )
                              : null,
                        ),
                        title: Text(
                          member.displayName,
                          style: const TextStyle(fontWeight: FontWeight.w500),
                        ),
                        trailing: Container(
                          width: 10,
                          height: 10,
                          decoration: const BoxDecoration(
                            color: Colors.green,
                            shape: BoxShape.circle,
                          ),
                        ),
                      );
                    },
                  ),
                ),
              const SizedBox(height: 16),
            ],
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final channelAsync = ref.watch(channelProvider(widget.channelId));
    final autoPlayEnabled = ref.watch(autoPlayEnabledProvider);

    // Listen for incoming broadcast to stop all audio playback
    ref.listen<LivePttSessionState>(
      livePttSessionProvider(widget.channelId),
      (previous, next) {
        // When someone starts broadcasting (we start listening), stop all audio
        if (previous?.isListening != true && next.isListening == true) {
          _stopAllAudioPlayback();
        }
        // Also stop when WE start broadcasting
        if (previous?.isBroadcasting != true && next.isBroadcasting == true) {
          _stopAllAudioPlayback();
        }
      },
    );

    return channelAsync.when(
      loading: () => const Scaffold(
        body: Center(child: CircularProgressIndicator()),
      ),
      error: (error, _) => Scaffold(
        appBar: AppBar(
          leading: IconButton(
            icon: const Icon(Icons.arrow_back),
            onPressed: () => Navigator.of(context).pop(),
          ),
        ),
        body: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.error_outline, size: 48, color: AppColors.error),
              const SizedBox(height: 16),
              const Text(
                'Unable to load channel',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w500),
              ),
              const SizedBox(height: 8),
              const Text(
                'Please check your connection',
                style: TextStyle(color: Colors.grey),
              ),
              const SizedBox(height: 16),
              ElevatedButton.icon(
                onPressed: () => ref.invalidate(channelProvider(widget.channelId)),
                icon: const Icon(Icons.refresh),
                label: const Text('Retry'),
              ),
            ],
          ),
        ),
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
          // Replay last message button
          IconButton(
            icon: Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: _isPlayingArchivedMessage ? Colors.green : AppColors.primary,
                shape: BoxShape.circle,
              ),
              child: Icon(
                _isPlayingArchivedMessage ? Icons.stop : Icons.replay,
                color: Colors.white,
                size: 20,
              ),
            ),
            onPressed: _isPlayingArchivedMessage
                ? () async {
                    await _audioPlayer?.stop();
                    setState(() {
                      _currentlyPlayingId = null;
                      _isPlayingArchivedMessage = false;
                    });
                  }
                : _playLastMessage,
          ),
        ],
      ),
    );
  }

  Widget _buildChannelInfo(ChannelModel channel) {
    final session = AppConstants.useLiveStreaming
        ? ref.watch(livePttSessionProvider(channel.id))
        : null;

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
                    // Show connection status only
                    Text(
                      (session?.isConnected ?? false)
                          ? 'Connected'
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
          // Online users count in the middle - clickable to show user list
          GestureDetector(
            onTap: () => _showOnlineUsersSheet(channel.id),
            child: Container(
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
