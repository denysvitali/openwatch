import 'package:flutter/material.dart';

import '../../../core/ui/ui_constants.dart';

class ChartZoomControls extends StatelessWidget {
  const ChartZoomControls({
    super.key,
    required this.onZoomIn,
    required this.onZoomOut,
    required this.onReset,
    this.canZoomIn = true,
    this.canZoomOut = true,
    this.canReset = true,
  });

  final VoidCallback? onZoomIn;
  final VoidCallback? onZoomOut;
  final VoidCallback? onReset;
  final bool canZoomIn;
  final bool canZoomOut;
  final bool canReset;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: theme.colorScheme.surface.withValues(alpha: 0.84),
        borderRadius: BorderRadius.circular(kChipRadius),
        border: Border.all(color: theme.colorScheme.outlineVariant),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _ChartIconButton(
            icon: Icons.remove_rounded,
            tooltip: 'Zoom out',
            onPressed: canZoomOut ? onZoomOut : null,
          ),
          _ChartIconButton(
            icon: Icons.center_focus_strong_rounded,
            tooltip: 'Reset view',
            onPressed: canReset ? onReset : null,
          ),
          _ChartIconButton(
            icon: Icons.add_rounded,
            tooltip: 'Zoom in',
            onPressed: canZoomIn ? onZoomIn : null,
          ),
        ],
      ),
    );
  }
}

class _ChartIconButton extends StatelessWidget {
  const _ChartIconButton({
    required this.icon,
    required this.tooltip,
    required this.onPressed,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 34,
      height: 32,
      child: IconButton(
        padding: EdgeInsets.zero,
        iconSize: 18,
        tooltip: tooltip,
        icon: Icon(icon),
        onPressed: onPressed,
      ),
    );
  }
}
