import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/services/hardware_ptt_service.dart';
import '../../../../core/services/native_audio_service.dart';
import '../../../../core/utils/extensions.dart';
import '../../data/websocket_signaling_service.dart';
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
    with TickerProviderStateMixin {
  late AnimationController _pulseController;
  late Animation<double> _pulseAnimation;
  late AnimationController _pressController;
  late Animation<double> _pressAnimation;
  String? _lastSpeakerId;
  bool _isPressed = false;

  // Batching for listener joined notifications
  final List<String> _pendingListenerNames = [];
  Timer? _listenerBatchTimer;
  static const Duration _listenerBatchDelay = Duration(milliseconds: 800);

  // Hardware PTT button subscription
  StreamSubscription<PttEvent>? _hardwarePttSubscription;

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

    // Press animation for immediate tactile feedback
    _pressController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 50),
    );
    _pressAnimation = Tween<double>(begin: 1.0, end: 0.95).animate(
      CurvedAnimation(parent: _pressController, curve: Curves.easeOut),
    );

    // Set up listener joined callback for toast notifications
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.read(livePttSessionProvider(widget.channelId).notifier).onListenerJoined = (listenerName) {
        if (mounted) {
          _queueListenerJoinedNotification(listenerName);
        }
      };
    });

    // Set up hardware PTT button listener (for Chinese PTT devices)
    _setupHardwarePttListener();
  }

  /// Set up hardware PTT button listener for Chinese PTT devices
  void _setupHardwarePttListener() {
    _hardwarePttSubscription = HardwarePttService.pttEvents.listen((event) {
      if (!mounted) return;

      debugPrint('LivePttButton: Hardware PTT event: $event');

      if (event.type == PttEventType.down) {
        _onHardwarePttDown();
      } else {
        _onHardwarePttUp();
      }
    });
    debugPrint('LivePttButton: Hardware PTT listener set up');
  }

  /// Handle hardware PTT button press - start broadcasting
  Future<void> _onHardwarePttDown() async {
    final session = ref.read(livePttSessionProvider(widget.channelId));

    // If already broadcasting, do nothing
    if (session.isBroadcasting || session.state == LivePttState.requestingFloor) {
      return;
    }

    // Check if can broadcast
    if (!session.canBroadcast) {
      if (session.isListening) {
        // Someone else is speaking, provide haptic feedback
        HapticFeedback.vibrate();
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
      HapticFeedback.vibrate(); // Error feedback
    }
  }

  /// Handle hardware PTT button release - stop broadcasting
  Future<void> _onHardwarePttUp() async {
    final session = ref.read(livePttSessionProvider(widget.channelId));

    // Only stop if we are currently broadcasting
    if (session.isBroadcasting) {
      HapticFeedback.lightImpact();
      _pulseController.stop();
      _pulseController.reset();

      await ref
          .read(livePttSessionProvider(widget.channelId).notifier)
          .stopBroadcasting();
    }
  }

  @override
  void dispose() {
    // Clear the callback to avoid memory leaks
    ref.read(livePttSessionProvider(widget.channelId).notifier).onListenerJoined = null;
    _listenerBatchTimer?.cancel();
    _pendingListenerNames.clear();
    _pulseController.dispose();
    _pressController.dispose();
    // Cancel hardware PTT subscription
    _hardwarePttSubscription?.cancel();
    _hardwarePttSubscription = null;
    super.dispose();
  }

  /// Handle tap down for immediate visual feedback
  void _onTapDown(TapDownDetails details) {
    if (!_isPressed) {
      _isPressed = true;
      HapticFeedback.selectionClick();
      _pressController.forward();
    }
  }

  /// Handle tap up/cancel to reset visual state
  void _onTapUp(TapUpDetails? details) {
    if (_isPressed) {
      _isPressed = false;
      _pressController.reverse();
    }
  }

  /// Handle tap cancel
  void _onTapCancel() {
    if (_isPressed) {
      _isPressed = false;
      _pressController.reverse();
    }
  }

  /// Toggle broadcasting on tap - tap to start, tap again to stop
  void _onTapToggle() async {
    // Reset press animation
    _onTapUp(null);

    try {
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

      // Wake up screen if it's off (for software PTT press)
      HardwarePttService.wakeScreen();

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
    } catch (e) {
      debugPrint('LivePTT: Error in tap toggle: $e');
      if (mounted) {
        _pulseController.stop();
        _pulseController.reset();
        context.showSnackBar('Error: please try again', isError: true);
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

    // Show toast when someone starts speaking (speaker changes from null to someone)
    // Don't show if we are the speaker
    final wsService = ref.watch(websocketSignalingServiceProvider);
    final currentSpeakerId = session.currentSpeakerId;
    if (currentSpeakerId != null &&
        currentSpeakerId != _lastSpeakerId &&
        currentSpeakerId != wsService.userId &&
        session.currentSpeakerName != null) {
      // Use post-frame callback to avoid showing during build
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          _showSpeakerToast(session.currentSpeakerName!);
        }
      });
    }
    _lastSpeakerId = currentSpeakerId;

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        // Current speaker display (when listening)
        if (session.isListening) ...[
          _buildSpeakerIndicator(session),
          const SizedBox(height: 8),
        ],

        // Main PTT button with new design - tap to toggle
        Semantics(
          button: true,
          enabled: session.state != LivePttState.error,
          label: session.isBroadcasting
              ? 'Stop broadcasting. Tap to release'
              : session.isListening
                  ? 'Someone is speaking. Tap to request floor'
                  : 'Push to talk button. Tap to start broadcasting',
          child: GestureDetector(
            onTapDown: _onTapDown,
            onTapUp: _onTapUp,
            onTapCancel: _onTapCancel,
            onTap: _onTapToggle,
            child: AnimatedBuilder(
              animation: Listenable.merge([_pulseAnimation, _pressAnimation]),
              builder: (context, child) {
                final scale = session.isBroadcasting
                    ? _pulseAnimation.value * _pressAnimation.value
                    : _pressAnimation.value;
                return Transform.scale(
                  scale: scale,
                  child: child,
                );
              },
              child: _buildPttButtonDesign(session),
            ),
          ),
        ),
      ],
    );
  }

  /// Build the PTT button with professional dark theme design
  Widget _buildPttButtonDesign(LivePttSessionState session) {
    final isActive = session.isBroadcasting || session.state == LivePttState.requestingFloor;
    final isListening = session.isListening;
    final isError = session.state == LivePttState.error;
    final isDisconnected = !session.isConnected && !session.isConnecting;

    // Professional dark theme colors (matching XIN POC style)
    const darkCenter = Color(0xFF363B44);
    const darkOuter = Color(0xFF2B3038);
    const darkRing = Color(0xFF1E2228);
    const orangeAccent = Color(0xFFF5A623);
    const greenAccent = Color(0xFF4CAF50);
    const redAccent = Color(0xFFE53935);

    // Determine glow color based on state
    Color? glowColor;
    if (isActive) {
      glowColor = session.isBroadcastTimeWarning ? redAccent : orangeAccent;
    } else if (isListening) {
      glowColor = greenAccent;
    }

    // Determine icon color
    Color iconColor;
    if (isError) {
      iconColor = redAccent;
    } else if (isDisconnected) {
      iconColor = Colors.grey;
    } else if (isListening) {
      iconColor = greenAccent;
    } else {
      iconColor = orangeAccent;
    }

    return SizedBox(
      width: widget.size,
      height: widget.size,
      child: Stack(
        alignment: Alignment.center,
        children: [
          // Glow effect when active or listening
          if (glowColor != null)
            Container(
              width: widget.size,
              height: widget.size,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                boxShadow: [
                  BoxShadow(
                    color: glowColor.withValues(alpha: 0.5),
                    blurRadius: 25,
                    spreadRadius: 5,
                  ),
                ],
              ),
            ),

          // Outer dark ring with 3D bevel effect
          Container(
            width: widget.size,
            height: widget.size,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [
                  darkRing.withValues(alpha: 0.8),
                  darkOuter,
                  const Color(0xFF151515),
                ],
              ),
              boxShadow: [
                // Outer shadow for depth
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.5),
                  offset: const Offset(4, 4),
                  blurRadius: 10,
                ),
                // Inner highlight
                BoxShadow(
                  color: Colors.white.withValues(alpha: 0.05),
                  offset: const Offset(-2, -2),
                  blurRadius: 6,
                ),
              ],
            ),
          ),

          // Inner button area with gradient
          Container(
            width: widget.size * 0.85,
            height: widget.size * 0.85,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: RadialGradient(
                center: Alignment.center,
                radius: 0.8,
                colors: [
                  darkCenter,
                  darkOuter,
                ],
              ),
              border: Border.all(
                color: glowColor?.withValues(alpha: 0.6) ?? Colors.transparent,
                width: glowColor != null ? 3 : 0,
              ),
              boxShadow: [
                // Inset shadow effect
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.4),
                  offset: const Offset(2, 2),
                  blurRadius: 8,
                ),
              ],
            ),
          ),

          // Center icon area
          Container(
            width: widget.size * 0.65,
            height: widget.size * 0.65,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: RadialGradient(
                center: const Alignment(0.1, -0.1),
                radius: 1.0,
                colors: [
                  darkCenter.withValues(alpha: 0.9),
                  darkOuter,
                ],
              ),
            ),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                // Main icon - larger, prominent
                Icon(
                  _getIcon(session),
                  size: widget.size * 0.32,
                  color: iconColor,
                ),
                // Minimal status indicator below icon
                if (session.isBroadcasting) ...[
                  SizedBox(height: widget.size * 0.02),
                  _buildRecordingIndicator(
                    session.isBroadcastTimeWarning ? redAccent : orangeAccent,
                  ),
                  if (session.isBroadcastTimeWarning) ...[
                    SizedBox(height: widget.size * 0.01),
                    Text(
                      '${session.remainingBroadcastSeconds}s',
                      style: TextStyle(
                        fontSize: widget.size * 0.07,
                        color: redAccent,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ],
                ] else if (session.state == LivePttState.requestingFloor) ...[
                  SizedBox(height: widget.size * 0.02),
                  SizedBox(
                    width: widget.size * 0.08,
                    height: widget.size * 0.08,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      valueColor: AlwaysStoppedAnimation<Color>(orangeAccent),
                    ),
                  ),
                ],
              ],
            ),
          ),

          // Listener count badge when broadcasting
          if (session.isBroadcasting && session.listenerCount > 0)
            Positioned(
              right: widget.size * 0.08,
              top: widget.size * 0.08,
              child: Container(
                padding: EdgeInsets.symmetric(
                  horizontal: widget.size * 0.04,
                  vertical: widget.size * 0.02,
                ),
                decoration: BoxDecoration(
                  color: greenAccent,
                  borderRadius: BorderRadius.circular(widget.size * 0.06),
                  boxShadow: [
                    BoxShadow(
                      color: greenAccent.withValues(alpha: 0.5),
                      blurRadius: 8,
                      spreadRadius: 1,
                    ),
                  ],
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.headphones,
                      size: widget.size * 0.06,
                      color: Colors.white,
                    ),
                    SizedBox(width: widget.size * 0.015),
                    Text(
                      session.allListening
                          ? 'All ${session.listenerCount}'
                          : (session.totalRoomMembers > 0
                              ? '${session.listenerCount}/${session.totalRoomMembers}'
                              : '${session.listenerCount}'),
                      style: TextStyle(
                        fontSize: widget.size * 0.055,
                        color: Colors.white,
                        fontWeight: FontWeight.bold,
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
    const greenAccent = Color(0xFF4CAF50);

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        // Speaker info with professional dark theme
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          decoration: BoxDecoration(
            color: const Color(0xFF1E2228),
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: greenAccent.withValues(alpha: 0.5), width: 1.5),
            boxShadow: [
              BoxShadow(
                color: greenAccent.withValues(alpha: 0.3),
                blurRadius: 12,
                spreadRadius: 1,
              ),
            ],
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                padding: const EdgeInsets.all(4),
                decoration: BoxDecoration(
                  color: greenAccent.withValues(alpha: 0.2),
                  shape: BoxShape.circle,
                ),
                child: const Icon(
                  Icons.volume_up,
                  size: 16,
                  color: greenAccent,
                ),
              ),
              const SizedBox(width: 8),
              Text(
                (session.currentSpeakerName?.isNotEmpty == true)
                    ? session.currentSpeakerName!
                    : 'User',
                style: const TextStyle(
                  fontSize: 13,
                  color: Colors.white,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(width: 6),
              Text(
                'is speaking',
                style: TextStyle(
                  fontSize: 13,
                  color: Colors.white.withValues(alpha: 0.7),
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

  /// Force stop the current broadcast - can be used by any user
  Future<void> _forceStopBroadcast() async {
    await ref.read(livePttSessionProvider(widget.channelId).notifier).forceStopCurrentBroadcast();
    if (mounted) {
      context.showSnackBar('Broadcast stopped');
    }
  }

  /// Show a bubble toast when someone starts speaking
  void _showSpeakerToast(String speakerName) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(
              Icons.volume_up,
              color: Colors.white,
              size: 20,
            ),
            const SizedBox(width: 8),
            Flexible(
              child: Text(
                '$speakerName is speaking',
                style: const TextStyle(
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
          ],
        ),
        backgroundColor: Colors.green,
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(24),
        ),
        margin: EdgeInsets.only(
          bottom: MediaQuery.of(context).size.height * 0.1,
          left: 20,
          right: 20,
        ),
        duration: const Duration(seconds: 3),
        dismissDirection: DismissDirection.horizontal,
      ),
    );
  }

  /// Queue a listener joined notification for batching
  /// This collects multiple listeners who join in quick succession
  /// and shows them together in a single notification
  void _queueListenerJoinedNotification(String listenerName) {
    // Add to pending list
    if (!_pendingListenerNames.contains(listenerName)) {
      _pendingListenerNames.add(listenerName);
    }

    // Reset or start the batch timer
    _listenerBatchTimer?.cancel();
    _listenerBatchTimer = Timer(_listenerBatchDelay, () {
      if (mounted && _pendingListenerNames.isNotEmpty) {
        _showBatchedListenerToast();
      }
    });
  }

  /// Show a batched toast with all pending listener names
  void _showBatchedListenerToast() {
    if (_pendingListenerNames.isEmpty) return;

    // Create the message based on count
    String message;
    if (_pendingListenerNames.length == 1) {
      message = '${_pendingListenerNames.first} joined';
    } else if (_pendingListenerNames.length == 2) {
      message = '${_pendingListenerNames[0]} & ${_pendingListenerNames[1]} joined';
    } else {
      // Show first two names + count of others
      final othersCount = _pendingListenerNames.length - 2;
      message = '${_pendingListenerNames[0]}, ${_pendingListenerNames[1]} +$othersCount joined';
    }

    // Clear the pending list
    _pendingListenerNames.clear();

    // Show the notification
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(
              Icons.headphones,
              color: Colors.white,
              size: 20,
            ),
            const SizedBox(width: 8),
            Flexible(
              child: Text(
                message,
                style: const TextStyle(
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
          ],
        ),
        backgroundColor: Colors.blue,
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(24),
        ),
        margin: EdgeInsets.only(
          bottom: MediaQuery.of(context).size.height * 0.15,
          left: 20,
          right: 20,
        ),
        duration: const Duration(seconds: 2),
        dismissDirection: DismissDirection.horizontal,
      ),
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
