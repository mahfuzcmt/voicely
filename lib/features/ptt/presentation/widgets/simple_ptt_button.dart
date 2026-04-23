import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/services/hardware_ptt_service.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/utils/extensions.dart';
import '../../data/websocket_signaling_service.dart';
import '../providers/simple_ptt_providers.dart';

/// Simplified PTT button - core functionality only
class SimplePttButton extends ConsumerStatefulWidget {
  final String channelId;
  final double size;

  const SimplePttButton({
    super.key,
    required this.channelId,
    this.size = 180, // Bigger button for PTT devices
  });

  @override
  ConsumerState<SimplePttButton> createState() => _SimplePttButtonState();
}

class _SimplePttButtonState extends ConsumerState<SimplePttButton>
    with SingleTickerProviderStateMixin {
  late AnimationController _pulseController;
  late Animation<double> _pulseAnimation;
  String? _lastSpeakerId;
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

    _setupHardwarePttListener();
  }

  void _setupHardwarePttListener() {
    _hardwarePttSubscription = HardwarePttService.pttEvents.listen((event) {
      if (!mounted) return;

      if (event.type == PttEventType.down) {
        _onHardwarePttDown();
      } else {
        _onHardwarePttUp();
      }
    });
  }

  Future<void> _onHardwarePttDown() async {
    final session = ref.read(simplePttSessionProvider(widget.channelId));

    if (session.isBroadcasting ||
        session.state == SimplePttState.requestingFloor) {
      return;
    }

    if (!session.canBroadcast) {
      if (session.isListening) {
        HapticFeedback.vibrate();
      }
      return;
    }

    HapticFeedback.heavyImpact();
    _pulseController.repeat(reverse: true);

    final success = await ref
        .read(simplePttSessionProvider(widget.channelId).notifier)
        .startBroadcasting();

    if (!success && mounted) {
      _pulseController.stop();
      _pulseController.reset();
      HapticFeedback.vibrate();
    }
  }

  Future<void> _onHardwarePttUp() async {
    final session = ref.read(simplePttSessionProvider(widget.channelId));

    if (session.isBroadcasting) {
      HapticFeedback.lightImpact();
      _pulseController.stop();
      _pulseController.reset();

      await ref
          .read(simplePttSessionProvider(widget.channelId).notifier)
          .stopBroadcasting();
    }
  }

  @override
  void dispose() {
    _pulseController.dispose();
    _hardwarePttSubscription?.cancel();
    super.dispose();
  }

  void _onTapToggle() async {
    try {
      final session = ref.read(simplePttSessionProvider(widget.channelId));

      if (session.isBroadcasting ||
          session.state == SimplePttState.requestingFloor) {
        HapticFeedback.lightImpact();
        _pulseController.stop();
        _pulseController.reset();

        await ref
            .read(simplePttSessionProvider(widget.channelId).notifier)
            .stopBroadcasting();
        return;
      }

      if (!session.canBroadcast) {
        if (session.state == SimplePttState.error) {
          ref
              .read(simplePttSessionProvider(widget.channelId).notifier)
              .clearError();
        } else if (!session.isConnected && !session.isConnecting) {
          ref
              .read(simplePttSessionProvider(widget.channelId).notifier)
              .reconnect();
          context.showSnackBar('Reconnecting...');
        } else if (session.isListening) {
          final speakerName = session.currentSpeakerName ?? 'Another user';
          context.showSnackBar('$speakerName is speaking');
        }
        return;
      }

      HapticFeedback.heavyImpact();
      _pulseController.repeat(reverse: true);

      final success = await ref
          .read(simplePttSessionProvider(widget.channelId).notifier)
          .startBroadcasting();

      if (!success && mounted) {
        _pulseController.stop();
        _pulseController.reset();

        final errorSession =
            ref.read(simplePttSessionProvider(widget.channelId));
        if (errorSession.errorMessage != null) {
          context.showSnackBar(errorSession.errorMessage!, isError: true);
          ref
              .read(simplePttSessionProvider(widget.channelId).notifier)
              .clearError();
        }
      }
    } catch (e) {
      debugPrint('SimplePTT: Tap toggle error: $e');
      if (mounted) {
        _pulseController.stop();
        _pulseController.reset();
        context.showSnackBar('Error: please try again', isError: true);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final session = ref.watch(simplePttSessionProvider(widget.channelId));

    // Update animation based on state
    if (session.isBroadcasting && !_pulseController.isAnimating) {
      _pulseController.repeat(reverse: true);
    } else if (!session.isBroadcasting && _pulseController.isAnimating) {
      _pulseController.stop();
      _pulseController.reset();
    }

    // Show toast when speaker changes
    final wsService = ref.watch(websocketSignalingServiceProvider);
    final currentSpeakerId = session.currentSpeakerId;
    if (currentSpeakerId != null &&
        currentSpeakerId != _lastSpeakerId &&
        currentSpeakerId != wsService.userId &&
        session.currentSpeakerName != null) {
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
        // Speaker indicator when listening
        if (session.isListening) ...[
          _buildSpeakerIndicator(session),
          const SizedBox(height: 8),
        ],

        // Main PTT button
        Semantics(
          button: true,
          enabled: session.state != SimplePttState.error,
          label: _getAccessibilityLabel(session),
          child: GestureDetector(
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
        ),
      ],
    );
  }

  String _getAccessibilityLabel(SimplePttSessionState session) {
    if (session.isBroadcasting) {
      return 'Stop broadcasting. Tap to release';
    } else if (session.isListening) {
      return 'Someone is speaking. Tap to request floor';
    } else {
      return 'Push to talk button. Tap to start broadcasting';
    }
  }

  Widget _buildPttButtonDesign(SimplePttSessionState session) {
    final ringColor = _getRingColor(session);
    final iconColor = _getIconColor(session);
    final isActive =
        session.isBroadcasting || session.state == SimplePttState.requestingFloor;

    return SizedBox(
      width: widget.size,
      height: widget.size,
      child: Stack(
        alignment: Alignment.center,
        children: [
          // Outer ring
          Container(
            width: widget.size,
            height: widget.size,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: Colors.grey[100],
            ),
          ),

          // Colored ring
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

          // Center with icon and text
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
                  size: widget.size * 0.25,
                  color: iconColor,
                ),
                SizedBox(height: widget.size * 0.015),
                _buildStateText(session, iconColor),
              ],
            ),
          ),

          // Pulsing overlay when active
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

  Widget _buildStateText(SimplePttSessionState session, Color iconColor) {
    if (session.isBroadcasting) {
      return Column(
        children: [
          _buildRecordingIndicator(
            session.isBroadcastTimeWarning ? Colors.red : iconColor,
          ),
          SizedBox(height: widget.size * 0.015),
          if (session.listenerCount > 0) ...[
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.headphones,
                  size: widget.size * 0.055,
                  color: Colors.green,
                ),
                SizedBox(width: widget.size * 0.01),
                Text(
                  '${session.listenerCount}',
                  style: TextStyle(
                    fontSize: widget.size * 0.06,
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
              fontSize: widget.size * 0.07,
              color: session.isBroadcastTimeWarning
                  ? Colors.red
                  : Colors.orange[700],
              fontWeight: FontWeight.bold,
            ),
          ),
        ],
      );
    } else if (session.state == SimplePttState.requestingFloor) {
      return SizedBox(
        width: widget.size * 0.1,
        height: widget.size * 0.1,
        child: CircularProgressIndicator(
          strokeWidth: 2,
          valueColor: AlwaysStoppedAnimation<Color>(iconColor),
        ),
      );
    } else if (session.isListening) {
      return Text(
        'Listening',
        style: TextStyle(
          fontSize: widget.size * 0.07,
          color: Colors.green,
          fontWeight: FontWeight.bold,
        ),
      );
    } else if (session.canBroadcast) {
      return Text(
        'Tap to speak',
        style: TextStyle(
          fontSize: widget.size * 0.07,
          color: Colors.grey[600],
          fontWeight: FontWeight.bold,
        ),
      );
    } else if (!session.isConnected) {
      return Text(
        'Reconnect',
        style: TextStyle(
          fontSize: widget.size * 0.065,
          color: Colors.grey[500],
          fontWeight: FontWeight.bold,
        ),
      );
    }
    return const SizedBox.shrink();
  }

  Color _getRingColor(SimplePttSessionState session) {
    switch (session.state) {
      case SimplePttState.idle:
        return session.isConnected ? Colors.orange : Colors.grey;
      case SimplePttState.connecting:
      case SimplePttState.requestingFloor:
        return Colors.orange;
      case SimplePttState.broadcasting:
        return session.isBroadcastTimeWarning ? Colors.red : Colors.orange;
      case SimplePttState.listening:
        return Colors.green;
      case SimplePttState.error:
        return Colors.red;
      case SimplePttState.disconnected:
        return Colors.grey;
    }
  }

  Color _getIconColor(SimplePttSessionState session) {
    switch (session.state) {
      case SimplePttState.idle:
        return session.isConnected ? AppColors.primary : Colors.grey;
      case SimplePttState.connecting:
      case SimplePttState.requestingFloor:
        return Colors.orange;
      case SimplePttState.broadcasting:
        return session.isBroadcastTimeWarning ? Colors.red : Colors.orange;
      case SimplePttState.listening:
        return Colors.green;
      case SimplePttState.error:
        return Colors.red;
      case SimplePttState.disconnected:
        return Colors.grey;
    }
  }

  IconData _getIcon(SimplePttSessionState session) {
    switch (session.state) {
      case SimplePttState.idle:
        return Icons.mic;
      case SimplePttState.connecting:
      case SimplePttState.requestingFloor:
        return Icons.mic;
      case SimplePttState.broadcasting:
        return Icons.stop;
      case SimplePttState.listening:
        return Icons.volume_up;
      case SimplePttState.error:
        return Icons.error_outline;
      case SimplePttState.disconnected:
        return Icons.signal_wifi_off;
    }
  }

  Widget _buildSpeakerIndicator(SimplePttSessionState session) {
    return Container(
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
            session.currentSpeakerName ?? 'User',
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
    );
  }

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
                style: const TextStyle(fontWeight: FontWeight.w500),
              ),
            ),
          ],
        ),
        backgroundColor: Colors.green,
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
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
