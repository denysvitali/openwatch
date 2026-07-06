import 'package:flutter/material.dart';

/// A section header used to group cards and list rows.
///
/// Top padding 24dp, bottom 8dp, horizontal 18dp. Title uses the page-title
/// style at 22sp. An optional "Show All" text button can be provided.
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
      padding: const EdgeInsets.fromLTRB(18, 24, 18, 8),
      child: Row(
        children: [
          Expanded(
            child: Text(
              title,
              style: theme.textTheme.headlineSmall?.copyWith(fontSize: 22),
            ),
          ),
          if (onShowAll != null)
            TextButton(
              onPressed: onShowAll,
              child: Text(
                actionLabel,
                style: theme.textTheme.labelSmall?.copyWith(
                  color: theme.colorScheme.primary,
                ),
              ),
            ),
        ],
      ),
    );
  }
}
