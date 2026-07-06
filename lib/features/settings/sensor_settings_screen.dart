import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers/app_providers.dart';
import '../../core/services/watch_manager.dart';
import '../widgets/health_widgets.dart';

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
    final ready = manager.isReady;
    final caps = manager.capabilities;
    final hrSupported = caps.heart;
    final theme = Theme.of(context);

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
        padding: const EdgeInsets.only(bottom: 32),
        children: [
          if (!hrSupported)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 8),
              child: HealthCard(
                icon: Icons.info_outline,
                metricColor: theme.colorScheme.error,
                caption: 'Heart rate not supported on this device',
                trailing: StatusPill(
                  icon: Icons.error_outline,
                  label: 'Unsupported',
                  color: theme.colorScheme.error,
                ),
              ),
            ),
          const HealthSectionHeader(title:'Heart rate'),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 18),
            child: Card(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  HealthListTile(
                    title: 'Auto-measure',
                    subtitle: 'Periodic background readings',
                    leadingIcon: Icons.favorite,
                    leadingColor: theme.colorScheme.error,
                    trailing: Switch(
                      value: settings.hrAutoMeasureEnabled,
                      onChanged: settingsNotifier.setHrAutoMeasure,
                    ),
                    onTap: () => settingsNotifier.setHrAutoMeasure(!settings.hrAutoMeasureEnabled),
                  ),
                  HealthListTile(
                    title: 'Measurement interval',
                    subtitle: '${settings.hrIntervalMinutes} minutes',
                    leadingIcon: Icons.timer,
                    leadingColor: theme.colorScheme.primary,
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
                    onTap: null,
                  ),
                ],
              ),
            ),
          ),
          const HealthSectionHeader(title:'Alarm thresholds'),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 18),
            child: Card(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _AlarmFieldTile(
                    title: 'Low HR alarm',
                    subtitle: '0 = disabled',
                    icon: Icons.trending_down,
                    value: settings.hrLowAlarm,
                    onSubmitted: settingsNotifier.setHrLowAlarm,
                  ),
                  _AlarmFieldTile(
                    title: 'High HR alarm',
                    subtitle: '0 = disabled',
                    icon: Icons.trending_up,
                    value: settings.hrHighAlarm,
                    onSubmitted: settingsNotifier.setHrHighAlarm,
                    showDivider: false,
                  ),
                ],
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(18, 24, 18, 0),
            child: PrimaryHealthButton(
              label: 'Apply to device now',
              icon: Icons.watch,
              onPressed: (ready && hrSupported)
                  ? () => _applyToDevice(context, ref, manager)
                  : null,
            ),
          ),
          if (!ready)
            Padding(
              padding: const EdgeInsets.fromLTRB(18, 12, 18, 0),
              child: StatusPill(
                icon: Icons.bluetooth_disabled,
                label: 'Connect a watch first',
                color: theme.colorScheme.onSurfaceVariant,
              ),
            )
          else if (!hrSupported)
            Padding(
              padding: const EdgeInsets.fromLTRB(18, 12, 18, 0),
              child: StatusPill(
                icon: Icons.error_outline,
                label: 'HR not supported on this device',
                color: theme.colorScheme.error,
              ),
            ),
        ],
      ),
    );
  }

  Future<void> _applyToDevice(
    BuildContext context,
    WidgetRef ref,
    WatchManager manager,
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

class _AlarmFieldTile extends StatelessWidget {
  const _AlarmFieldTile({
    required this.title,
    required this.subtitle,
    required this.icon,
    required this.value,
    required this.onSubmitted,
    this.showDivider = true,
  });

  final String title;
  final String subtitle;
  final IconData icon;
  final int value;
  final ValueChanged<int> onSubmitted;
  final bool showDivider;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return HealthListTile(
      title: title,
      subtitle: subtitle,
      leadingIcon: icon,
      leadingColor: theme.colorScheme.primary,
      trailing: SizedBox(
        width: 80,
        child: TextFormField(
          initialValue: value.toString(),
          keyboardType: TextInputType.number,
          textAlign: TextAlign.center,
          decoration: const InputDecoration(
            suffixText: 'bpm',
            isDense: true,
          ),
          onFieldSubmitted: (v) {
            final parsed = int.tryParse(v);
            if (parsed != null && parsed >= 0 && parsed <= 255) {
              onSubmitted(parsed);
            }
          },
        ),
      ),
      onTap: null,
      showDivider: showDivider,
    );
  }
}
