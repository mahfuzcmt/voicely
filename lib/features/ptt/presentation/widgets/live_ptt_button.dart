import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/services/native_audio_service.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/utils/extensions.dart';
import '../providers/live_ptt_providers.dart';

/// Enhanced PTT button for real-time streaming
class LivePttButton extends ConsumerStatefulWidget {
  final String channelId;
  final double size;

  const LivePttButton({
    super.key,
    required this.channelId,
    this.size = 120,
  });

  @override
  ConsumerState<LivePttButton> createState() => _LivePttButtonState();
}

class _LivePttButtonState extends ConsumerState<LivePttButton>
    with SingleTickerProviderStateMixin {
  late AnimationController _pulseController;
  late Animation<double> _pulseAnimation;

  @override
  void initState() {
    super.initState();
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1000),
    );
    _pulseAnimation = Tween<double>(begin: 1.0, end: 1.15).animate(
      CurvedAnimation(parent: _pulseController, curve: Curves.easeInOut),
    );
  }

  @override
  void dispose() {
    _pulseController.dispose();
    super.dispose();
  }

  /// Toggle broadcasting on tap - tap to start, tap again to stop
  void _onTapToggle() async {
    final session = ref.read(livePttSessionProvider(widget.channelId));

    // If currently broadcasting or requesting floor, stop
    if (session.isBroadcasting || session.state == LivePttState.requestingFloor) {
      HapticFeedback.lightImpact();
      _pulseController.stop();
      _pulseController.reset();

      await ref
          .read(livePttSessionProvider(widget.channelId).notifier)
          .stopBroadcasting();
      return;
    }

    // Check if can broadcast
    if (!session.canBroadcast) {
      if (session.state == LivePttState.error) {
        ref.read(livePttSessionProvider(widget.channelId).notifier).clearError();
      } else if (!session.isConnected && !session.isConnecting) {
        // Try to reconnect
        ref.read(livePttSessionProvider(widget.channelId).notifier).reconnect();
        context.showSnackBar('Reconnecting...');
      } else if (session.isListening) {
        // Someone else is speaking
        final speakerName = (session.currentSpeakerName?.isNotEmpty == true)
            ? session.currentSpeakerName!
            : 'Another user';
        context.showSnackBar('$speakerName is speaking');
      }
      return;
    }

    // Start broadcasting
    HapticFeedback.heavyImpact();
    _pulseController.repeat(reverse: true);

    final success = await ref
        .read(livePttSessionProvider(widget.channelId).notifier)
        .startBroadcasting();

    if (!success && mounted) {
      _pulseController.stop();
      _pulseController.reset();

      final errorSession = ref.read(livePttSessionProvider(widget.channelId));
      if (errorSession.errorMessage != null) {
        context.showSnackBar(errorSession.errorMessage!, isError: true);
        ref.read(livePttSessionProvider(widget.channelId).notifier).clearError();
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final session = ref.watch(livePttSessionProvider(widget.channelId));

    // Update pulse animation based on state
    if (session.isBroadcasting && !_pulseController.isAnimating) {
      _pulseController.repeat(reverse: true);
    } else if (!session.isBroadcasting && _pulseController.isAnimating) {
      _pulseController.stop();
      _pulseController.reset();
    }

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        // Current speaker display (when listening)
        if (session.isListening) ...[
          _buildSpeakerIndicator(session),
          const SizedBox(height: 8),
        ],

        // Main PTT button with new design - tap to toggle
        GestureDetector(
          onTap: _onTapToggle,
          child: AnimatedBuilder(
            animation: _pulseAnimation,
            builder: (context, child) {
              return Transform.scale(
                scale: session.isBroadcasting ? _pulseAnimation.value : 1.0,
                child: child,
              );
            },
            child: _buildPttButtonDesign(session),
          ),
        ),
      ],
    );
  }

  /// Build the PTT button with the new design matching the UI mockup
  Widget _buildPttButtonDesign(LivePttSessionState session) {
    final ringColor = _getRingColor(session);
    final iconColor = _getIconColor(session);
    final isActive = session.isBroadcasting || session.state == LivePttState.requestingFloor;

    return SizedBox(
      width: widget.size,
      height: widget.size,
      child: Stack(
        alignment: Alignment.center,
        children: [
          // Outer subtle ring (light gray)
          Container(
            width: widget.size,
            height: widget.size,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: Colors.grey[100],
            ),
          ),

          // Orange/colored ring
          Container(
            width: widget.size * 0.85,
            height: widget.size * 0.85,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              border: Border.all(
                color: ringColor,
                width: widget.size * 0.025,
              ),
            ),
          ),

          // White center with icon and text
          Container(
            width: widget.size * 0.7,
            height: widget.size * 0.7,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: Colors.white,
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.1),
                  blurRadius: 10,
                  spreadRadius: 2,
                ),
              ],
            ),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(
                  _getIcon(session),
                  size: widget.size * 0.2,
                  color: iconColor,
                ),
                SizedBox(height: widget.size * 0.02),
                // Text inside button based on state
                if (session.isBroadcasting) ...[
                  _buildRecordingIndicator(session.isBroadcastTimeWarning ? Colors.red : iconColor),
                  SizedBox(height: widget.size * 0.02),
                  // Show listener count when broadcasting
                  if (session.listenerCount > 0) ...[
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          Icons.headphones,
                          size: widget.size * 0.045,
                          color: Colors.green,
                        ),
                        SizedBox(width: widget.size * 0.01),
                        Text(
                          '${session.listenerCount}',
                          style: TextStyle(
                            fontSize: widget.size * 0.05,
                            color: Colors.green,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ],
                    ),
                    SizedBox(height: widget.size * 0.01),
                  ],
                  Text(
                    session.isBroadcastTimeWarning
                        ? '${session.remainingBroadcastSeconds}s'
                        : 'Tap to stop',
                    style: TextStyle(
                      fontSize: widget.size * 0.055,
                      color: session.isBroadcastTimeWarning ? Colors.red : Colors.orange[700],
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ] else if (session.state == LivePttState.requestingFloor) ...[
                  SizedBox(
                    width: widget.size * 0.1,
                    height: widget.size * 0.1,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      valueColor: AlwaysStoppedAnimation<Color>(iconColor),
                    ),
                  ),
                ] else if (session.isListening) ...[
                  Text(
                    'Listening',
                    style: TextStyle(
                      fontSize: widget.size * 0.055,
                      color: Colors.green,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ] else if (session.canBroadcast) ...[
                  Text(
                    'Tap to speak',
                    style: TextStyle(
                      fontSize: widget.size * 0.055,
                      color: Colors.grey[600],
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ] else if (!session.isConnected) ...[
                  Text(
                    'Reconnect',
                    style: TextStyle(
                      fontSize: widget.size * 0.055,
                      color: Colors.grey[500],
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ],
            ),
          ),

          // Pulsing overlay when broadcasting
          if (isActive)
            Container(
              width: widget.size * 0.85,
              height: widget.size * 0.85,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(
                  color: ringColor.withValues(alpha: 0.3),
                  width: widget.size * 0.05,
                ),
              ),
            ),
        ],
      ),
    );
  }

  Color _getRingColor(LivePttSessionState session) {
    switch (session.state) {
      case LivePttState.idle:
        return session.isConnected ? Colors.orange : Colors.grey;
      case LivePttState.connecting:
      case LivePttState.requestingFloor:
        return Colors.orange;
      case LivePttState.broadcasting:
        // Red when time is running low, orange otherwise
        return session.isBroadcastTimeWarning ? Colors.red : Colors.orange;
      case LivePttState.listening:
        return Colors.green;
      case LivePttState.error:
        return Colors.red;
      case LivePttState.disconnected:
        return Colors.grey;
    }
  }

  Color _getIconColor(LivePttSessionState session) {
    switch (session.state) {
      case LivePttState.idle:
        return session.isConnected ? AppColors.primary : Colors.grey;
      case LivePttState.connecting:
      case LivePttState.requestingFloor:
        return Colors.orange;
      case LivePttState.broadcasting:
        // Red when time is running low, orange otherwise
        return session.isBroadcastTimeWarning ? Colors.red : Colors.orange;
      case LivePttState.listening:
        return Colors.green;
      case LivePttState.error:
        return Colors.red;
      case LivePttState.disconnected:
        return Colors.grey;
    }
  }

  Widget _buildStatusIndicator(LivePttSessionState session) {
    Color dotColor;
    String statusText;

    if (session.isConnected) {
      dotColor = Colors.green;
      statusText = 'Connected';
    } else if (session.isConnecting) {
      dotColor = Colors.orange;
      statusText = 'Connecting...';
    } else if (session.state == LivePttState.error) {
      dotColor = Colors.red;
      statusText = 'Error';
    } else {
      dotColor = Colors.grey;
      statusText = 'Disconnected';
    }

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 8,
          height: 8,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: dotColor,
          ),
        ),
        const SizedBox(width: 6),
        Text(
          statusText,
          style: TextStyle(
            fontSize: 12,
            color: Colors.grey[600],
          ),
        ),
      ],
    );
  }

  Widget _buildSpeakerIndicator(LivePttSessionState session) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          decoration: BoxDecoration(
            color: Colors.green.withValues(alpha: 0.1),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: Colors.green.withValues(alpha: 0.3)),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(
                Icons.volume_up,
                size: 16,
                color: Colors.green,
              ),
              const SizedBox(width: 6),
              Text(
                (session.currentSpeakerName?.isNotEmpty == true)
                    ? session.currentSpeakerName!
                    : 'User',
                style: const TextStyle(
                  fontSize: 12,
                  color: Colors.green,
                  fontWeight: FontWeight.w500,
                ),
              ),
              const SizedBox(width: 4),
              const Text(
                'is speaking',
                style: TextStyle(
                  fontSize: 12,
                  color: Colors.green,
                ),
              ),
            ],
          ),
        ),
        // DEBUG: Show audio state
        const SizedBox(height: 8),
        _AudioDebugInfo(channelId: widget.channelId),
      ],
    );
  }

  Widget _buildDurationDisplay(LivePttSessionState session) {
    final duration = session.broadcastDuration;
    final minutes = duration.inMinutes;
    final seconds = duration.inSeconds % 60;
    final timeStr = '${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}';

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      decoration: BoxDecoration(
        color: Colors.orange.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 8,
            height: 8,
            decoration: const BoxDecoration(
              shape: BoxShape.circle,
              color: Colors.orange,
            ),
          ),
          const SizedBox(width: 6),
          Text(
            'LIVE $timeStr',
            style: const TextStyle(
              fontSize: 12,
              color: Colors.orange,
              fontWeight: FontWeight.bold,
            ),
          ),
        ],
      ),
    );
  }

  Color _getButtonColor(LivePttSessionState session) {
    switch (session.state) {
      case LivePttState.idle:
        return session.isConnected ? AppColors.primary : Colors.grey;
      case LivePttState.connecting:
      case LivePttState.requestingFloor:
        return Colors.orange;
      case LivePttState.broadcasting:
        return Colors.red;
      case LivePttState.listening:
        return Colors.green;
      case LivePttState.error:
        return AppColors.error;
      case LivePttState.disconnected:
        return Colors.grey;
    }
  }

  IconData _getIcon(LivePttSessionState session) {
    switch (session.state) {
      case LivePttState.idle:
        return Icons.mic;
      case LivePttState.connecting:
      case LivePttState.requestingFloor:
        return Icons.mic;
      case LivePttState.broadcasting:
        return Icons.stop;  // Show stop icon when broadcasting (tap to stop)
      case LivePttState.listening:
        return Icons.volume_up;
      case LivePttState.error:
        return Icons.error_outline;
      case LivePttState.disconnected:
        return Icons.signal_wifi_off;
    }
  }

  Widget _buildRecordingIndicator([Color? color]) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: List.generate(
        5,
        (index) => _AudioBar(delay: index * 100, color: color ?? Colors.white),
      ),
    );
  }
}

