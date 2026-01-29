import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../../core/theme/app_colors.dart';

enum PttState { idle, requesting, transmitting, receiving }

class PttButton extends StatefulWidget {
  final String channelId;
  final VoidCallback? onPttStart;
  final VoidCallback? onPttEnd;

  const PttButton({
    super.key,
    required this.channelId,
    this.onPttStart,
    this.onPttEnd,
  });

  @override
  State<PttButton> createState() => _PttButtonState();
}

class _PttButtonState extends State<PttButton>
    with SingleTickerProviderStateMixin {
  PttState _state = PttState.idle;
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

  void _startPtt() {
    HapticFeedback.heavyImpact();
    setState(() => _state = PttState.transmitting);
    _pulseController.repeat(reverse: true);
    widget.onPttStart?.call();
  }

  void _endPtt() {
    HapticFeedback.lightImpact();
    setState(() => _state = PttState.idle);
    _pulseController.stop();
    _pulseController.reset();
    widget.onPttEnd?.call();
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTapDown: (_) => _startPtt(),
      onTapUp: (_) => _endPtt(),
      onTapCancel: () => _endPtt(),
      child: AnimatedBuilder(
        animation: _pulseAnimation,
        builder: (context, child) {
          return Transform.scale(
            scale: _state == PttState.transmitting ? _pulseAnimation.value : 1.0,
            child: child,
          );
        },
        child: Container(
          width: 100,
          height: 100,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: _getButtonColor(),
            boxShadow: [
              BoxShadow(
                color: _getButtonColor().withValues(alpha: 0.4),
                blurRadius: _state == PttState.transmitting ? 24 : 12,
                spreadRadius: _state == PttState.transmitting ? 4 : 0,
              ),
            ],
          ),
          child: Stack(
            alignment: Alignment.center,
            children: [
              // Outer ring for receiving state
              if (_state == PttState.receiving)
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
                    _getIcon(),
                    size: 40,
                    color: _getIconColor(),
                  ),
                  if (_state == PttState.transmitting) ...[
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

  Color _getButtonColor() {
    switch (_state) {
      case PttState.idle:
        return AppColors.pttIdle;
      case PttState.requesting:
        return AppColors.pttWaiting;
      case PttState.transmitting:
        return AppColors.pttActive;
      case PttState.receiving:
        return AppColors.pttReceiving;
    }
  }

  Color _getIconColor() {
    switch (_state) {
      case PttState.idle:
        return AppColors.textSecondaryDark;
      case PttState.requesting:
      case PttState.transmitting:
      case PttState.receiving:
        return Colors.white;
    }
  }

  IconData _getIcon() {
    switch (_state) {
      case PttState.idle:
        return Icons.mic_none;
      case PttState.requesting:
        return Icons.hourglass_empty;
      case PttState.transmitting:
        return Icons.mic;
      case PttState.receiving:
        return Icons.volume_up;
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
