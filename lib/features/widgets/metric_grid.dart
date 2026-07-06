import 'package:flutter/material.dart';

/// A responsive metric grid that wraps [HealthCard]-style tiles.
///
/// Uses a [GridView.extent] layout so tiles reflow naturally while honoring
/// the design system's 220dp max cross-axis extent, 12dp spacing, and 1.45
/// child aspect ratio.
class MetricGrid extends StatelessWidget {
  const MetricGrid({
    super.key,
    required this.children,
    this.shrinkWrap = true,
    this.physics = const NeverScrollableScrollPhysics(),
    this.crossAxisSpacing = 12,
    this.mainAxisSpacing = 12,
    this.childAspectRatio = 1.45,
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
