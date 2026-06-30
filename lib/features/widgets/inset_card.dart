import 'package:flutter/material.dart';

/// A [Card] wrapping its [child] in [padding]. Shared layout primitive
/// between the dashboard and history screens.
class InsetCard extends StatelessWidget {
  const InsetCard({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(16),
  });

  final Widget child;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(padding: padding, child: child),
    );
  }
}
