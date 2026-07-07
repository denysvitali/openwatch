import 'package:flutter/material.dart';
import 'package:openwatch/core/ui/ui_constants.dart';

/// The primary call-to-action button used across health screens.
///
/// Compact height, rounded corners, primary-accent background, white
/// foreground, optional leading icon in a subtle tinted circle, and no colored
/// shadow.
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
    final onPrimary = theme.colorScheme.onPrimary;

    return FilledButton.icon(
      onPressed: onPressed,
      icon: icon != null
          ? Container(
              width: kIconCircleSizeSmall,
              height: kIconCircleSizeSmall,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: onPrimary.withValues(alpha: kMetricTintOpacity),
                shape: BoxShape.circle,
              ),
              child: Icon(icon, size: kIconSizeSmall, color: onPrimary),
            )
          : const SizedBox.shrink(),
      label: Text(label),
      style: FilledButton.styleFrom(
        minimumSize: Size(0, kIconCircleSizeSmall + kListTilePaddingV),
        padding: const EdgeInsets.symmetric(horizontal: kCardPadding),
        backgroundColor: primary,
        foregroundColor: onPrimary,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(kCardRadius),
        ),
        shadowColor: Colors.transparent,
        elevation: elevated ? 2 : 0,
        textStyle: theme.textTheme.labelMedium?.copyWith(
          fontSize: kLabelMedium,
          fontWeight: FontWeight.w600,
          height: 1.25,
          color: onPrimary,
        ),
      ),
    );
  }
}
