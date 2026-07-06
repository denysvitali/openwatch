import 'package:flutter/material.dart';

/// The primary call-to-action button used across health screens.
///
/// Minimum height 54dp, 16dp border radius, primary-accent background, white
/// foreground, optional leading icon, and a soft matching shadow.
class PrimaryHealthButton extends StatelessWidget {
  const PrimaryHealthButton({
    super.key,
    required this.label,
    this.icon,
    this.onPressed,
    this.elevated = true,
  });

  final String label;
  final IconData? icon;
  final VoidCallback? onPressed;
  final bool elevated;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final primary = theme.colorScheme.primary;

    return FilledButton.icon(
      onPressed: onPressed,
      icon: icon != null
          ? SizedBox(
              width: 48,
              child: Icon(icon, size: 24, color: theme.colorScheme.onPrimary),
            )
          : const SizedBox.shrink(),
      label: Text(label),
      style: FilledButton.styleFrom(
        minimumSize: const Size(0, 54),
        padding: const EdgeInsets.symmetric(horizontal: 24),
        backgroundColor: primary,
        foregroundColor: theme.colorScheme.onPrimary,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        shadowColor: elevated
            ? primary.withValues(alpha: 0.16)
            : Colors.transparent,
        elevation: elevated ? 4 : 0,
        textStyle: theme.textTheme.labelLarge?.copyWith(
          fontSize: 16,
          fontWeight: FontWeight.w600,
          height: 1.25,
          color: theme.colorScheme.onPrimary,
        ),
      ),
    );
  }
}
