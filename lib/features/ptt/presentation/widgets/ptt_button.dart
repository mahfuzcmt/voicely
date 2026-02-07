import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/theme/app_colors.dart';
import '../../../../core/utils/extensions.dart';
import '../providers/ptt_providers.dart';

class PttButton extends ConsumerStatefulWidget {
  final String channelId;
  final double size;

  const PttButton({
    super.key,
    required this.channelId,
    this.size = 120,
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

  void _onPressStart() async {
    final session = ref.read(pttSessionProvider(widget.channelId));

    if (!session.canRecord) {
      if (session.state == PttState.error) {
        ref.read(pttSessionProvider(widget.channelId).notifier).clearError();
      }
      return;
    }

    HapticFeedback.heavyImpact();
    _pulseController.repeat(reverse: true);

    final success = await ref
        .read(pttSessionProvider(widget.channelId).notifier)
        .startRecording();

    if (!success && mounted) {
      _pulseController.stop();
      _pulseController.reset();

      final errorSession = ref.read(pttSessionProvider(widget.channelId));
      if (errorSession.errorMessage != null) {
        context.showSnackBar(errorSession.errorMessage!, isError: true);
        ref.read(pttSessionProvider(widget.channelId).notifier).clearError();
      }
    }
  }

  void _onPressEnd() async {
    final session = ref.read(pttSessionProvider(widget.channelId));

    if (!session.isRecording) return;

    HapticFeedback.lightImpact();
    _pulseController.stop();
    _pulseController.reset();

    final success = await ref
        .read(pttSessionProvider(widget.channelId).notifier)
        .stopRecordingAndSend();

    if (mounted) {
      if (success) {
        context.showSnackBar('Voice message sent!');
      } else {
        final errorSession = ref.read(pttSessionProvider(widget.channelId));
        if (errorSession.errorMessage != null) {
          context.showSnackBar(errorSession.errorMessage!, isError: true);
          ref.read(pttSessionProvider(widget.channelId).notifier).clearError();
        }
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final session = ref.watch(pttSessionProvider(widget.channelId));

    // Update pulse animation based on state
    if (session.isRecording && !_pulseController.isAnimating) {
      _pulseController.repeat(reverse: true);
    } else if (!session.isRecording && _pulseController.isAnimating) {
      _pulseController.stop();
      _pulseController.reset();
    }

    return GestureDetector(
      onTapDown: (_) => _onPressStart(),
      onTapUp: (_) => _onPressEnd(),
      onTapCancel: () {
        if (session.isRecording) {
          ref.read(pttSessionProvider(widget.channelId).notifier).cancelRecording();
          _pulseController.stop();
          _pulseController.reset();
        }
      },
      child: AnimatedBuilder(
        animation: _pulseAnimation,
        builder: (context, child) {
          return Transform.scale(
            scale: session.isRecording ? _pulseAnimation.value : 1.0,
            child: child,
          );
        },
        child: _buildPttButtonDesign(session),
      ),
    );
  }

  Widget _buildPttButtonDesign(PttSessionState session) {
    final ringColor = _getRingColor(session.state);
    final iconColor = _getIconColor(session.state);

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

          // White center with icon
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
                  _getIcon(session.state),
                  size: widget.size * 0.25,
                  color: iconColor,
                ),
                if (session.isRecording) ...[
                  SizedBox(height: widget.size * 0.02),
                  _buildRecordingIndicator(iconColor),
                ],
              ],
            ),
          ),

          // Pulsing overlay when recording
          if (session.isRecording)
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

  Color _getRingColor(PttState state) {
    switch (state) {
      case PttState.idle:
        return Colors.orange;
      case PttState.recording:
        return Colors.red;
      case PttState.uploading:
        return Colors.orange;
      case PttState.error:
        return Colors.red;
    }
  }

  Color _getIconColor(PttState state) {
    switch (state) {
      case PttState.idle:
        return AppColors.primary;
      case PttState.recording:
        return Colors.red;
      case PttState.uploading:
        return Colors.orange;
      case PttState.error:
        return Colors.red;
    }
  }

  Color _getButtonColor(PttState state) {
    switch (state) {
      case PttState.idle:
        return AppColors.primary;
      case PttState.recording:
        return Colors.red;
      case PttState.uploading:
        return Colors.orange;
      case PttState.error:
        return AppColors.error;
    }
  }

  IconData _getIcon(PttState state) {
    switch (state) {
      case PttState.idle:
        return Icons.mic;
      case PttState.recording:
        return Icons.mic;
      case PttState.uploading:
        return Icons.cloud_upload;
      case PttState.error:
        return Icons.error_outline;
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
