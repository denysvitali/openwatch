import 'package:flutter/material.dart';

/// A rounded health metric card used throughout the refreshed OpenWatch UI.
///
/// The card follows the design system: 20dp radius, 18dp padding, an optional
/// metric-tinted gradient background, a circular leading icon, hero-style
/// value/unit pair, caption, and an optional trailing widget.
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
    this.padding = const EdgeInsets.all(18),
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
                    width: 48,
                    height: 48,
                    decoration: BoxDecoration(
                      color: color.withValues(alpha: 0.14),
                      shape: BoxShape.circle,
                    ),
                    alignment: Alignment.center,
                    child: Icon(icon, size: 28, color: color),
                  ),
                  const SizedBox(width: 14),
                ],
                if (title != null)
                  Expanded(
                    child: Text(
                      title!,
                      style: theme.textTheme.titleLarge,
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
            const SizedBox(height: 12),
          if (value != null || unit != null)
            Row(
              crossAxisAlignment: CrossAxisAlignment.baseline,
              textBaseline: TextBaseline.alphabetic,
              children: [
                if (value != null)
                  Text(value!, style: theme.textTheme.headlineMedium),
                if (value != null && unit != null) const SizedBox(width: 4),
                if (unit != null)
                  Text(
                    unit!,
                    style: theme.textTheme.labelMedium?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
              ],
            ),
          if (caption != null) ...[
            const SizedBox(height: 6),
            Text(
              caption!,
              style: theme.textTheme.bodySmall,
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
        borderRadius: BorderRadius.circular(20),
        child: content,
      );
    }

    return Card(
      margin: EdgeInsets.zero,
      child: Container(
        decoration: BoxDecoration(
          gradient: effectiveGradient,
          borderRadius: BorderRadius.circular(20),
          boxShadow: elevated
              ? [
                  BoxShadow(
                    color: theme.colorScheme.primary.withValues(alpha: 0.08),
                    blurRadius: 16,
                    offset: const Offset(0, 6),
                  ),
                ]
              : null,
        ),
        child: content,
      ),
    );
  }

  static Gradient _defaultGradient(Color color) {
    return LinearGradient(
      begin: Alignment.topLeft,
      end: Alignment.bottomRight,
      colors: [color.withValues(alpha: 0.14), color.withValues(alpha: 0.06)],
    );
  }
}
