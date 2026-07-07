import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../../core/ui/ui_constants.dart';

/// A Cupertino-informed list row used for health metrics and settings rows.
///
/// Features a circular leading icon tinted with the metric color, title /
/// subtitle, a trailing value+unit+chevron row, and an optional indented
/// divider. A dedicated [control] slot is provided for switches, dropdowns,
/// and other controls that should be baseline-aligned with the title.
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
    this.control,
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
  final Widget? control;
  final VoidCallback? onTap;
  final bool showDivider;
  final EdgeInsetsGeometry contentPadding;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = leadingColor ?? theme.colorScheme.primary;

    final Widget? controlWidget = control ?? _controlFromTrailing(trailing);
    final Widget? trailingWidget = controlWidget == null ? trailing : null;

    Widget tile = Padding(
      padding: contentPadding,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          if (leadingIcon != null)
            Container(
              width: kIconCircleSizeListTile,
              height: kIconCircleSizeListTile,
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
                  const SizedBox(height: kSpacingMini),
                  Text(subtitle!, style: AppTextStyles.bodySmall(context)),
                ],
              ],
            ),
          ),
          if (controlWidget != null)
            Baseline(
              baseline:
                  AppTextStyles.bodyMedium(context)?.fontSize ?? kBodyMedium,
              baselineType: TextBaseline.alphabetic,
              child: controlWidget,
            )
          else
            _buildTrailing(context, trailingWidget),
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
            indent: kListTilePaddingH + kIconCircleSizeListTile + kGridSpacing,
            height: 1,
            thickness: 1,
            color: theme.dividerColor,
          ),
      ],
    );
  }

  Widget _buildTrailing(BuildContext context, Widget? trailingWidget) {
    final theme = Theme.of(context);
    if (trailingWidget != null) return trailingWidget;
    if (value == null && unit == null) return const SizedBox.shrink();
    return Row(
      crossAxisAlignment: CrossAxisAlignment.baseline,
      textBaseline: TextBaseline.alphabetic,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (value != null)
          Text(
            value!,
            style: AppTextStyles.titleLarge(
              context,
            )?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
        if (value != null && unit != null) const SizedBox(width: kSpacingTiny),
        if (unit != null) Text(unit!, style: AppTextStyles.bodySmall(context)),
        const SizedBox(width: kSpacingTiny),
        Icon(
          CupertinoIcons.chevron_forward,
          size: kIconSizeSmall,
          color: theme.colorScheme.onSurfaceVariant,
        ),
      ],
    );
  }

  /// Returns [trailing] if it is a control widget that should be baseline
  /// aligned with the title, otherwise `null`. This lets existing callers pass
  /// a [Switch] or [DropdownButton] as [trailing] without breaking the
  /// baseline contract.
  Widget? _controlFromTrailing(Widget? widget) {
    if (widget == null) return null;
    if (widget is Switch || widget is Checkbox || widget is DropdownButton) {
      return widget;
    }
    return null;
  }
}
