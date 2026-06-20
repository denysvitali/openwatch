import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/ble/ble_transport.dart';
import '../../core/providers/app_providers.dart';

/// Health metrics. Heart rate is wired to the live-measure commands; the
/// remaining metrics are gated on device capabilities.
class HealthScreen extends ConsumerWidget {
  const HealthScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final manager = ref.watch(watchManagerProvider);
    final ready = (ref.watch(linkStateProvider).value) == LinkState.ready;
    final caps = manager.capabilities;
    final hrSupported = caps.heart;

    return Scaffold(
      appBar: AppBar(title: const Text('Health')),
      body: ListView(
        children: [
          ListTile(
            leading: const Icon(Icons.favorite, color: Colors.redAccent),
            title: const Text('Heart rate'),
            subtitle: Text(
              hrSupported
                  ? 'Wear the watch on your wrist and stay still for ~15s'
                  : 'Not supported on this device',
            ),
            trailing: Text(
              manager.lastHeartRate != null
                  ? '${manager.lastHeartRate} bpm'
                  : (hrSupported ? 'Measuring…' : '—'),
              style: Theme.of(context).textTheme.titleMedium,
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(
              children: [
                FilledButton.tonalIcon(
                  onPressed: (ready && hrSupported)
                      ? manager.startHeartRate
                      : null,
                  icon: const Icon(Icons.play_arrow),
                  label: const Text('Start'),
                ),
                const SizedBox(width: 12),
                OutlinedButton.icon(
                  onPressed: (ready && hrSupported)
                      ? manager.stopHeartRate
                      : null,
                  icon: const Icon(Icons.stop),
                  label: const Text('Stop'),
                ),
              ],
            ),
          ),
          const Divider(),
          if (caps.bloodOxygen)
            const ListTile(
              leading: Icon(Icons.bloodtype),
              title: Text('Blood oxygen'),
              trailing: Text('—'),
            ),
          if (caps.bloodPressure)
            const ListTile(
              leading: Icon(Icons.monitor_heart),
              title: Text('Blood pressure'),
              trailing: Text('—'),
            ),
          if (caps.sleep)
            const ListTile(
              leading: Icon(Icons.bedtime),
              title: Text('Sleep'),
              trailing: Text('—'),
            ),
          if (caps.stress)
            const ListTile(
              leading: Icon(Icons.psychology),
              title: Text('Stress'),
              trailing: Text('—'),
            ),
          if (caps.hrv)
            const ListTile(
              leading: Icon(Icons.show_chart),
              title: Text('HRV'),
              trailing: Text('—'),
            ),
          if (caps.temperature)
            const ListTile(
              leading: Icon(Icons.thermostat),
              title: Text('Temperature'),
              trailing: Text('—'),
            ),
        ],
      ),
    );
  }
}
