import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:openwatch/core/ui/ui_constants.dart';

import '../../core/providers/app_providers.dart';
import '../widgets/health_widgets.dart';

/// App-notification relay config (ANCS-style push to the watch).
///
/// Placeholder: protocol supports push messages but companion-side enablement
/// is not wired yet — switches stay disabled.
class NotificationsScreen extends ConsumerWidget {
  const NotificationsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final manager = ref.watch(watchManagerProvider);
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final ready = manager.isReady;
    final loading = ready && !manager.initialized;
    final supported = manager.capabilities.alarm;

    return Scaffold(
      appBar: AppBar(title: const Text('Notifications')),
      body: MaxWidthContainer(
        child: !ready
            ? const _NotReady()
            : loading
            ? const Center(child: AppLoadingIndicator())
            : !supported
            ? const _Unsupported()
            : ListView(
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
                  _NotificationCategories(
                    categories: const [
                      _NotificationCategory(
                        icon: Icons.call,
                        title: 'Incoming calls',
                        subtitle: 'Ring and caller ID on the watch',
                      ),
                      _NotificationCategory(
                        icon: Icons.sms,
                        title: 'Messages',
                        subtitle: 'SMS and messaging apps',
                      ),
                      _NotificationCategory(
                        icon: Icons.apps,
                        title: 'App notifications',
                        subtitle: 'Other app alerts',
                      ),
                    ],
                  ),
                ],
              ),
      ),
    );
  }
}

class _NotificationCategory {
  const _NotificationCategory({
    required this.icon,
    required this.title,
    required this.subtitle,
  });

  final IconData icon;
  final String title;
  final String subtitle;
}

class _NotificationCategories extends StatelessWidget {
  const _NotificationCategories({required this.categories});

  final List<_NotificationCategory> categories;

  @override
  Widget build(BuildContext context) {
    if (categories.isEmpty) {
      return const EmptyState(
        icon: Icons.notifications_off_outlined,
        title: 'No notification categories',
        caption: 'This watch did not expose notification-relay categories.',
      );
    }

    final colorScheme = Theme.of(context).colorScheme;
    return SettingsGroup(
      title: 'Categories',
      children: [
        for (var index = 0; index < categories.length; index++) ...[
          _NotificationCategoryTile(
            category: categories[index],
            leadingColor: colorScheme.primary,
            showDivider: index < categories.length - 1,
          ),
        ],
      ],
    );
  }
}

class _NotificationCategoryTile extends StatelessWidget {
  const _NotificationCategoryTile({
    required this.category,
    required this.leadingColor,
    required this.showDivider,
  });

  final _NotificationCategory category;
  final Color leadingColor;
  final bool showDivider;

  @override
  Widget build(BuildContext context) {
    return HealthListTile(
      leadingIcon: category.icon,
      leadingColor: leadingColor,
      title: category.title,
      subtitle: category.subtitle,
      control: Switch.adaptive(value: false, onChanged: null),
      showDivider: showDivider,
    );
  }
}

class _NotReady extends StatelessWidget {
  const _NotReady();
  @override
  Widget build(BuildContext context) {
    return const EmptyState(
      icon: Icons.bluetooth_disabled,
      title: 'Connect your watch',
      caption: 'Connect your watch to open notification settings.',
    );
  }
}

class _Unsupported extends StatelessWidget {
  const _Unsupported();
  @override
  Widget build(BuildContext context) {
    return const EmptyState(
      icon: Icons.notifications_off_outlined,
      title: 'Notifications unavailable',
      caption: 'This watch does not expose notification relay support.',
    );
  }
}
