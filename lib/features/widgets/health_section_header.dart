import 'package:flutter/material.dart';
import 'package:openwatch/core/ui/ui_constants.dart';

/// Section header for grouping cards and list rows.
///
/// Only applies **vertical** padding so horizontal alignment matches the parent
/// list's [kCardPadding] / [kScreenPaddingH]. Optional action button on the right.
class HealthSectionHeader extends StatelessWidget {
  const HealthSectionHeader({
    super.key,
    required this.title,
    this.onShowAll,
    this.actionLabel = 'Show All',
  });

  final String title;
  final VoidCallback? onShowAll;
  final String actionLabel;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Padding(
      padding: const EdgeInsets.only(
        top: kSectionHeaderPaddingTop,
        bottom: kSectionHeaderPaddingBottom,
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(title, style: AppTextStyles.headlineSmall(context)),
          ),
          if (onShowAll != null)
            TextButton(
              onPressed: onShowAll,
              child: Text(
                actionLabel,
                style: AppTextStyles.labelSmall(
                  context,
                )?.copyWith(color: theme.colorScheme.primary),
              ),
            ),
        ],
      ),
    );
  }
}
