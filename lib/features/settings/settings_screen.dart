import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/ble/ble_transport.dart';
import '../../core/providers/app_providers.dart';
import '../../core/services/settings_service.dart';
import '../widgets/section_header.dart';

/// Device + app settings, including the offline-first cloud toggle.
class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(settingsProvider);
    final settingsNotifier = ref.read(settingsProvider.notifier);
    final manager = ref.watch(watchManagerProvider);
    final armedAlarmCount = manager.alarms
        .where((alarm) => alarm.enabled)
        .length;
    final ready = (ref.watch(linkStateProvider).value) == LinkState.ready;

    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(
        children: [
          const SectionHeader('Device'),
          ListTile(
            leading: const Icon(Icons.vibration),
            title: const Text('Find device'),
            subtitle: const Text('Ring the watch'),
            enabled: ready,
            onTap: ready ? manager.findDevice : null,
          ),
          ListTile(
            leading: const Icon(Icons.access_time),
            title: const Text('Sync time now'),
            enabled: ready,
            onTap: ready ? manager.syncTime : null,
          ),
          SwitchListTile(
            secondary: const Icon(Icons.update_disabled),
            title: const Text('Auto-sync time on connect'),
            subtitle: const Text('Local only — no network'),
            value: settings.autoSyncTimeOnConnect,
            onChanged: settingsNotifier.setAutoSyncTime,
          ),
          SwitchListTile(
            secondary: const Icon(Icons.history_toggle_off),
            title: const Text('Auto-sync history on connect'),
            subtitle: const Text(
              'Fetch missing days from the watch each time it becomes '
              'ready — only days we haven\'t seen are pulled.',
            ),
            value: settings.autoSyncHistoryOnConnect,
            onChanged: settingsNotifier.setAutoSyncHistory,
          ),
          ListTile(
            leading: const Icon(Icons.system_update),
            title: const Text('Firmware update (OTA)'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => context.push('/firmware'),
          ),
          ListTile(
            leading: const Icon(Icons.sensors),
            title: const Text('Sensor settings'),
            subtitle: const Text('HR interval, alarms'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => context.push('/sensor-settings'),
          ),
          ListTile(
            leading: const Icon(Icons.alarm),
            title: const Text('Clock alarms'),
            subtitle: Text(
              armedAlarmCount == 0 ? 'None armed' : '$armedAlarmCount armed',
            ),
            trailing: const Icon(Icons.chevron_right),
            enabled: ready,
            onTap: ready ? () => context.push('/alarms') : null,
          ),
          ListTile(
            leading: const Icon(Icons.tune),
            title: const Text('Watch preferences'),
            subtitle: const Text(
              'Display, theme, DND, daily goals, sedentary alarms',
            ),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => context.push('/preferences'),
          ),
          ListTile(
            leading: const Icon(Icons.brush_outlined),
            title: const Text('Custom watch face'),
            subtitle: const Text('Designer + DIY upload (Channel-B 0x3a)'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => context.push('/watchface'),
          ),
          ListTile(
            leading: const Icon(Icons.restart_alt, color: Colors.redAccent),
            title: const Text('Factory reset watch'),
            enabled: ready,
            onTap: ready
                ? () => _confirmReset(context, manager.factoryReset)
                : null,
          ),
          const SectionHeader('Cloud sync'),
          SwitchListTile(
            secondary: Icon(
              settings.cloudSyncEnabled ? Icons.cloud_done : Icons.cloud_off,
            ),
            title: const Text('Enable cloud integration'),
            subtitle: Text(
              settings.cloudSyncEnabled
                  ? 'Health & watch-face sync with QC Wireless servers'
                  : 'Off — OpenWatch runs fully offline',
            ),
            value: settings.cloudSyncEnabled,
            onChanged: (v) => v
                ? _confirmCloud(
                    context,
                    () => settingsNotifier.setCloudSync(true),
                  )
                : settingsNotifier.setCloudSync(false),
          ),
          if (settings.cloudSyncEnabled)
            ListTile(
              leading: const Icon(Icons.public),
              title: const Text('Server region'),
              trailing: DropdownButton<CloudRegion>(
                value: settings.region,
                onChanged: (r) =>
                    r == null ? null : settingsNotifier.setRegion(r),
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
            ),
          const SectionHeader('Diagnostics'),
          ListTile(
            leading: const Icon(Icons.bug_report_outlined),
            title: const Text('Logs'),
            subtitle: const Text('BLE traffic & events — copy to share'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => context.push('/logs'),
          ),
          ListTile(
            leading: const Icon(Icons.bloodtype_outlined),
            title: const Text('BP raw bytes'),
            subtitle: const Text(
              '13-byte BP records, byte-by-byte. '
              'See PROTOCOL.md §8.5 — needs live capture.',
            ),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => context.push('/bp-debug'),
          ),
          ListTile(
            leading: const Icon(Icons.delete_sweep),
            title: const Text('Clear stored history'),
            subtitle: const Text(
              'Wipes HR, sleep and step data stored on this phone.',
            ),
            onTap: () => _confirmClearHistory(context, ref),
          ),
          const SectionHeader('About'),
          ListTile(
            leading: const Icon(Icons.link_off),
            title: const Text('Disconnect'),
            subtitle: const Text('Keeps the watch paired for auto-reconnect'),
            onTap: () async {
              await ref.read(bleTransportProvider).disconnect();
              if (context.mounted) context.go('/scan');
            },
          ),
          ListTile(
            leading: const Icon(Icons.delete_forever),
            title: const Text('Forget device'),
            subtitle: const Text('Disconnect and stop auto-reconnecting'),
            onTap: () async {
              await ref.read(bleTransportProvider).disconnect();
              final svc = await ref.read(settingsServiceProvider.future);
              await svc.clearLastDevice();
              if (context.mounted) context.go('/scan');
            },
          ),
          const AboutListTile(
            icon: Icon(Icons.info_outline),
            applicationName: 'OpenWatch',
            applicationVersion: '0.1.0',
            aboutBoxChildren: [
              Text(
                'Open-source, offline-first manager for Oudmon-based BLE smartwatches.',
              ),
            ],
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
