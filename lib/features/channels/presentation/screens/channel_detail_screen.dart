import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:just_audio/just_audio.dart';
import 'package:intl/intl.dart';
import '../../../../core/services/background_audio_service.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/utils/extensions.dart';
import '../../../../di/providers.dart';
import '../../../auth/presentation/screens/profile_screen.dart';
import '../../../messaging/data/message_repository.dart';
import '../../../messaging/domain/models/message_model.dart';
import '../../../ptt/presentation/providers/ptt_providers.dart';
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

  @override
  Widget build(BuildContext context) {
    final channelAsync = ref.watch(channelProvider(widget.channelId));
    final messagesAsync = ref.watch(channelMessagesProvider(widget.channelId));
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
          backgroundColor: AppColors.backgroundDark,
          appBar: AppBar(
            title: Text(channel.name),
            centerTitle: true,
            actions: [
              // Auto-play toggle
              IconButton(
                icon: Icon(
                  autoPlayEnabled ? Icons.volume_up : Icons.volume_off,
                  color: autoPlayEnabled ? AppColors.primary : null,
                ),
                tooltip: autoPlayEnabled ? 'Auto-play ON' : 'Auto-play OFF',
                onPressed: () {
                  ref.read(autoPlayEnabledProvider.notifier).state = !autoPlayEnabled;
                  context.showSnackBar(
                    autoPlayEnabled ? 'Auto-play disabled' : 'Auto-play enabled',
                  );
                },
              ),
            ],
          ),
          body: SafeArea(
            child: Column(
              children: [
                // Playing indicator
                if (_currentlyPlayingId != null)
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                    color: AppColors.primary.withValues(alpha: 0.2),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(Icons.volume_up, color: AppColors.primary, size: 20),
                        const SizedBox(width: 8),
                        Text(
                          'Playing voice message...',
                          style: TextStyle(color: AppColors.primary),
                        ),
                        const SizedBox(width: 8),
                        GestureDetector(
                          onTap: () async {
                            await _audioPlayer?.stop();
                            setState(() => _currentlyPlayingId = null);
                          },
                          child: Icon(Icons.stop_circle, color: AppColors.primary, size: 24),
                        ),
                      ],
                    ),
                  ),

                // Message history list
                Expanded(
                  child: messagesAsync.when(
                    loading: () => const Center(child: CircularProgressIndicator()),
                    error: (error, _) {
                      // Check if it's an index building error
                      final errorStr = error.toString();
                      if (errorStr.contains('index') && errorStr.contains('building')) {
                        return const Center(
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              CircularProgressIndicator(),
                              SizedBox(height: 16),
                              Text(
                                'Setting up...\nPlease wait a moment',
                                textAlign: TextAlign.center,
                                style: TextStyle(color: AppColors.textSecondaryDark),
                              ),
                            ],
                          ),
                        );
                      }
                      return Center(
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            const Icon(Icons.error_outline, size: 48, color: AppColors.error),
                            const SizedBox(height: 8),
                            Text(
                              'Unable to load messages',
                              style: TextStyle(color: AppColors.textSecondaryDark),
                            ),
                          ],
                        ),
                      );
                    },
                    data: (messages) {
                      if (messages.isEmpty) {
                        return const Center(
                          child: Text(
                            'No messages yet\nPress and hold the button to record',
                            textAlign: TextAlign.center,
                            style: TextStyle(color: AppColors.textSecondaryDark),
                          ),
                        );
                      }
                      return _buildMessageList(messages);
                    },
                  ),
                ),

                // PTT Button area
                _buildPttArea(channel),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildMessageList(List<MessageModel> messages) {
    return ListView.builder(
      reverse: true,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      itemCount: messages.length,
      itemBuilder: (context, index) {
        final message = messages[index];
        final currentUser = ref.read(authStateProvider).value;
        final isMe = message.senderId == currentUser?.uid;
        final isPlaying = _currentlyPlayingId == message.id;

        return Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Row(
            mainAxisAlignment: isMe ? MainAxisAlignment.end : MainAxisAlignment.start,
            children: [
              Container(
                constraints: BoxConstraints(
                  maxWidth: MediaQuery.of(context).size.width * 0.75,
                ),
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: isMe ? AppColors.primary.withValues(alpha: 0.2) : AppColors.cardDark,
                  borderRadius: BorderRadius.circular(16),
                  border: isPlaying ? Border.all(color: AppColors.primary, width: 2) : null,
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // Play button
                    GestureDetector(
                      onTap: () => _playAudio(message),
                      child: Container(
                        width: 44,
                        height: 44,
                        decoration: BoxDecoration(
                          color: isPlaying ? AppColors.primary : (isMe ? AppColors.primary : AppColors.surfaceDark),
                          shape: BoxShape.circle,
                        ),
                        child: Icon(
                          isPlaying ? Icons.stop : Icons.play_arrow,
                          color: isPlaying || isMe ? Colors.black : Colors.white,
                          size: 24,
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    // Message info
                    Flexible(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            isMe ? 'You' : message.senderName,
                            style: TextStyle(
                              fontWeight: FontWeight.bold,
                              fontSize: 13,
                              color: isMe ? AppColors.primary : Colors.white,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                Icons.mic,
                                size: 14,
                                color: AppColors.textSecondaryDark,
                              ),
                              const SizedBox(width: 4),
                              Text(
                                '${message.audioDuration ?? 0}s',
                                style: TextStyle(
                                  fontSize: 12,
                                  color: AppColors.textSecondaryDark,
                                ),
                              ),
                              const SizedBox(width: 8),
                              Text(
                                _formatTime(message.timestamp),
                                style: TextStyle(
                                  fontSize: 11,
                                  color: AppColors.textSecondaryDark,
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
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

  String _formatTime(DateTime? timestamp) {
    if (timestamp == null) return '';
    final now = DateTime.now();
    final diff = now.difference(timestamp);

    if (diff.inMinutes < 1) {
      return 'Just now';
    } else if (diff.inHours < 1) {
      return '${diff.inMinutes}m ago';
    } else if (diff.inDays < 1) {
      return DateFormat('HH:mm').format(timestamp);
    } else {
      return DateFormat('MMM d, HH:mm').format(timestamp);
    }
  }

  Widget _buildPttArea(ChannelModel channel) {
    final session = ref.watch(pttSessionProvider(channel.id));

    String statusText;
    switch (session.state) {
      case PttState.idle:
        statusText = 'Hold to record';
      case PttState.recording:
        statusText = 'Recording...';
      case PttState.uploading:
        statusText = 'Sending...';
      case PttState.error:
        statusText = session.errorMessage ?? 'Error';
    }

    return Container(
      padding: const EdgeInsets.fromLTRB(24, 16, 24, 24),
      decoration: BoxDecoration(
        color: AppColors.surfaceDark,
        border: Border(top: BorderSide(color: AppColors.cardDark)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Status text
          Text(
            statusText,
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: session.isRecording ? Colors.red : AppColors.textSecondaryDark,
                  fontWeight: session.isRecording ? FontWeight.bold : FontWeight.normal,
                ),
          ),
          const SizedBox(height: 16),
          // PTT Button
          PttButton(channelId: channel.id),
        ],
      ),
    );
  }
}
