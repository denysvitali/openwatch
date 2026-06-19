import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/ble/ble_transport.dart';
import '../../core/providers/app_providers.dart';
import '../../core/services/settings_service.dart';

/// Device + app settings, including the offline-first cloud toggle.
class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(settingsProvider);
    final settingsNotifier = ref.read(settingsProvider.notifier);
    final manager = ref.watch(watchManagerProvider);
    final ready = (ref.watch(linkStateProvider).value) == LinkState.ready;

    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(
        children: [
          const _SectionHeader('Device'),
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
          ListTile(
            leading: const Icon(Icons.system_update),
            title: const Text('Firmware update (OTA)'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => context.push('/firmware'),
          ),
          ListTile(
            leading: const Icon(Icons.restart_alt, color: Colors.redAccent),
            title: const Text('Factory reset watch'),
            enabled: ready,
            onTap: ready
                ? () => _confirmReset(context, manager.factoryReset)
                : null,
          ),

          const _SectionHeader('Cloud sync'),
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

          const _SectionHeader('Diagnostics'),
          ListTile(
            leading: const Icon(Icons.bug_report_outlined),
            title: const Text('Logs'),
            subtitle: const Text('BLE traffic & events — copy to share'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => context.push('/logs'),
          ),

          const _SectionHeader('About'),
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

class _SectionHeader extends StatelessWidget {
  const _SectionHeader(this.title);
  final String title;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 20, 16, 8),
      child: Text(
        title.toUpperCase(),
        style: Theme.of(context).textTheme.labelMedium?.copyWith(
          color: Theme.of(context).colorScheme.primary,
          letterSpacing: 1,
        ),
      ),
    );
  }
}
