import 'package:flutter/material.dart';

import '../../core/ui/ui_constants.dart';

/// Amber info strip for experimental / contributor-only tools.
class ExperimentalBanner extends StatelessWidget {
  const ExperimentalBanner({
    super.key,
    required this.message,
    this.icon = Icons.science_outlined,
  });

  final String message;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final amber = theme.colorScheme.tertiary;

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(
        horizontal: kCardPadding,
        vertical: kListTilePaddingV,
      ),
      decoration: BoxDecoration(
        color: amber.withValues(alpha: kPillTintOpacity),
        borderRadius: BorderRadius.circular(kCardRadius),
        border: Border.all(color: amber.withValues(alpha: 0.35)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: kIconSizeSmall, color: amber),
          const SizedBox(width: kGridSpacing),
          Expanded(
            child: Text(
              message,
              style: AppTextStyles.bodySmall(
                context,
              )?.copyWith(color: theme.colorScheme.onSurface, height: 1.35),
            ),
          ),
        ],
      ),
    );
  }
}
