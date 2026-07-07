import 'package:flutter/material.dart';
import 'package:openwatch/core/ui/ui_constants.dart';

/// A compact health metric card used throughout the refreshed OpenWatch UI.
///
/// The card follows the design system: [kCardRadius] radius, [kCardPadding]
/// padding, a subtle metric-tinted gradient background, a small circular
/// leading icon, a compact value/unit pair, caption, and an optional trailing
/// widget.
class HealthCard extends StatelessWidget {
  const HealthCard({
    super.key,
    this.title,
    this.value,
    this.unit,
    this.caption,
    this.icon,
    this.metricColor,
    this.trailing,
    this.gradient,
    this.elevated = false,
    this.onTap,
    this.child,
    this.padding = const EdgeInsets.all(kCardPadding),
  });

  final String? title;
  final String? value;
  final String? unit;
  final String? caption;
  final IconData? icon;
  final Color? metricColor;
  final Widget? trailing;
  final Gradient? gradient;
  final bool elevated;
  final VoidCallback? onTap;
  final Widget? child;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = metricColor ?? theme.colorScheme.primary;
    final effectiveGradient = gradient ?? _defaultGradient(color);

    Widget content = Padding(
      padding: padding,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (title != null || icon != null || trailing != null)
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (icon != null) ...[
                  Container(
                    width: kIconCircleSizeSmall,
                    height: kIconCircleSizeSmall,
                    decoration: BoxDecoration(
                      color: color.withValues(alpha: kMetricTintOpacity),
                      shape: BoxShape.circle,
                    ),
                    alignment: Alignment.center,
                    child: Icon(icon, size: kIconSizeSmall, color: color),
                  ),
                  const SizedBox(width: kGridSpacing),
                ],
                if (title != null)
                  Expanded(
                    child: Text(
                      title!,
                      style: AppTextStyles.titleMedium(context),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                if (trailing != null)
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 40),
                    child: trailing,
                  ),
              ],
            ),
          if (title != null || icon != null || trailing != null)
            const SizedBox(height: kSpacingSmall),
          if (value != null || unit != null)
            Row(
              crossAxisAlignment: CrossAxisAlignment.baseline,
              textBaseline: TextBaseline.alphabetic,
              children: [
                if (value != null)
                  Text(value!, style: AppTextStyles.headlineSmall(context)),
                if (value != null && unit != null)
                  const SizedBox(width: kSpacingTiny),
                if (unit != null)
                  Text(
                    unit!,
                    style: AppTextStyles.labelMedium(
                      context,
                    )?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                  ),
              ],
            ),
          if (caption != null) ...[
            const SizedBox(height: kSpacingTiny),
            Text(
              caption!,
              style: AppTextStyles.bodySmall(context),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ],
          child ?? const SizedBox.shrink(),
        ],
      ),
    );

    if (onTap != null) {
      content = InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(kCardRadius),
        child: content,
      );
    }

    return Card(
      margin: EdgeInsets.zero,
      elevation: elevated ? 2 : 0,
      child: Container(
        decoration: BoxDecoration(
          gradient: effectiveGradient,
          borderRadius: BorderRadius.circular(kCardRadius),
        ),
        child: content,
      ),
    );
  }

  static Gradient _defaultGradient(Color color) {
    return LinearGradient(
      begin: Alignment.topLeft,
      end: Alignment.bottomRight,
      colors: [
        color.withValues(alpha: kCardGradientOpacityStart),
        color.withValues(alpha: kCardGradientOpacityEnd),
      ],
    );
  }
}
