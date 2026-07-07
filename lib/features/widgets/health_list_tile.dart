import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../../core/ui/ui_constants.dart';

/// A Cupertino-informed list row used for health metrics and settings rows.
///
/// Features a circular leading icon tinted with the metric color, title /
/// subtitle, a trailing value+unit+chevron row, and an optional indented
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
      horizontal: kListTilePaddingH,
      vertical: kListTilePaddingV,
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
              width: kIconCircleSizeSmall,
              height: kIconCircleSizeSmall,
              decoration: BoxDecoration(
                color: color.withValues(alpha: kMetricTintOpacity),
                shape: BoxShape.circle,
              ),
              alignment: Alignment.center,
              child: Icon(leadingIcon, size: kIconSizeTiny, color: color),
            ),
          if (leadingIcon != null) const SizedBox(width: kGridSpacing),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  title,
                  style: AppTextStyles.bodyMedium(
                    context,
                  )?.copyWith(fontWeight: FontWeight.w600),
                ),
                if (subtitle != null) ...[
                  const SizedBox(height: 2),
                  Text(subtitle!, style: AppTextStyles.bodySmall(context)),
                ],
              ],
            ),
          ),
          _buildTrailing(context),
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
            indent: kListTilePaddingH + kIconCircleSizeSmall,
            height: 1,
            thickness: 1,
            color: theme.dividerColor,
          ),
      ],
    );
  }

  Widget _buildTrailing(BuildContext context) {
    final theme = Theme.of(context);
    if (trailing != null) return trailing!;
    if (value == null && unit == null) return const SizedBox.shrink();
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (value != null)
          Text(
            value!,
            style: AppTextStyles.titleLarge(
              context,
            )?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
        if (value != null && unit != null) const SizedBox(width: 4),
        if (unit != null) Text(unit!, style: AppTextStyles.bodySmall(context)),
        const SizedBox(width: 4),
        Icon(
          CupertinoIcons.chevron_forward,
          size: kIconSizeSmall,
          color: theme.colorScheme.onSurfaceVariant,
        ),
      ],
    );
  }
}
