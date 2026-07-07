import 'package:flutter/material.dart';
import 'package:openwatch/core/ui/ui_constants.dart';

/// A centered empty-state illustration used throughout the app.
///
/// Shows a large tinted circle containing an icon, followed by a title, an
/// optional caption, and an optional action widget (typically a button).
/// All dimensions and colors come from [ui_constants.dart].
class EmptyState extends StatelessWidget {
  const EmptyState({
    super.key,
    required this.icon,
    required this.title,
    this.caption,
    this.action,
    this.iconColor,
  });

  final IconData icon;
  final String title;
  final String? caption;
  final Widget? action;
  final Color? iconColor;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = iconColor ?? theme.colorScheme.primary;

    return Center(
      child: Padding(
        padding: const EdgeInsets.all(kEmptyStatePadding),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: kIconCircleSizeLarge + kSpacingSmall * 4,
              height: kIconCircleSizeLarge + kSpacingSmall * 4,
              decoration: BoxDecoration(
                color: color.withValues(alpha: kMetricTintOpacity),
                shape: BoxShape.circle,
              ),
              alignment: Alignment.center,
              child: Icon(icon, size: kIconSizeLarge, color: color),
            ),
            const SizedBox(height: kCardInternalSpacing),
            Text(
              title,
              style: AppTextStyles.titleMedium(context),
              textAlign: TextAlign.center,
            ),
            if (caption != null) ...[
              const SizedBox(height: kSpacingTiny),
              Text(
                caption!,
                style: AppTextStyles.bodySmall(context)?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
                textAlign: TextAlign.center,
              ),
            ],
            if (action != null) ...[
              const SizedBox(height: kCardInternalSpacing),
              action!,
            ],
          ],
        ),
      ),
    );
  }
}
