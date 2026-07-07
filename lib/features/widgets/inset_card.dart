import 'package:flutter/material.dart';

import '../../core/ui/ui_constants.dart';

/// A flat, edge-to-edge grouped-list surface.
///
/// Defaults to [elevation] 0 and [margin] [EdgeInsets.zero] so it sits flush
/// inside a padded column. Use it for settings, alarms, notifications, and
/// any other screen that groups a list of tiles. Raised metric cards should
/// use HealthCard with elevated true instead.
class InsetCard extends StatelessWidget {
  const InsetCard({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(kCardPadding),
    this.elevation = 0,
    this.margin = EdgeInsets.zero,
  });

  final Widget child;
  final EdgeInsetsGeometry padding;
  final double elevation;
  final EdgeInsetsGeometry? margin;

  @override
  Widget build(BuildContext context) {
    return Card(
      elevation: elevation,
      margin: margin,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(kCardRadius),
      ),
      child: Padding(padding: padding, child: child),
    );
  }
}
