import 'package:flutter/material.dart';
import 'package:openwatch/core/ui/ui_constants.dart';

/// A section header used to group cards and list rows.
///
/// Horizontal padding [kSectionHeaderPaddingH], top [kSectionHeaderPaddingTop],
/// bottom [kSectionHeaderPaddingBottom]. Title uses [kHeadlineSmall].
/// An optional "Show All" text button can be provided.
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
      padding: const EdgeInsets.fromLTRB(
        kSectionHeaderPaddingH,
        kSectionHeaderPaddingTop,
        kSectionHeaderPaddingH,
        kSectionHeaderPaddingBottom,
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              title,
              style: AppTextStyles.headlineSmall(context),
            ),
          ),
          if (onShowAll != null)
            TextButton(
              onPressed: onShowAll,
              child: Text(
                actionLabel,
                style: AppTextStyles.labelSmall(context)?.copyWith(
                  color: theme.colorScheme.primary,
                ),
              ),
            ),
        ],
      ),
    );
  }
}
