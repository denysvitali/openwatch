import 'package:flutter/material.dart';
import 'package:openwatch/core/ui/ui_constants.dart';

import '../widgets/health_widgets.dart';

/// App-notification relay config (ANCS-style push to the watch).
///
/// Currently a placeholder: the watch protocol supports push messages but the
/// companion-side enablement toggles are not yet wired, so all switches are
/// disabled.
class NotificationsScreen extends StatelessWidget {
  const NotificationsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return Scaffold(
      appBar: AppBar(title: const Text('Notifications')),
      body: ListView(
        children: [
          const HealthSectionHeader(title: 'Push to watch'),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: kCardPadding),
            child: HealthCard(
              icon: Icons.info_outline,
              metricColor: colorScheme.primary,
              title: 'Notification relay',
              caption:
                  'Forward calls, messages, and app alerts to the watch. '
                  'This feature requires companion-side support and is not yet enabled.',
              trailing: StatusPill(
                icon: Icons.pending,
                label: 'Coming soon',
                color: colorScheme.primary,
              ),
            ),
          ),
          const HealthSectionHeader(title: 'Categories'),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: kCardPadding),
            child: Card(
              child: Column(
                children: [
                  HealthListTile(
                    leadingIcon: Icons.call,
                    leadingColor: colorScheme.primary,
                    title: 'Incoming calls',
                    subtitle: 'Ring and caller ID on the watch',
                    control: const Switch(value: false, onChanged: null),
                  ),
                  HealthListTile(
                    leadingIcon: Icons.sms,
                    leadingColor: colorScheme.primary,
                    title: 'Messages',
                    subtitle: 'SMS and messaging apps',
                    control: const Switch(value: false, onChanged: null),
                  ),
                  HealthListTile(
                    leadingIcon: Icons.apps,
                    leadingColor: colorScheme.primary,
                    title: 'App notifications',
                    subtitle: 'Other app alerts',
                    control: const Switch(value: false, onChanged: null),
                    showDivider: false,
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: kCardPadding),
        ],
      ),
    );
  }
}
