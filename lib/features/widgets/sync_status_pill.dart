import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../core/services/history_sync.dart';
import '../../core/ui/ui_constants.dart';

/// Compact status pill summarizing [HistorySync]'s syncing/error/last-synced
/// state. Shared between the dashboard and history screens.
class SyncStatusPill extends StatelessWidget {
  const SyncStatusPill({super.key, required this.sync});

  final HistorySync sync;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final (label, color, icon) = switch ((
      sync.syncing,
      sync.lastSyncedAt,
      sync.lastSyncError,
    )) {
      (true, _, _) => ('Syncing', theme.colorScheme.primary, Icons.sync),
      (false, _, String _) => (
        'Error',
        theme.colorScheme.error,
        CupertinoIcons.exclamationmark_circle,
      ),
      (false, null, _) => (
        'No sync',
        theme.colorScheme.outline,
        Icons.cloud_off_rounded,
      ),
      (false, DateTime last, _) => (
        formatRelativeTime(last),
        theme.colorScheme.secondary,
        CupertinoIcons.checkmark_circle_fill,
      ),
    };

    return Container(
      height: kPillHeight,
      padding: const EdgeInsets.symmetric(horizontal: kSpacingSmall),
      decoration: BoxDecoration(
        color: color.withValues(alpha: kPillTintOpacity),
        borderRadius: BorderRadius.circular(kPillRadius),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: kPillIconSize, color: color),
          const SizedBox(width: kSpacingTiny),
          Text(
            label,
            style: AppTextStyles.labelSmall(context)?.copyWith(color: color),
          ),
        ],
      ),
    );
  }
}

/// Formats [when] as 'Just now' / 'Xm ago' / 'Xh ago', falling back to a
/// month-day date beyond 24 hours.
String formatRelativeTime(DateTime when) {
  final delta = DateTime.now().difference(when);
  if (delta.inMinutes < 1) return 'Just now';
  if (delta.inMinutes < 60) return '${delta.inMinutes}m ago';
  if (delta.inHours < 24) return '${delta.inHours}h ago';
  return DateFormat.MMMd().format(when);
}
