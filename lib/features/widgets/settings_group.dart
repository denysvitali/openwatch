import 'package:flutter/material.dart';

import '../../core/ui/ui_constants.dart';
import 'health_list_tile.dart';
import 'health_section_header.dart';
import 'inset_card.dart';

/// Standard settings section: optional [HealthSectionHeader] + padded [InsetCard].
///
/// Keeps Settings, Preferences, Sensors, Alarms, and Notifications on one
/// visual language for grouped lists.
class SettingsGroup extends StatelessWidget {
  const SettingsGroup({
    super.key,
    this.title,
    required this.children,
    this.cardPadding = EdgeInsets.zero,
    this.showHeader = true,
  });

  final String? title;
  final List<Widget> children;
  final EdgeInsetsGeometry cardPadding;
  final bool showHeader;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (showHeader && title != null)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: kCardPadding),
            child: HealthSectionHeader(title: title!),
          ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: kCardPadding),
          child: InsetCard(
            padding: cardPadding,
            child: Column(mainAxisSize: MainAxisSize.min, children: children),
          ),
        ),
      ],
    );
  }
}

/// Shared switch row used across Settings-family screens.
class SettingsSwitchTile extends StatelessWidget {
  const SettingsSwitchTile({
    super.key,
    required this.title,
    this.subtitle,
    this.icon,
    this.iconColor,
    required this.value,
    required this.onChanged,
    this.showDivider = true,
  });

  final String title;
  final String? subtitle;
  final IconData? icon;
  final Color? iconColor;
  final bool value;
  final ValueChanged<bool>? onChanged;
  final bool showDivider;

  @override
  Widget build(BuildContext context) {
    return HealthListTile(
      title: title,
      subtitle: subtitle,
      leadingIcon: icon,
      leadingColor: iconColor,
      control: Switch.adaptive(value: value, onChanged: onChanged),
      onTap: onChanged == null ? null : () => onChanged!(!value),
      showDivider: showDivider,
    );
  }
}
