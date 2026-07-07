import 'package:flutter/material.dart';
import 'package:openwatch/core/ui/ui_constants.dart';

/// Standardized loading spinner sizes used throughout OpenWatch.
///
/// Each size has a fixed diameter and stroke width so the UI no longer mixes
/// ad-hoc 20dp/28dp/default spinners.
enum AppLoadingIndicatorSize { small, medium, large }

/// A deterministic [CircularProgressIndicator] wrapper.
///
/// Defaults to [AppLoadingIndicatorSize.medium] (28dp diameter, 3dp stroke).
class AppLoadingIndicator extends StatelessWidget {
  const AppLoadingIndicator({
    super.key,
    this.size = AppLoadingIndicatorSize.medium,
    this.color,
  });

  final AppLoadingIndicatorSize size;
  final Color? color;

  static const _diameters = <AppLoadingIndicatorSize, double>{
    AppLoadingIndicatorSize.small: kIconSizeSmall,
    AppLoadingIndicatorSize.medium: kIconSizeLarge,
    AppLoadingIndicatorSize.large: kIconCircleSizeLarge,
  };

  static const _strokeWidths = <AppLoadingIndicatorSize, double>{
    AppLoadingIndicatorSize.small: 2,
    AppLoadingIndicatorSize.medium: 3,
    AppLoadingIndicatorSize.large: 4,
  };

  @override
  Widget build(BuildContext context) {
    final diameter = _diameters[size]!;
    return SizedBox(
      width: diameter,
      height: diameter,
      child: CircularProgressIndicator(
        strokeWidth: _strokeWidths[size]!,
        color: color ?? Theme.of(context).colorScheme.primary,
      ),
    );
  }
}

/// A loading skeleton shaped like a [HealthCard].
///
/// Use while metric data is being fetched so the dashboard metric grid and
/// history overview keep a consistent silhouette.
class HealthCardLoading extends StatelessWidget {
  const HealthCardLoading({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = theme.colorScheme.onSurface;
    final shimmer = color.withValues(alpha: 0.08);

    Widget placeholder(double width, double height) => Container(
      width: width,
      height: height,
      decoration: BoxDecoration(
        color: shimmer,
        borderRadius: BorderRadius.circular(kChipRadius),
      ),
    );

    return Card(
      clipBehavior: Clip.antiAlias,
      margin: EdgeInsets.zero,
      elevation: 0,
      child: Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [
              theme.colorScheme.primary.withValues(
                alpha: kCardGradientOpacityStart,
              ),
              theme.colorScheme.primary.withValues(
                alpha: kCardGradientOpacityEnd,
              ),
            ],
          ),
          borderRadius: BorderRadius.circular(kCardRadius),
        ),
        child: Padding(
          padding: const EdgeInsets.all(kCardPadding),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  Container(
                    width: kIconCircleSizeSmall,
                    height: kIconCircleSizeSmall,
                    decoration: BoxDecoration(
                      color: shimmer,
                      shape: BoxShape.circle,
                    ),
                  ),
                  const SizedBox(width: kGridSpacing),
                  Expanded(
                    child: placeholder(double.infinity, kSpacingSmall + 8),
                  ),
                ],
              ),
              const SizedBox(height: kSpacingSmall),
              placeholder(80, kHeadlineSmall),
              const SizedBox(height: kSpacingTiny),
              placeholder(120, kBodySmall),
            ],
          ),
        ),
      ),
    );
  }
}
