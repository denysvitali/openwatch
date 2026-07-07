import 'package:flutter/material.dart';

import '../../core/ui/ui_constants.dart';

/// Default max content width for feature screens.
const double kMaxWidthContainerDefault = 860;

/// Narrower max content width used by the scan screen.
const double kMaxWidthContainerScan = 520;

/// Centers [child] and constrains its width to [maxWidth].
///
/// Use this directly when the child is already scrollable (e.g. a [ListView]
/// or [RefreshIndicator] wrapping one). For non-scrollable content, prefer
/// [CenteredScrollable].
class MaxWidthContainer extends StatelessWidget {
  const MaxWidthContainer({
    super.key,
    this.maxWidth = kMaxWidthContainerDefault,
    required this.child,
  });

  final double maxWidth;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: maxWidth),
        child: child,
      ),
    );
  }
}

/// A centered, width-constrained scrollable wrapper for feature-screen bodies.
///
/// Defaults to [kMaxWidthContainerDefault] (860dp). Use this for screens whose
/// body is a simple column of widgets; for screens that already use a
/// [ListView] or [RefreshIndicator], use [MaxWidthContainer] directly to keep
/// the existing scroll physics.
class CenteredScrollable extends StatelessWidget {
  const CenteredScrollable({
    super.key,
    this.maxWidth = kMaxWidthContainerDefault,
    this.padding,
    this.physics,
    required this.child,
  });

  final double maxWidth;
  final EdgeInsetsGeometry? padding;
  final ScrollPhysics? physics;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      physics: physics,
      padding:
          padding ??
          const EdgeInsets.fromLTRB(
            kScreenPaddingH,
            kScreenPaddingTop,
            kScreenPaddingH,
            kScreenPaddingBottom,
          ),
      child: MaxWidthContainer(maxWidth: maxWidth, child: child),
    );
  }
}
