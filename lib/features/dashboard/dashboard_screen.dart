import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/ble/ble_transport.dart';
import '../../core/providers/app_providers.dart';

/// Device overview: connection state, firmware, battery, steps + quick actions.
class DashboardScreen extends ConsumerWidget {
  const DashboardScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final link = ref.watch(linkStateProvider).value ?? LinkState.disconnected;
    final manager = ref.watch(watchManagerProvider);
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
                onPressed: link == LinkState.ready
                    ? () => context.push('/history')
                    : null,
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
        LinkState.discovering => 'Discovering services…',
        LinkState.readingDeviceInfo => 'Reading device info…',
        LinkState.disconnected => 'Disconnected',
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
