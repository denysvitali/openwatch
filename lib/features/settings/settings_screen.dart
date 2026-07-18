import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:openwatch/core/ui/app_colors.dart';
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
    final isReady = manager.isReady;
    final contextRouter = context;

    if (settingsAsync.isLoading) {
      return Scaffold(
        appBar: AppBar(title: const Text('Settings')),
        body: const Center(child: AppLoadingIndicator()),
      );
    }

    if (settingsAsync.hasError) {
      return Scaffold(
        appBar: AppBar(title: const Text('Settings')),
        body: EmptyState(
          icon: Icons.error_outline,
          title: 'Could not load settings',
          caption: settingsAsync.error?.toString() ?? 'Unknown error',
        ),
      );
    }

    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: MaxWidthContainer(
        child: ListView(
          padding: const EdgeInsets.only(bottom: kScreenPaddingBottom),
          children: [
            _StatusCard(
              ready: isReady,
              cloudSyncEnabled: settings.cloudSyncEnabled,
            ),
            _DeviceSection(
              armedAlarmCount: armedAlarmCount,
              ready: isReady,
              autoSyncTimeOnConnect: settings.autoSyncTimeOnConnect,
              autoSyncHistoryOnConnect: settings.autoSyncHistoryOnConnect,
              onFindDevice: isReady
                  ? () {
                      manager.findDevice();
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                          content: Text('Watch will ring shortly'),
                        ),
                      );
                    }
                  : null,
              onSyncTime: isReady
                  ? () {
                      manager.syncTime();
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('Watch clock updated')),
                      );
                    }
                  : null,
              onAutoSyncTimeChanged: settingsNotifier.setAutoSyncTime,
              onAutoSyncHistoryChanged: settingsNotifier.setAutoSyncHistory,
              onFirmware: () => contextRouter.push('/firmware'),
              onSensorSettings: () => contextRouter.push('/sensor-settings'),
              onClockAlarms: isReady
                  ? () => contextRouter.push('/alarms')
                  : null,
              onWatchPreferences: () => contextRouter.push('/preferences'),
              onCustomWatchFace: () => contextRouter.push('/watchface'),
            ),
            _PhoneSection(
              onNotifications: () => contextRouter.push('/notifications'),
            ),
            _CloudSection(
              cloudSyncEnabled: settings.cloudSyncEnabled,
              region: settings.region,
              onCloudSyncChanged: (enabled) {
                enabled
                    ? _confirmCloud(
                        context,
                        () => settingsNotifier.setCloudSync(true),
                      )
                    : settingsNotifier.setCloudSync(false);
              },
              onRegionChanged: (region) =>
                  region == null ? null : settingsNotifier.setRegion(region),
            ),
            _DiagnosticsSection(
              onLogs: () => contextRouter.push('/logs'),
              onBpDebug: () => contextRouter.push('/bp-debug'),
              onClearHistory: () => _confirmClearHistory(context, ref),
            ),
            _DangerSection(
              onFactoryReset: isReady
                  ? () => _confirmReset(context, manager.factoryReset)
                  : null,
            ),
            _AboutSection(
              onAbout: () => showAboutDialog(
                context: context,
                applicationName: 'OpenWatch',
                applicationVersion: '0.1.0',
                applicationLegalese:
                    'Open-source, offline-first manager for Oudmon-based BLE smartwatches.',
              ),
              onDisconnect: () async {
                await ref.read(bleConnectionPoolProvider).disconnect();
                if (context.mounted) context.go('/scan');
              },
              onForget: () => _confirmForget(context, ref),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _confirmReset(
    BuildContext context,
    Future<void> Function() onConfirm,
  ) async {
    final ok = await showConfirmDialog(
      context,
      title: 'Factory reset watch?',
      message:
          'This erases all data on the watch and cannot be undone. The watch may disconnect after the command is sent.',
      confirmLabel: 'Reset watch',
      destructive: true,
    );
    if (!ok) return;
    await onConfirm();
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Reset sent — watch may reboot and disconnect'),
        ),
      );
    }
  }
}

class _StatusCard extends StatelessWidget {
  const _StatusCard({required this.ready, required this.cloudSyncEnabled});

  final bool ready;
  final bool cloudSyncEnabled;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = AppColors.of(context);

    return Padding(
      padding: const EdgeInsets.fromLTRB(
        kCardPadding,
        kSpacingSmall,
        kCardPadding,
        0,
      ),
      child: HealthCard(
        title: 'Status',
        icon: ready ? Icons.watch_rounded : Icons.watch_off_outlined,
        caption: ready
            ? 'Watch connected — health data stays on this phone unless cloud is on.'
            : 'No watch connected. Pair from Scan when ready.',
        metricColor: ready ? colors.activity : colors.accent,
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
                  ? colors.activity
                  : theme.colorScheme.onSurfaceVariant,
            ),
            const SizedBox(height: kSpacingTiny),
            StatusPill(
              icon: cloudSyncEnabled ? Icons.cloud_done : Icons.cloud_off,
              label: cloudSyncEnabled ? 'Cloud on' : 'Cloud off',
              color: cloudSyncEnabled
                  ? colors.accent
                  : theme.colorScheme.onSurfaceVariant,
            ),
          ],
        ),
      ),
    );
  }
}

