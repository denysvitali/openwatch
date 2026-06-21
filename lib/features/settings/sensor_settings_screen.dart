import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/ble/ble_transport.dart';
import '../../core/providers/app_providers.dart';

/// Wristband sensor settings: HR auto-measure interval, enable toggle,
/// and optional low/high alarm thresholds.
///
/// Changes are persisted locally via [SettingsService] and can be
/// pushed to the watch with the "Apply to device" action.
class SensorSettingsScreen extends ConsumerWidget {
  const SensorSettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(settingsProvider);
    final settingsNotifier = ref.read(settingsProvider.notifier);
    final manager = ref.watch(watchManagerProvider);
    final ready = (ref.watch(linkStateProvider).value) == LinkState.ready;
    final caps = manager.capabilities;
    final hrSupported = caps.heart;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Sensor settings'),
        actions: [
          TextButton.icon(
            onPressed: (ready && hrSupported)
                ? () => _applyToDevice(context, ref, manager)
                : null,
            icon: const Icon(Icons.watch),
            label: const Text('Apply'),
          ),
        ],
      ),
      body: ListView(
        children: [
          if (!hrSupported)
            const ListTile(
              leading: Icon(Icons.info_outline, color: Colors.orange),
              title: Text('Heart rate not supported on this device'),
            ),
          const _SectionHeader('Heart rate'),
          SwitchListTile(
            secondary: const Icon(Icons.favorite),
            title: const Text('Auto-measure'),
            subtitle: const Text('Periodic background readings'),
            value: settings.hrAutoMeasureEnabled,
            onChanged: settingsNotifier.setHrAutoMeasure,
          ),
          ListTile(
            leading: const Icon(Icons.timer),
            title: const Text('Measurement interval'),
            subtitle: Text('${settings.hrIntervalMinutes} minutes'),
            enabled: settings.hrAutoMeasureEnabled,
            trailing: SizedBox(
              width: 180,
              child: Slider(
                value: settings.hrIntervalMinutes.toDouble(),
                min: 1,
                max: 60,
                divisions: 59,
                label: '${settings.hrIntervalMinutes} min',
                onChanged: settings.hrAutoMeasureEnabled
                    ? (v) => settingsNotifier.setHrInterval(v.round())
                    : null,
              ),
            ),
          ),
          const _SectionHeader('Alarm thresholds'),
          ListTile(
            leading: const Icon(Icons.trending_down),
            title: const Text('Low HR alarm'),
            subtitle: const Text('0 = disabled'),
            trailing: SizedBox(
              width: 80,
              child: TextFormField(
                initialValue: settings.hrLowAlarm.toString(),
                keyboardType: TextInputType.number,
                textAlign: TextAlign.center,
                decoration: const InputDecoration(
                  suffixText: 'bpm',
                  isDense: true,
                ),
                onFieldSubmitted: (v) {
                  final parsed = int.tryParse(v);
                  if (parsed != null && parsed >= 0 && parsed <= 255) {
                    settingsNotifier.setHrLowAlarm(parsed);
                  }
                },
              ),
            ),
          ),
          ListTile(
            leading: const Icon(Icons.trending_up),
            title: const Text('High HR alarm'),
            subtitle: const Text('0 = disabled'),
            trailing: SizedBox(
              width: 80,
              child: TextFormField(
                initialValue: settings.hrHighAlarm.toString(),
                keyboardType: TextInputType.number,
                textAlign: TextAlign.center,
                decoration: const InputDecoration(
                  suffixText: 'bpm',
                  isDense: true,
                ),
                onFieldSubmitted: (v) {
                  final parsed = int.tryParse(v);
                  if (parsed != null && parsed >= 0 && parsed <= 255) {
                    settingsNotifier.setHrHighAlarm(parsed);
                  }
                },
              ),
            ),
          ),
          const Divider(),
          ListTile(
            leading: Icon(
              Icons.watch,
              color: ready && hrSupported ? Colors.green : Colors.grey,
            ),
            title: const Text('Apply to device now'),
            subtitle: Text(
              ready
                  ? (hrSupported
                        ? 'Push current settings to the watch'
                        : 'HR not supported on this device')
                  : 'Connect a watch first',
            ),
            enabled: ready && hrSupported,
            onTap: () => _applyToDevice(context, ref, manager),
          ),
        ],
      ),
    );
  }

  Future<void> _applyToDevice(
    BuildContext context,
    WidgetRef ref,
    dynamic manager,
  ) async {
    final settings = ref.read(settingsProvider);
    try {
      await manager.applyHeartRateSettings(
        enabled: settings.hrAutoMeasureEnabled,
        interval: settings.hrIntervalMinutes,
        tooLow: settings.hrLowAlarm,
        tooHigh: settings.hrHighAlarm,
      );
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Sensor settings applied to watch')),
        );
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Failed to apply: $e')));
      }
    }
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
