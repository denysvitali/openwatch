import 'package:flutter/material.dart';
import 'package:openwatch/core/ui/ui_constants.dart';

import '../widgets/health_widgets.dart';

/// App-notification relay config (ANCS-style push to the watch).
///
/// Placeholder: protocol supports push messages but companion-side enablement
/// is not wired yet — switches stay disabled.
class NotificationsScreen extends StatelessWidget {
  const NotificationsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return Scaffold(
      appBar: AppBar(title: const Text('Notifications')),
      body: MaxWidthContainer(
        child: ListView(
          padding: const EdgeInsets.only(bottom: kScreenPaddingBottom),
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(
                kCardPadding,
                kSpacingSmall,
                kCardPadding,
                0,
              ),
              child: HealthCard(
                icon: Icons.info_outline,
                metricColor: colorScheme.primary,
                title: 'Notification relay',
                caption:
                    'Forward calls, messages, and app alerts to the watch. '
                    'Companion-side enablement is not wired yet — toggles stay off.',
                trailing: StatusPill(
                  icon: Icons.pending,
                  label: 'Coming soon',
                  color: colorScheme.tertiary,
                ),
              ),
            ),
            SettingsGroup(
              title: 'Categories',
              children: [
                HealthListTile(
                  leadingIcon: Icons.call,
                  leadingColor: colorScheme.primary,
                  title: 'Incoming calls',
                  subtitle: 'Ring and caller ID on the watch',
                  control: Switch.adaptive(value: false, onChanged: null),
                ),
                HealthListTile(
                  leadingIcon: Icons.sms,
                  leadingColor: colorScheme.primary,
                  title: 'Messages',
                  subtitle: 'SMS and messaging apps',
                  control: Switch.adaptive(value: false, onChanged: null),
                ),
                HealthListTile(
                  leadingIcon: Icons.apps,
                  leadingColor: colorScheme.primary,
                  title: 'App notifications',
                  subtitle: 'Other app alerts',
                  control: Switch.adaptive(value: false, onChanged: null),
                  showDivider: false,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
