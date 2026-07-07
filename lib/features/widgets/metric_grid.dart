import 'package:flutter/material.dart';
import 'package:openwatch/core/ui/ui_constants.dart';

/// A responsive metric grid that wraps [HealthCard]-style tiles.
///
/// Uses a [Wrap] layout so tiles take their intrinsic height while still
/// reflowing across the available width. The [maxCrossAxisExtent] is applied
/// as a max-width constraint on each child; [crossAxisSpacing] and
/// [mainAxisSpacing] map to Wrap's spacing and runSpacing, respectively.
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
    final wrap = Wrap(
      spacing: crossAxisSpacing,
      runSpacing: mainAxisSpacing,
      alignment: WrapAlignment.start,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: children
          .map(
            (child) => ConstrainedBox(
              constraints: BoxConstraints(maxWidth: maxCrossAxisExtent),
              child: child,
            ),
          )
          .toList(),
    );

    if (padding != null) {
      return Padding(padding: padding!, child: wrap);
    }
    return wrap;
  }
}
