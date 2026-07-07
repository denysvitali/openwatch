import 'package:flutter/material.dart';
import 'package:openwatch/core/ui/ui_constants.dart';

/// A compact status pill used for sync state, signal strength, update
/// availability, cloud status, and similar discrete states.
class StatusPill extends StatelessWidget {
  const StatusPill({
    super.key,
    required this.icon,
    required this.label,
    this.color,
  });

  final IconData icon;
  final String label;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final statusColor = color ?? theme.colorScheme.primary;

    return Container(
      height: kPillHeight,
      padding: const EdgeInsets.symmetric(horizontal: kSpacingSmall),
      decoration: BoxDecoration(
        color: statusColor.withValues(alpha: kPillTintOpacity),
        borderRadius: BorderRadius.circular(kPillRadius),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: kPillIconSize, color: statusColor),
          const SizedBox(width: kSpacingTiny),
          Text(
            label,
            style: AppTextStyles.labelSmall(context)
                ?.copyWith(color: statusColor),
          ),
        ],
      ),
    );
  }
}
