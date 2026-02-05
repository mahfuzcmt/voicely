import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/theme/app_colors.dart';
import '../../../../core/utils/extensions.dart';
import '../../data/audio_recording_service.dart';
import '../../domain/models/ptt_session_model.dart';
import '../providers/audio_providers.dart';
import '../providers/ptt_providers.dart';

class PttButton extends ConsumerStatefulWidget {
  final String channelId;

  const PttButton({
    super.key,
    required this.channelId,
  });

  @override
  ConsumerState<PttButton> createState() => _PttButtonState();
}

class _PttButtonState extends ConsumerState<PttButton>
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

  PttSessionState _getState(PttSessionModel session) {
    return session.state;
  }

  void _forceRelease() async {
    HapticFeedback.heavyImpact();
    await ref.read(pttSessionProvider(widget.channelId).notifier).forceReset();
    if (mounted) {
      context.showSnackBar('Floor released');
    }
  }

  void _startPtt() async {
    final session = ref.read(pttSessionProvider(widget.channelId));

    // Check microphone permission first
    final hasPermission = await ref.read(audioRecordingServiceProvider).hasPermission();
    if (!hasPermission) {
      if (mounted) {
        context.showSnackBar('Microphone permission required');
      }
      return;
    }

    // If stuck in requestingFloor or error state, reset first
    if (session.state == PttSessionState.requestingFloor ||
        session.state == PttSessionState.error) {
      debugPrint('PTT Button - Resetting stuck state: ${session.state}');
      await ref.read(pttSessionProvider(widget.channelId).notifier).forceReset();
      // Small delay to allow state to settle
      await Future.delayed(const Duration(milliseconds: 100));
    }

    HapticFeedback.heavyImpact();
    _pulseController.repeat(reverse: true);

    try {
      // Configure audio and start PTT
      await ref.read(pttAudioStateProvider.notifier).startTransmitting();
      final success =
          await ref.read(pttSessionProvider(widget.channelId).notifier).startPtt();

      if (!success && mounted) {
        _pulseController.stop();
        _pulseController.reset();
        await ref.read(pttAudioStateProvider.notifier).stop();

        final errorSession = ref.read(pttSessionProvider(widget.channelId));
        if (errorSession.errorMessage != null) {
          context.showSnackBar(errorSession.errorMessage!);
          ref
              .read(pttSessionProvider(widget.channelId).notifier)
              .clearError();
        }
      }
    } catch (e) {
      // Handle any unexpected errors
      debugPrint('PTT Button - Exception in startPtt: $e');
      if (mounted) {
        _pulseController.stop();
        _pulseController.reset();
        await ref.read(pttAudioStateProvider.notifier).stop();
        await ref.read(pttSessionProvider(widget.channelId).notifier).forceReset();
        context.showSnackBar('Failed to start PTT');
      }
    }
  }

  void _endPtt() async {
    HapticFeedback.lightImpact();
    _pulseController.stop();
    _pulseController.reset();

    try {
      await ref.read(pttSessionProvider(widget.channelId).notifier).stopPtt();
      await ref.read(pttAudioStateProvider.notifier).stop();
    } catch (e) {
      // Ensure audio is stopped even if stopPtt fails
      await ref.read(pttAudioStateProvider.notifier).stop();
    }
  }

  @override
  Widget build(BuildContext context) {
    final session = ref.watch(pttSessionProvider(widget.channelId));
    final state = _getState(session);

    // Debug logging
    debugPrint('PTT Button - State: $state, canStartPtt: ${session.canStartPtt}');

    // Update pulse animation based on state
    if (state == PttSessionState.transmitting && !_pulseController.isAnimating) {
      _pulseController.repeat(reverse: true);
    } else if (state != PttSessionState.transmitting &&
        _pulseController.isAnimating) {
      _pulseController.stop();
      _pulseController.reset();
    }

    // Configure audio for receiving
    if (state == PttSessionState.receiving) {
      ref.read(pttAudioStateProvider.notifier).startReceiving();
    } else if (state == PttSessionState.idle) {
      ref.read(pttAudioStateProvider.notifier).stop();
    }

    return GestureDetector(
      onLongPress: () {
        // Long press to force release stuck floor
        debugPrint('PTT Button - Long press detected, forcing floor release');
        _forceRelease();
      },
      onTapDown: (_) {
        debugPrint('PTT Button - onTapDown triggered, canStartPtt: ${session.canStartPtt}');
        if (session.canStartPtt) {
          _startPtt();
        } else {
          debugPrint('PTT Button - Cannot start PTT, state is: $state');
        }
      },
      onTapUp: (_) {
        if (state == PttSessionState.transmitting ||
            state == PttSessionState.requestingFloor) {
          _endPtt();
        }
      },
      onTapCancel: () {
        if (state == PttSessionState.transmitting ||
            state == PttSessionState.requestingFloor) {
          _endPtt();
        }
      },
      child: AnimatedBuilder(
        animation: _pulseAnimation,
        builder: (context, child) {
          return Transform.scale(
            scale: state == PttSessionState.transmitting
                ? _pulseAnimation.value
                : 1.0,
            child: child,
          );
        },
        child: Container(
          width: 100,
          height: 100,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: _getButtonColor(state),
            boxShadow: [
              BoxShadow(
                color: _getButtonColor(state).withValues(alpha: 0.4),
                blurRadius: state == PttSessionState.transmitting ? 24 : 12,
                spreadRadius: state == PttSessionState.transmitting ? 4 : 0,
              ),
            ],
          ),
          child: Stack(
            alignment: Alignment.center,
            children: [
              // Outer ring for receiving state
              if (state == PttSessionState.receiving)
                Container(
                  width: 120,
                  height: 120,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    border: Border.all(
                      color: AppColors.pttReceiving,
                      width: 3,
                    ),
                  ),
                ),
              // Inner content
              Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(
                    _getIcon(state),
                    size: 40,
                    color: _getIconColor(state),
                  ),
                  if (state == PttSessionState.transmitting) ...[
                    const SizedBox(height: 4),
                    _buildAudioWave(),
                  ],
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Color _getButtonColor(PttSessionState state) {
    switch (state) {
      case PttSessionState.idle:
        return AppColors.pttIdle;
      case PttSessionState.requestingFloor:
        return AppColors.pttWaiting;
      case PttSessionState.transmitting:
        return AppColors.pttActive;
      case PttSessionState.receiving:
        return AppColors.pttReceiving;
      case PttSessionState.error:
        return AppColors.error;
    }
  }

  Color _getIconColor(PttSessionState state) {
    switch (state) {
      case PttSessionState.idle:
        return AppColors.textSecondaryDark;
      case PttSessionState.requestingFloor:
      case PttSessionState.transmitting:
      case PttSessionState.receiving:
      case PttSessionState.error:
        return Colors.white;
    }
  }

  IconData _getIcon(PttSessionState state) {
    switch (state) {
      case PttSessionState.idle:
        return Icons.mic_none;
      case PttSessionState.requestingFloor:
        return Icons.hourglass_empty;
      case PttSessionState.transmitting:
        return Icons.mic;
      case PttSessionState.receiving:
        return Icons.volume_up;
      case PttSessionState.error:
        return Icons.error_outline;
    }
  }

  Widget _buildAudioWave() {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: List.generate(
        5,
        (index) => _AudioBar(
          delay: index * 100,
        ),
      ),
    );
  }
}

class _AudioBar extends StatefulWidget {
  final int delay;

  const _AudioBar({required this.delay});

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
    _animation = Tween<double>(begin: 4, end: 12).animate(
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
            color: Colors.white,
            borderRadius: BorderRadius.circular(2),
          ),
        );
      },
    );
  }
}
