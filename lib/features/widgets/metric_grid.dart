import 'package:flutter/material.dart';
import 'package:openwatch/core/ui/ui_constants.dart';

/// A responsive metric grid that wraps [HealthCard]-style tiles.
///
/// Uses a [GridView.extent] layout so tiles reflow naturally while honoring
/// the design system's 220dp max cross-axis extent, [kGridSpacing] spacing,
/// and [kGridChildAspectRatio] child aspect ratio.
class MetricGrid extends StatelessWidget {
  const MetricGrid({
    super.key,
    required this.children,
    this.shrinkWrap = true,
    this.physics = const NeverScrollableScrollPhysics(),
    this.crossAxisSpacing = kGridSpacing,
    this.mainAxisSpacing = kGridSpacing,
    this.childAspectRatio = kGridChildAspectRatio,
    this.maxCrossAxisExtent = 220,
    this.padding,
  });

  final List<Widget> children;
  final bool shrinkWrap;
  final ScrollPhysics physics;
  final double crossAxisSpacing;
  final double mainAxisSpacing;
  final double childAspectRatio;
  final double maxCrossAxisExtent;
  final EdgeInsetsGeometry? padding;

  @override
  Widget build(BuildContext context) {
    return GridView.extent(
      maxCrossAxisExtent: maxCrossAxisExtent,
      crossAxisSpacing: crossAxisSpacing,
      mainAxisSpacing: mainAxisSpacing,
      childAspectRatio: childAspectRatio,
      shrinkWrap: shrinkWrap,
      physics: physics,
      padding: padding,
      children: children,
    );
  }
}
