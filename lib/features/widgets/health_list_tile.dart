import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

/// A Cupertino-informed list row used for health metrics and settings rows.
///
/// Features a circular leading icon tinted with the metric color, title /
/// subtitle, a trailing value+unit+chevron row, and an optional 56dp-indented
/// divider.
class HealthListTile extends StatelessWidget {
  const HealthListTile({
    super.key,
    required this.title,
    this.subtitle,
    this.value,
    this.unit,
    this.leadingIcon,
    this.leadingColor,
    this.trailing,
    this.onTap,
    this.showDivider = true,
    this.contentPadding = const EdgeInsets.symmetric(
      horizontal: 18,
      vertical: 16,
    ),
  });

  final String title;
  final String? subtitle;
  final String? value;
  final String? unit;
  final IconData? leadingIcon;
  final Color? leadingColor;
  final Widget? trailing;
  final VoidCallback? onTap;
  final bool showDivider;
  final EdgeInsetsGeometry contentPadding;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = leadingColor ?? theme.colorScheme.primary;

    Widget tile = Padding(
      padding: contentPadding,
      child: Row(
        children: [
          if (leadingIcon != null)
            Container(
              width: 38,
              height: 38,
              decoration: BoxDecoration(
                color: color.withValues(alpha: 0.14),
                shape: BoxShape.circle,
              ),
              alignment: Alignment.center,
              child: Icon(leadingIcon, size: 20, color: color),
            ),
          if (leadingIcon != null) const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  title,
                  style: theme.textTheme.bodyLarge?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
                if (subtitle != null) ...[
                  const SizedBox(height: 2),
                  Text(subtitle!, style: theme.textTheme.bodySmall),
                ],
              ],
            ),
          ),
          _buildTrailing(theme),
        ],
      ),
    );

    if (onTap != null) {
      tile = InkWell(onTap: onTap, child: tile);
    }

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        tile,
        if (showDivider)
          Divider(
            indent: 56,
            height: 1,
            thickness: 1,
            color: theme.dividerColor,
          ),
      ],
    );
  }

  Widget _buildTrailing(ThemeData theme) {
    if (trailing != null) return trailing!;
    if (value == null && unit == null) return const SizedBox.shrink();
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (value != null)
          Text(
            value!,
            style: theme.textTheme.headlineMedium?.copyWith(
              fontSize: 20,
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        if (value != null && unit != null) const SizedBox(width: 4),
        if (unit != null) Text(unit!, style: theme.textTheme.bodySmall),
        const SizedBox(width: 4),
        Icon(
          CupertinoIcons.chevron_forward,
          size: 20,
          color: theme.colorScheme.onSurfaceVariant,
        ),
      ],
    );
  }
}
