import 'package:flutter/material.dart';

import '../../core/ui/ui_constants.dart';

/// A [Card] wrapping its [child] in [padding]. Shared layout primitive
/// between the dashboard and history screens.
class InsetCard extends StatelessWidget {
  const InsetCard({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(kCardPadding),
  });

  final Widget child;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    return Card(
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(kCardRadius),
      ),
      child: Padding(padding: padding, child: child),
    );
  }
}