class _DeviceSection extends StatelessWidget {
  const _DeviceSection({
    required this.armedAlarmCount,
    required this.ready,
    required this.autoSyncTimeOnConnect,
    required this.autoSyncHistoryOnConnect,
    this.onFindDevice,
    this.onSyncTime,
    required this.onAutoSyncTimeChanged,
    required this.onAutoSyncHistoryChanged,
    required this.onFirmware,
    required this.onSensorSettings,
    this.onClockAlarms,
    required this.onWatchPreferences,
    required this.onCustomWatchFace,
  });

  final int armedAlarmCount;
  final bool ready;
  final bool autoSyncTimeOnConnect;
  final bool autoSyncHistoryOnConnect;
  final VoidCallback? onFindDevice;
  final VoidCallback? onSyncTime;
  final ValueChanged<bool> onAutoSyncTimeChanged;
  final ValueChanged<bool> onAutoSyncHistoryChanged;
  final VoidCallback onFirmware;
  final VoidCallback onSensorSettings;
  final VoidCallback? onClockAlarms;
  final VoidCallback onWatchPreferences;
  final VoidCallback onCustomWatchFace;

  @override
  Widget build(BuildContext context) {
    return SettingsGroup(
      title: 'Device',
      children: [
        HealthListTile(
          title: 'Find device',
          subtitle: 'Ring the watch',
          leadingIcon: Icons.vibration,
          onTap: onFindDevice,
        ),
        HealthListTile(
          title: 'Sync time now',
          subtitle: 'Local only — no network',
          leadingIcon: Icons.access_time,
          onTap: onSyncTime,
        ),
        SettingsSwitchTile(
          title: 'Auto-sync time on connect',
          subtitle: 'Local only — no network',
          icon: Icons.update_disabled,
          value: autoSyncTimeOnConnect,
          onChanged: onAutoSyncTimeChanged,
        ),
        SettingsSwitchTile(
          title: 'Auto-sync history on connect',
          subtitle: 'Fetch missing days each time the watch is ready',
          icon: Icons.history_toggle_off,
          value: autoSyncHistoryOnConnect,
          onChanged: onAutoSyncHistoryChanged,
        ),
        HealthListTile(
          title: 'Firmware update (OTA)',
          subtitle: 'Local images over BLE',
          leadingIcon: Icons.system_update,
          trailingChevron: true,
          onTap: onFirmware,
        ),
        HealthListTile(
          title: 'Sensor settings',
          subtitle: 'HR interval, alarm thresholds',
          leadingIcon: Icons.sensors,
          trailingChevron: true,
          onTap: onSensorSettings,
        ),
        HealthListTile(
          title: 'Clock alarms',
          subtitle: armedAlarmCount == 0
              ? 'None armed'
              : '$armedAlarmCount armed',
          leadingIcon: Icons.alarm,
          value: ready ? armedAlarmCount.toString() : null,
          unit: ready ? 'armed' : null,
          onTap: onClockAlarms,
        ),
        HealthListTile(
          title: 'Watch preferences',
          subtitle: 'Display, theme, DND, goals, reminders',
          leadingIcon: Icons.tune,
          trailingChevron: true,
          onTap: onWatchPreferences,
        ),
        HealthListTile(
          title: 'Custom watch face',
          subtitle: 'Experimental designer (not on H59MA v14)',
          leadingIcon: Icons.brush_outlined,
          trailingChevron: true,
          onTap: onCustomWatchFace,
          showDivider: false,
        ),
      ],
    );
  }
}

class _PhoneSection extends StatelessWidget {
  const _PhoneSection({required this.onNotifications});

  final VoidCallback onNotifications;

  @override
  Widget build(BuildContext context) {
    return SettingsGroup(
      title: 'Phone',
      children: [
        HealthListTile(
          title: 'Phone notifications',
          subtitle: 'Mirror calls & messages to the watch',
          leadingIcon: Icons.notifications_outlined,
          trailingChevron: true,
          onTap: onNotifications,
          showDivider: false,
        ),
      ],
    );
  }
}

class _CloudSection extends StatelessWidget {
  const _CloudSection({
    required this.cloudSyncEnabled,
    required this.region,
    required this.onCloudSyncChanged,
    required this.onRegionChanged,
  });

  final bool cloudSyncEnabled;
  final CloudRegion region;
  final ValueChanged<bool> onCloudSyncChanged;
  final ValueChanged<CloudRegion?> onRegionChanged;