class _AudioBar extends StatefulWidget {
  final int delay;
  final Color color;

  const _AudioBar({required this.delay, this.color = Colors.white});

  @override
  State<_AudioBar> createState() => _AudioBarState();
}

class _AudioBarState extends State<_AudioBar>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<double> _animation;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 400),
    );
    _animation = Tween<double>(begin: 4, end: 14).animate(
      CurvedAnimation(parent: _controller, curve: Curves.easeInOut),
    );

    Future.delayed(Duration(milliseconds: widget.delay), () {
      if (mounted) {
        _controller.repeat(reverse: true);
      }
    });
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
        return Container(
          width: 3,
          height: _animation.value,
          margin: const EdgeInsets.symmetric(horizontal: 1),
          decoration: BoxDecoration(
            color: widget.color,
            borderRadius: BorderRadius.circular(2),
          ),
        );
      },
    );
  }
}

/// Debug widget to show audio state on screen
class _AudioDebugInfo extends ConsumerStatefulWidget {
  final String channelId;

  const _AudioDebugInfo({required this.channelId});

  @override
  ConsumerState<_AudioDebugInfo> createState() => _AudioDebugInfoState();
}

class _AudioDebugInfoState extends ConsumerState<_AudioDebugInfo> {
  Map<String, dynamic>? _audioState;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _loadAudioState();
  }

  Future<void> _loadAudioState() async {
    final state = await NativeAudioService.getAudioState();
    if (mounted) {
      setState(() {
        _audioState = state;
        _loading = false;
      });
    }
    // Refresh every second while visible
    Future.delayed(const Duration(seconds: 1), () {
      if (mounted) _loadAudioState();
    });
  }

  @override
  Widget build(BuildContext context) {
    // Get WebRTC state from provider
    final session = ref.watch(livePttSessionProvider(widget.channelId));

    if (_loading || _audioState == null) {
      return const Text(
        'Loading audio state...',
        style: TextStyle(fontSize: 10, color: Colors.grey),
      );
    }

    final mode = _audioState!['modeString'] ?? 'Unknown';
    final speaker = _audioState!['isSpeakerphoneOn'] == true ? 'ON' : 'OFF';
    final voiceVol = _audioState!['voiceCallVolume'] ?? '?';
    final voiceMax = _audioState!['voiceCallMaxVolume'] ?? '?';
    final musicVol = _audioState!['musicVolume'] ?? '?';
    final musicMax = _audioState!['musicMaxVolume'] ?? '?';

    // WebRTC state
    final tracksReceived = session.audioTracksReceived;
    final onTrackFired = session.onTrackFired;
    final iceState = session.iceState ?? 'unknown';

    return Container(
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: Colors.black87,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'DEBUG - AUDIO & WEBRTC',
            style: TextStyle(
              fontSize: 10,
              fontWeight: FontWeight.bold,
              color: Colors.yellow[400],
            ),
          ),
          const SizedBox(height: 4),
          // Android Audio State
          Text(
            'Mode: $mode',
            style: TextStyle(
              fontSize: 10,
              color: mode == 'IN_COMMUNICATION' ? Colors.green : Colors.red,
            ),
          ),
          Text(
            'Speaker: $speaker',
            style: TextStyle(
              fontSize: 10,
              color: speaker == 'ON' ? Colors.green : Colors.red,
            ),
          ),
          Text(
            'Voice Vol: $voiceVol/$voiceMax',
            style: TextStyle(
              fontSize: 10,
              color: voiceVol == voiceMax ? Colors.green : Colors.orange,
            ),
          ),
          Text(
            'Music Vol: $musicVol/$musicMax',
            style: TextStyle(
              fontSize: 10,
              color: musicVol == musicMax ? Colors.green : Colors.orange,
            ),
          ),
          const Divider(color: Colors.grey, height: 8),
          // WebRTC State
          Text(
            'onTrack: ${onTrackFired ? "YES" : "NO"}',
            style: TextStyle(
              fontSize: 10,
              color: onTrackFired ? Colors.green : Colors.red,
            ),
          ),
          Text(
            'Audio Tracks: $tracksReceived',
            style: TextStyle(
              fontSize: 10,
              color: tracksReceived > 0 ? Colors.green : Colors.red,
            ),
          ),
          Text(
            'ICE: $iceState',
            style: TextStyle(
              fontSize: 10,
              color: iceState.contains('Connected') ? Colors.green : Colors.orange,
            ),
          ),
        ],
      ),
    );
  }
}
