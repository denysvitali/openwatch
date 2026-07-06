import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

/// A pulsing heart badge used to indicate an active heart-rate measurement.
///
/// Scales between 1.0 and 1.18 over 900ms with an ease-in-out curve.
class AnimatedHeartBadge extends StatefulWidget {
  const AnimatedHeartBadge({
    super.key,
    this.color,
    this.size = 48,
    this.iconSize = 28,
    this.isAnimating = true,
  });

  final Color? color;
  final double size;
  final double iconSize;
  final bool isAnimating;

  @override
  State<AnimatedHeartBadge> createState() => _AnimatedHeartBadgeState();
}

class _AnimatedHeartBadgeState extends State<AnimatedHeartBadge>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<double> _scale;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      duration: const Duration(milliseconds: 900),
      vsync: this,
    );
    _scale = TweenSequence<double>([
      TweenSequenceItem(tween: Tween(begin: 1.0, end: 1.18), weight: 1),
      TweenSequenceItem(tween: Tween(begin: 1.18, end: 1.0), weight: 1),
    ]).animate(CurvedAnimation(parent: _controller, curve: Curves.easeInOut));

    if (widget.isAnimating) {
      _controller.repeat();
    }
  }

  @override
  void didUpdateWidget(covariant AnimatedHeartBadge oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.isAnimating && !_controller.isAnimating) {
      _controller.repeat();
    } else if (!widget.isAnimating && _controller.isAnimating) {
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
    final theme = Theme.of(context);
    final color = widget.color ?? theme.colorScheme.error;

    return ScaleTransition(
      scale: _scale,
      child: Container(
        width: widget.size,
        height: widget.size,
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.14),
          shape: BoxShape.circle,
        ),
        alignment: Alignment.center,
        child: Icon(
          CupertinoIcons.heart_fill,
          size: widget.iconSize,
          color: color,
        ),
      ),
    );
  }
}
