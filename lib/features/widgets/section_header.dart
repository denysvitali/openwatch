import 'package:flutter/material.dart';
import 'package:openwatch/core/ui/ui_constants.dart';

/// Uppercase, muted section label used to separate groups of settings rows.
class SectionHeader extends StatelessWidget {
  const SectionHeader(this.title, {super.key});
  final String title;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        kSectionHeaderPaddingH,
        kSectionHeaderPaddingTop,
        kSectionHeaderPaddingH,
        kSectionHeaderPaddingBottom,
      ),
      child: Text(
        title.toUpperCase(),
        style: Theme.of(context).textTheme.labelSmall?.copyWith(
          fontSize: kLabelSmall,
          color: Theme.of(context).colorScheme.onSurfaceVariant,
          letterSpacing: 1,
        ),
      ),
    );
  }
}
