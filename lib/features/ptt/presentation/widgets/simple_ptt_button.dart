import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/services/hardware_ptt_service.dart';
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
    with TickerProviderStateMixin {
  late AnimationController _pulseController;
  late Animation<double> _pulseAnimation;
  late AnimationController _pressController;
  late Animation<double> _pressAnimation;
  String? _lastSpeakerId;
  StreamSubscription<PttEvent>? _hardwarePttSubscription;
  bool _isPressed = false;

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
    _pressController.dispose();
    _hardwarePttSubscription?.cancel();
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

  void _onTapToggle() async {
    // Reset press animation
    _onTapUp(null);

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

      // Wake up screen if it's off (for software PTT press)
      HardwarePttService.wakeScreen();

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
    final isActive =
        session.isBroadcasting || session.state == SimplePttState.requestingFloor;
    final isListening = session.isListening;
    final isError = session.state == SimplePttState.error;
    final isDisconnected = !session.isConnected && !session.isConnecting;

    // Professional dark theme colors
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
                // Main icon - larger, no text
                Icon(
                  _getIcon(session),
                  size: widget.size * 0.32,
                  color: iconColor,
                ),
                // Small status indicator below icon
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
                ] else if (session.state == SimplePttState.requestingFloor) ...[
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
                      '${session.listenerCount}',
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
    const greenAccent = Color(0xFF4CAF50);

    return Container(
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
            session.currentSpeakerName ?? 'User',
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
