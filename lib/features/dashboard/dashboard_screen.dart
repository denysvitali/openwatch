import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../core/ble/ble_transport.dart';
import '../../core/providers/app_providers.dart';
import '../../core/services/history_sync.dart';
import '../history/widgets/hr_chart.dart';
import '../history/widgets/steps_chart.dart';

/// Device overview: connection state, firmware, battery, steps + quick actions.
class DashboardScreen extends ConsumerWidget {
  const DashboardScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final link = ref.watch(linkStateProvider).value ?? LinkState.disconnected;
    final manager = ref.watch(watchManagerProvider);
    final sync = ref.watch(historySyncProvider);
    final device = ref.watch(connectedDeviceProvider);
    final name = device?.platformName.isNotEmpty == true
        ? device!.platformName
        : 'Watch';

    return Scaffold(
      appBar: AppBar(
        title: const Text('Device'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: 'Refresh',
            onPressed: link == LinkState.ready
                ? () {
                    manager.refreshSteps();
                    manager.refreshBattery();
                  }
                : null,
          ),
          IconButton(
            icon: const Icon(Icons.link_off),
            tooltip: 'Disconnect',
            onPressed: () async {
              await ref.read(bleTransportProvider).disconnect();
              if (context.mounted) context.go('/scan');
            },
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Card(
            child: ListTile(
              leading: const Icon(Icons.watch, size: 36),
              title: Text(name),
              subtitle: Text(_describe(link)),
              trailing: Icon(
                link == LinkState.ready ? Icons.check_circle : Icons.sync,
                color: link == LinkState.ready ? Colors.green : null,
              ),
            ),
          ),
          const SizedBox(height: 8),
          _MetricCard(
            icon: manager.charging
                ? Icons.battery_charging_full
                : Icons.battery_full,
            title: 'Battery',
            value: manager.batteryPercent != null
                ? '${manager.batteryPercent}%${manager.charging ? " ⚡" : ""}'
                : '—',
          ),
          _MetricCard(
            icon: Icons.memory,
            title: 'Firmware',
            value: manager.firmwareRevision.isNotEmpty
                ? manager.firmwareRevision
                : '—',
          ),
          _MetricCard(
            icon: Icons.developer_board,
            title: 'Hardware',
            value: manager.hardwareRevision.isNotEmpty
                ? manager.hardwareRevision
                : '—',
          ),
          _MetricCard(
            icon: Icons.directions_walk,
            title: 'Steps today',
            value: manager.todaySteps?.toString() ?? '—',
          ),
          _MetricCard(
            icon: Icons.local_fire_department,
            title: 'Calories',
            value: manager.todayCalories?.toString() ?? '—',
          ),
          const SizedBox(height: 16),
          _RecentActivityCard(sync: sync),
          const SizedBox(height: 16),
          Wrap(
            spacing: 12,
            runSpacing: 12,
            children: [
              FilledButton.tonalIcon(
                onPressed: link == LinkState.ready ? manager.findDevice : null,
                icon: const Icon(Icons.vibration),
                label: const Text('Find watch'),
              ),
              FilledButton.tonalIcon(
                onPressed: link == LinkState.ready ? manager.syncTime : null,
                icon: const Icon(Icons.access_time),
                label: const Text('Sync time'),
              ),
              FilledButton.tonalIcon(
                onPressed: () => context.push('/history'),
                icon: const Icon(Icons.timeline),
                label: const Text('History'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  String _describe(LinkState s) => switch (s) {
    LinkState.ready => 'Connected',
    LinkState.connecting => 'Connecting…',
    LinkState.disconnected => 'Disconnected',
    LinkState.discovering => 'Discovering services…',
    LinkState.readingDeviceInfo => 'Reading device info…',
  };
}

class _MetricCard extends StatelessWidget {
  const _MetricCard({
    required this.icon,
    required this.title,
    required this.value,
  });
  final IconData icon;
  final String title;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: ListTile(
        leading: Icon(icon),
        title: Text(title),
        trailing: Text(value, style: Theme.of(context).textTheme.titleMedium),
      ),
    );
  }
}

/// Surfaces the most-recent locally-stored activity without forcing the
/// user to navigate to `/history`. Renders a friendly placeholder until
/// the first sync lands any samples — better than faking one.
class _RecentActivityCard extends StatelessWidget {
  const _RecentActivityCard({required this.sync});
  final HistorySync sync;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (sync.days.isEmpty) {
      return Card(
        child: ListTile(
          leading: const Icon(Icons.timeline),
          title: const Text('Recent activity'),
          subtitle: Text(
            sync.syncing
                ? 'Syncing…'
                : 'Connect to your watch to start collecting history.',
            style: theme.textTheme.bodySmall,
          ),
          trailing: TextButton(
            onPressed: () => Navigator.of(context).maybePop(),
            child: const Text('Open history'),
          ),
        ),
      );
    }

    final recent = sync.days.length <= 7
        ? sync.days
        : sync.days.sublist(sync.days.length - 7);
    final today = sync.days.last;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    'Recent activity',
                    style: theme.textTheme.titleMedium,
                  ),
                ),
                _SyncPill(sync: sync),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              _subtitle(today),
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 12),
            if (today.hr.isNotEmpty) ...[
              MiniHrSpark(samples: today.hr, height: 56),
              const SizedBox(height: 12),
            ],
            StepsBarChart(days: recent),
          ],
        ),
      ),
    );
  }

  String _subtitle(DailyHistory today) {
    final parts = <String>[];
    final avg = _avgBpm(today.hr);
    if (avg > 0) parts.add('HR avg ${avg}bpm today');
    if (today.steps != null) parts.add('${today.steps} steps today');
    if (today.sleep.isNotEmpty) {
      final total = today.sleep.fold<Duration>(
        Duration.zero,
        (a, s) => a + s.duration,
      );
      parts.add('${(total.inMinutes / 60).toStringAsFixed(1)}h sleep');
    }
    return parts.isEmpty
        ? DateFormat.yMMMd().format(today.day.midnight)
        : parts.join(' · ');
  }

  static int _avgBpm(List<HrSample> samples) {
    if (samples.isEmpty) return 0;
    final sum = samples.fold<int>(0, (a, s) => a + s.bpm);
    return (sum / samples.length).round();
  }
}

class _SyncPill extends StatelessWidget {
  const _SyncPill({required this.sync});
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
      (false, _, String e) => (
        'Error',
        theme.colorScheme.error,
        Icons.error_outline,
      ),
      (false, null, _) => (
        'No sync',
        theme.colorScheme.outline,
        Icons.cloud_off,
      ),
      (false, DateTime l, _) => (
        _formatRelative(l),
        Colors.green,
        Icons.check_circle,
      ),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: color),
          const SizedBox(width: 4),
          Text(
            label,
            style: theme.textTheme.labelSmall?.copyWith(color: color),
          ),
        ],
      ),
    );
  }

  String _formatRelative(DateTime when) {
    final delta = DateTime.now().difference(when);
    if (delta.inMinutes < 1) return 'Just now';
    if (delta.inMinutes < 60) return '${delta.inMinutes}m ago';
    if (delta.inHours < 24) return '${delta.inHours}h ago';
    return DateFormat.MMMd().format(when);
  }
}
