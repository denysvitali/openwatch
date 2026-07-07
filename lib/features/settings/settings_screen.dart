import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:openwatch/core/ui/ui_constants.dart';

import '../../core/providers/app_providers.dart';
import '../../core/services/settings_service.dart';
import '../widgets/health_widgets.dart';

/// Device + app settings, including the offline-first cloud toggle.
class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settingsAsync = ref.watch(settingsServiceProvider);
    final settings = ref.watch(settingsProvider);
    final settingsNotifier = ref.read(settingsProvider.notifier);
    final manager = ref.watch(watchManagerProvider);
    final armedAlarmCount = manager.alarms
        .where((alarm) => alarm.enabled)
        .length;
    final ready = manager.isReady;
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(
        padding: const EdgeInsets.only(bottom: kCardPadding),
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: kCardPadding),
            child: HealthCard(
              title: 'Status',
              icon: ready ? Icons.watch_rounded : Icons.watch_off_outlined,
              caption: ready ? 'Watch connected' : 'No watch connected',
              trailing: Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                mainAxisSize: MainAxisSize.min,
                children: [
                  StatusPill(
                    icon: ready
                        ? Icons.bluetooth_connected
                        : Icons.bluetooth_disabled,
                    label: ready ? 'Connected' : 'Disconnected',
                    color: ready
                        ? theme.colorScheme.primary
                        : theme.colorScheme.onSurfaceVariant,
                  ),
                  const SizedBox(height: kSpacingTiny),
                  StatusPill(
                    icon: settings.cloudSyncEnabled
                        ? Icons.cloud_done
                        : Icons.cloud_off,
                    label: settings.cloudSyncEnabled ? 'Cloud on' : 'Cloud off',
                    color: settings.cloudSyncEnabled
                        ? theme.colorScheme.primary
                        : theme.colorScheme.onSurfaceVariant,
                  ),
                ],
              ),
            ),
          ),
          const HealthSectionHeader(title: 'Device'),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: kCardPadding),
            child: Card(
              elevation: 0,
              margin: EdgeInsets.zero,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(kCardRadius),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  HealthListTile(
                    title: 'Find device',
                    subtitle: 'Ring the watch',
                    leadingIcon: Icons.vibration,
                    onTap: ready ? manager.findDevice : null,
                  ),
                  HealthListTile(
                    title: 'Sync time now',
                    subtitle: 'Local only — no network',
                    leadingIcon: Icons.access_time,
                    onTap: ready ? manager.syncTime : null,
                  ),
                  _SwitchTile(
                    title: 'Auto-sync time on connect',
                    subtitle: 'Local only — no network',
                    icon: Icons.update_disabled,
                    value: settings.autoSyncTimeOnConnect,
                    onChanged: settingsNotifier.setAutoSyncTime,
                  ),
                  _SwitchTile(
                    title: 'Auto-sync history on connect',
                    subtitle:
                        'Fetch missing days from the watch each time it becomes ready',
                    icon: Icons.history_toggle_off,
                    value: settings.autoSyncHistoryOnConnect,
                    onChanged: settingsNotifier.setAutoSyncHistory,
                  ),
                  HealthListTile(
                    title: 'Firmware update (OTA)',
                    subtitle: 'Local firmware images over BLE',
                    leadingIcon: Icons.system_update,
                    trailing: Icon(
                      CupertinoIcons.chevron_forward,
                      color: theme.colorScheme.onSurfaceVariant,
                      size: kIconSizeSmall,
                    ),
                    onTap: () => context.push('/firmware'),
                  ),
                  HealthListTile(
                    title: 'Sensor settings',
                    subtitle: 'HR interval, alarms',
                    leadingIcon: Icons.sensors,
                    trailing: Icon(
                      CupertinoIcons.chevron_forward,
                      color: theme.colorScheme.onSurfaceVariant,
                      size: kIconSizeSmall,
                    ),
                    onTap: () => context.push('/sensor-settings'),
                  ),
                  HealthListTile(
                    title: 'Clock alarms',
                    subtitle: armedAlarmCount == 0
                        ? 'None armed'
                        : '$armedAlarmCount armed',
                    leadingIcon: Icons.alarm,
                    value: ready ? armedAlarmCount.toString() : null,
                    unit: ready ? 'armed' : null,
                    onTap: ready ? () => context.push('/alarms') : null,
                  ),
                  HealthListTile(
                    title: 'Watch preferences',
                    subtitle:
                        'Display, theme, DND, daily goals, sedentary alarms',
                    leadingIcon: Icons.tune,
                    trailing: Icon(
                      CupertinoIcons.chevron_forward,
                      color: theme.colorScheme.onSurfaceVariant,
                      size: kIconSizeSmall,
                    ),
                    onTap: () => context.push('/preferences'),
                  ),
                  HealthListTile(
                    title: 'Custom watch face',
                    subtitle: 'Designer + DIY upload (Channel-B 0x3a)',
                    leadingIcon: Icons.brush_outlined,
                    trailing: Icon(
                      CupertinoIcons.chevron_forward,
                      color: theme.colorScheme.onSurfaceVariant,
                      size: kIconSizeSmall,
                    ),
                    onTap: () => context.push('/watchface'),
                  ),
                  HealthListTile(
                    title: 'Factory reset watch',
                    subtitle: 'Erases all data on the watch',
                    leadingIcon: Icons.restart_alt,
                    trailing: Icon(
                      CupertinoIcons.chevron_forward,
                      color: theme.colorScheme.onSurfaceVariant,
                      size: kIconSizeSmall,
                    ),
                    onTap: ready
                        ? () => _confirmReset(context, manager.factoryReset)
                        : null,
                    showDivider: false,
                  ),
                ],
              ),
            ),
          ),
          const HealthSectionHeader(title: 'Cloud sync'),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: kCardPadding),
            child: Card(
              elevation: 0,
              margin: EdgeInsets.zero,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(kCardRadius),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _SwitchTile(
                    title: 'Enable cloud integration',
                    subtitle: settings.cloudSyncEnabled
                        ? 'Health & watch-face sync with QC Wireless servers'
                        : 'Off — OpenWatch runs fully offline',
                    icon: settings.cloudSyncEnabled
                        ? Icons.cloud_done
                        : Icons.cloud_off,
                    value: settings.cloudSyncEnabled,
                    onChanged: (enabled) => enabled
                        ? _confirmCloud(
                            context,
                            () => settingsNotifier.setCloudSync(true),
                          )
                        : settingsNotifier.setCloudSync(false),
                  ),
                  if (settings.cloudSyncEnabled)
                    HealthListTile(
                      title: 'Server region',
                      subtitle: 'Backend endpoint for cloud sync',
                      leadingIcon: Icons.public,
                      trailing: DropdownButton<CloudRegion>(
                        value: settings.region,
                        onChanged: (r) =>
                            r == null ? null : settingsNotifier.setRegion(r),
                        underline: const SizedBox.shrink(),
                        items: const [
                          DropdownMenuItem(
                            value: CloudRegion.international,
                            child: Text('International'),
                          ),
                          DropdownMenuItem(
                            value: CloudRegion.china,
                            child: Text('China'),
                          ),
                        ],
                      ),
                      onTap: null,
                      showDivider: false,
                    ),
                ],
              ),
            ),
          ),
          const HealthSectionHeader(title: 'Diagnostics'),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: kCardPadding),
            child: Card(
              elevation: 0,
              margin: EdgeInsets.zero,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(kCardRadius),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  HealthListTile(
                    title: 'Logs',
                    subtitle: 'BLE traffic & events — copy to share',
                    leadingIcon: Icons.bug_report_outlined,
                    trailing: Icon(
                      CupertinoIcons.chevron_forward,
                      color: theme.colorScheme.onSurfaceVariant,
                      size: kIconSizeSmall,
                    ),
                    onTap: () => context.push('/logs'),
                  ),
                  HealthListTile(
                    title: 'BP raw bytes',
                    subtitle:
                        'Compact history bytes for capture correlation. See PROTOCOL.md §8.5.',
                    leadingIcon: Icons.bloodtype_outlined,
                    trailing: Icon(
                      CupertinoIcons.chevron_forward,
                      color: theme.colorScheme.onSurfaceVariant,
                      size: kIconSizeSmall,
                    ),
                    onTap: () => context.push('/bp-debug'),
                  ),
                  HealthListTile(
                    title: 'Clear stored history',
                    subtitle:
                        'Wipes HR, sleep and step data stored on this phone',
                    leadingIcon: Icons.delete_sweep,
                    trailing: Icon(
                      CupertinoIcons.chevron_forward,
                      color: theme.colorScheme.onSurfaceVariant,
                      size: kIconSizeSmall,
                    ),
                    onTap: () => _confirmClearHistory(context, ref),
                    showDivider: false,
                  ),
                ],
              ),
            ),
          ),
          const HealthSectionHeader(title: 'About'),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: kCardPadding),
            child: Card(
              elevation: 0,
              margin: EdgeInsets.zero,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(kCardRadius),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  HealthListTile(
                    title: 'About OpenWatch',
                    subtitle: 'Version 0.1.0',
                    leadingIcon: Icons.info_outline,
                    trailing: Icon(
                      CupertinoIcons.chevron_forward,
                      color: theme.colorScheme.onSurfaceVariant,
                      size: kIconSizeSmall,
                    ),
                    onTap: () => showAboutDialog(
                      context: context,
                      applicationName: 'OpenWatch',
                      applicationVersion: '0.1.0',
                      applicationLegalese:
                          'Open-source, offline-first manager for Oudmon-based BLE smartwatches.',
                    ),
                  ),
                  HealthListTile(
                    title: 'Disconnect',
                    subtitle: 'Keeps the watch paired for auto-reconnect',
                    leadingIcon: Icons.link_off,
                    trailing: Icon(
                      CupertinoIcons.chevron_forward,
                      color: theme.colorScheme.onSurfaceVariant,
                      size: kIconSizeSmall,
                    ),
                    onTap: () async {
                      await ref.read(bleTransportProvider).disconnect();
                      if (context.mounted) context.go('/scan');
                    },
                  ),
                  HealthListTile(
                    title: 'Forget device',
                    subtitle: 'Disconnect and stop auto-reconnecting',
                    leadingIcon: Icons.delete_forever,
                    trailing: Icon(
                      CupertinoIcons.chevron_forward,
                      color: theme.colorScheme.onSurfaceVariant,
                      size: kIconSizeSmall,
                    ),
                    onTap: () async {
                      await ref.read(bleTransportProvider).disconnect();
                      final svc = await ref.read(
                        settingsServiceProvider.future,
                      );
                      await svc.clearLastDevice();
                      if (context.mounted) context.go('/scan');
                    },
                    showDivider: false,
                  ),
                ],
              ),
            ),
          ),
          if (settingsAsync.isLoading)
            const Padding(
              padding: EdgeInsets.all(kCardPadding),
              child: Center(child: CircularProgressIndicator()),
            ),
        ],
      ),
    );
  }

  void _confirmReset(BuildContext context, Future<void> Function() onConfirm) {
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Factory reset watch?'),
        content: const Text(
          'This erases all data on the watch and cannot be undone.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () {
              Navigator.pop(ctx);
              onConfirm();
            },
            child: const Text('Reset'),
          ),
        ],
      ),
    );
  }

  Future<void> _confirmClearHistory(BuildContext context, WidgetRef ref) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Clear stored history?'),
        content: const Text(
          'Removes every day of HR, sleep and step data stored on this '
          'phone. The watch itself is untouched — a fresh sync will '
          're-download whatever data it still has.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Clear'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    final store = await ref.read(historyStoreProvider.future);
    await store.clearAll();
    // Force the in-memory mirror to re-hydrate from the now-empty
    // directory so the UI updates immediately rather than waiting for
    // the next sync.
    await ref.read(historySyncProvider).loadFromStore();
    if (context.mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Stored history cleared')));
    }
  }

  void _confirmCloud(BuildContext context, VoidCallback onConfirm) {
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Enable cloud integration?'),
        content: const Text(
          'OpenWatch is offline-first. Enabling this sends data to QC Wireless '
          'servers for health sync, watch faces and firmware lookup. You can turn '
          'it off again at any time.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () {
              Navigator.pop(ctx);
              onConfirm();
            },
            child: const Text('Enable'),
          ),
        ],
      ),
    );
  }
}

class _SwitchTile extends StatelessWidget {
  const _SwitchTile({
    required this.title,
    required this.subtitle,
    required this.icon,
    required this.value,
    required this.onChanged,
  });

  final String title;
  final String subtitle;
  final IconData icon;
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    return HealthListTile(
      title: title,
      subtitle: subtitle,
      leadingIcon: icon,
      control: Switch(value: value, onChanged: onChanged),
      onTap: () => onChanged(!value),
    );
  }
}