  @override
  Widget build(BuildContext context) {
    return SettingsGroup(
      title: 'Cloud sync',
      children: [
        SettingsSwitchTile(
          title: 'Enable cloud integration',
          subtitle: cloudSyncEnabled
              ? 'Health & firmware lookup via QC Wireless servers'
              : 'Off — OpenWatch runs fully offline',
          icon: cloudSyncEnabled ? Icons.cloud_done : Icons.cloud_off,
          value: cloudSyncEnabled,
          onChanged: onCloudSyncChanged,
          showDivider: cloudSyncEnabled,
        ),
        if (cloudSyncEnabled)
          HealthListTile(
            title: 'Server region',
            subtitle: 'Backend endpoint for cloud sync',
            leadingIcon: Icons.public,
            trailing: DropdownButton<CloudRegion>(
              value: region,
              onChanged: onRegionChanged,
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
            showDivider: false,
          ),
      ],
    );
  }
}

class _DiagnosticsSection extends StatelessWidget {
  const _DiagnosticsSection({
    required this.onLogs,
    required this.onBpDebug,
    required this.onClearHistory,
  });

  final VoidCallback onLogs;
  final VoidCallback onBpDebug;
  final VoidCallback onClearHistory;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return SettingsGroup(
      title: 'Diagnostics',
      children: [
        HealthListTile(
          title: 'Logs',
          subtitle: 'BLE traffic & events — copy to share',
          leadingIcon: Icons.bug_report_outlined,
          trailingChevron: true,
          onTap: onLogs,
        ),
        HealthListTile(
          title: 'BP raw bytes',
          subtitle: 'Contributor tool for PROTOCOL.md §8.5',
          leadingIcon: Icons.bloodtype_outlined,
          trailingChevron: true,
          onTap: onBpDebug,
        ),
        HealthListTile(
          title: 'Clear stored history',
          subtitle: 'Wipe HR, sleep and steps on this phone',
          leadingIcon: Icons.delete_sweep,
          leadingColor: theme.colorScheme.error,
          onTap: onClearHistory,
          showDivider: false,
        ),
      ],
    );
  }
}

class _DangerSection extends StatelessWidget {
  const _DangerSection({required this.onFactoryReset});

  final VoidCallback? onFactoryReset;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return SettingsGroup(
      title: 'Danger zone',
      children: [
        HealthListTile(
          title: 'Factory reset watch',
          subtitle: 'Erases all data on the watch',
          leadingIcon: Icons.restart_alt,
          leadingColor: theme.colorScheme.error,
          onTap: onFactoryReset,
          showDivider: false,
        ),
      ],
    );
  }
}

class _AboutSection extends StatelessWidget {
  const _AboutSection({
    required this.onAbout,
    required this.onDisconnect,
    required this.onForget,
  });

  final VoidCallback onAbout;
  final VoidCallback onDisconnect;
  final VoidCallback onForget;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return SettingsGroup(
      title: 'About',
      children: [
        HealthListTile(
          title: 'About OpenWatch',
          subtitle: 'Version 0.1.0',
          leadingIcon: Icons.info_outline,
          trailingChevron: true,
          onTap: onAbout,
        ),
        HealthListTile(
          title: 'Disconnect',
          subtitle: 'Keeps the watch paired for auto-reconnect',
          leadingIcon: Icons.link_off,
          onTap: onDisconnect,
        ),
        HealthListTile(
          title: 'Forget device',
          subtitle: 'Disconnect and stop auto-reconnecting',
          leadingIcon: Icons.delete_forever,
          leadingColor: theme.colorScheme.error,
          onTap: onForget,
          showDivider: false,
        ),
      ],
    );
  }
}

Future<void> _confirmClearHistory(BuildContext context, WidgetRef ref) async {
  final ok = await showConfirmDialog(
    context,
    title: 'Clear stored history?',
    message:
        'Removes every day of HR, sleep and step data stored on this '
        'phone. The watch itself is untouched — a fresh sync will '
        're-download whatever data it still has.',
    confirmLabel: 'Clear',
    destructive: true,
  );
  if (!ok) return;
  final store = await ref.read(historyStoreProvider.future);
  await store.clearAll();
  await ref.read(historySyncProvider).loadFromStore();
  if (context.mounted) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('Stored history cleared')));
  }
}

Future<void> _confirmForget(BuildContext context, WidgetRef ref) async {
  final ok = await showConfirmDialog(
    context,
    title: 'Forget this watch?',
    message:
        'Disconnects now and stops auto-reconnect. You can pair again from Scan anytime.',
    confirmLabel: 'Forget',
    destructive: true,
  );
  if (!ok) return;
  await ref.read(bleConnectionPoolProvider).disconnect();
  final svc = await ref.read(settingsServiceProvider.future);
  await svc.clearLastDevice();
  if (context.mounted) context.go('/scan');
}

Future<void> _confirmCloud(BuildContext context, VoidCallback onConfirm) async {
  final ok = await showConfirmDialog(
    context,
    title: 'Enable cloud integration?',
    message:
        'OpenWatch is offline-first by default.\n\n'
        'Turning this on may send firmware lookups, health sync, and '
        'watch-face data to QC Wireless servers. You can turn it off anytime.\n\n'
        'Nothing leaves this phone until you enable this switch.',
    confirmLabel: 'Enable cloud',
  );
  if (ok) onConfirm();
}
