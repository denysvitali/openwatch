import 'package:flutter/cupertino.dart';
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
    final bpSystolic = manager.lastBloodPressureSystolic;
    final bpDiastolic = manager.lastBloodPressureDiastolic;
    final bpValue = bpSystolic == null || bpDiastolic == null
        ? '-'
        : '$bpSystolic/$bpDiastolic';

    return Scaffold(
      appBar: AppBar(title: const Text('Health')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 28),
        children: [
          _HeartRateCard(
            bpm: manager.lastHeartRate,
            supported: hrSupported,
            ready: ready,
            measuring: manager.measuringHeartRate,
            start: manager.startHeartRate,
            stop: manager.stopHeartRate,
          ),
          const SizedBox(height: 14),
          _SectionTitle('Available metrics'),
          const SizedBox(height: 8),
          _MetricList(
            metrics: [
              if (caps.bloodOxygen)
                const _HealthMetric(
                  icon: CupertinoIcons.drop_fill,
                  title: 'Blood oxygen',
                  value: '-',
                  tint: Color(0xFF007AFF),
                ),
              if (caps.bloodPressure)
                _HealthMetric(
                  icon: CupertinoIcons.waveform_path_ecg,
                  title: 'Blood pressure',
                  value: bpValue,
                  unit: 'mmHg',
                  tint: Color(0xFFFF3B30),
                  ready: ready,
                  measuring: manager.measuringBloodPressure,
                  start: manager.startBloodPressure,
                  stop: manager.stopBloodPressure,
                ),
              if (caps.sleep)
                const _HealthMetric(
                  icon: CupertinoIcons.moon_fill,
                  title: 'Sleep',
                  value: 'History',
                  tint: Color(0xFF5856D6),
                ),
              if (caps.stress)
                _HealthMetric(
                  icon: CupertinoIcons.bolt_fill,
                  title: 'Stress',
                  value: manager.lastStress?.toString() ?? '-',
                  tint: Color(0xFFFF9500),
                  ready: ready,
                  measuring: manager.measuringStress,
                  start: manager.startStress,
                  stop: manager.stopStress,
                ),
              if (caps.hrv)
                _HealthMetric(
                  icon: CupertinoIcons.chart_bar_fill,
                  title: 'HRV',
                  value: manager.lastHrv?.toString() ?? '-',
                  unit: 'ms',
                  tint: Color(0xFF34C759),
                  ready: ready,
                  measuring: manager.measuringHrv,
                  start: manager.startHrv,
                  stop: manager.stopHrv,
                ),
              if (caps.temperature)
                const _HealthMetric(
                  icon: CupertinoIcons.thermometer,
                  title: 'Temperature',
                  value: '-',
                  tint: Color(0xFFFF2D55),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

class _HeartRateCard extends StatelessWidget {
  const _HeartRateCard({
    required this.bpm,
    required this.supported,
    required this.ready,
    required this.measuring,
    required this.start,
    required this.stop,
  });

  final int? bpm;
  final bool supported;
  final bool ready;
  final bool measuring;
  final VoidCallback start;
  final VoidCallback stop;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final String statusText;
    if (!supported) {
      statusText = 'Not supported on this device';
    } else if (!ready) {
      statusText = 'Connect your watch';
    } else if (measuring) {
      statusText = 'Measuring';
    } else {
      statusText = 'Ready to measure';
    }
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  width: 42,
                  height: 42,
                  decoration: BoxDecoration(
                    color: const Color(0xFFFF3B30).withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: const Icon(
                    CupertinoIcons.heart_fill,
                    color: Color(0xFFFF3B30),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    'Heart rate',
                    style: theme.textTheme.titleLarge?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                Text(
                  bpm == null ? '-' : '$bpm',
                  style: theme.textTheme.displaySmall?.copyWith(
                    fontWeight: FontWeight.w700,
                    height: 1,
                  ),
                ),
                if (bpm != null) ...[
                  const SizedBox(width: 4),
                  Padding(
                    padding: const EdgeInsets.only(top: 18),
                    child: Text(
                      'bpm',
                      style: theme.textTheme.labelLarge?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                ],
              ],
            ),
            const SizedBox(height: 12),
            Text(
              statusText,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: FilledButton.icon(
                    onPressed: ready && supported && !measuring ? start : null,
                    icon: const Icon(CupertinoIcons.play_fill),
                    label: const Text('Start'),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: ready && supported && measuring ? stop : null,
                    icon: const Icon(CupertinoIcons.stop_fill),
                    label: const Text('Stop'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _MetricList extends StatelessWidget {
  const _MetricList({required this.metrics});

  final List<_HealthMetric> metrics;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (metrics.isEmpty) {
      return Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Text(
            'No additional metrics reported by this watch.',
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ),
      );
    }

    return Card(
      child: Column(
        children: [
          for (var i = 0; i < metrics.length; i++) ...[
            ListTile(
              leading: Icon(metrics[i].icon, color: metrics[i].tint),
              title: Text(metrics[i].title),
              subtitle: metrics[i].unit == null ? null : Text(metrics[i].unit!),
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    metrics[i].measuring && metrics[i].value == '-'
                        ? 'Measuring'
                        : metrics[i].value,
                    style: theme.textTheme.titleMedium?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                  if (metrics[i].start != null) ...[
                    const SizedBox(width: 8),
                    IconButton(
                      tooltip: 'Start',
                      icon: const Icon(CupertinoIcons.play_fill),
                      onPressed: metrics[i].ready && !metrics[i].measuring
                          ? metrics[i].start
                          : null,
                    ),
                    IconButton(
                      tooltip: 'Stop',
                      icon: const Icon(CupertinoIcons.stop_fill),
                      onPressed: metrics[i].ready && metrics[i].measuring
                          ? metrics[i].stop
                          : null,
                    ),
                  ],
                ],
              ),
            ),
            if (i != metrics.length - 1)
              Divider(
                indent: 56,
                color: theme.colorScheme.outlineVariant.withValues(alpha: 0.7),
              ),
          ],
        ],
      ),
    );
  }
}

class _HealthMetric {
  const _HealthMetric({
    required this.icon,
    required this.title,
    required this.value,
    required this.tint,
    this.unit,
    this.ready = false,
    this.measuring = false,
    this.start,
    this.stop,
  });

  final IconData icon;
  final String title;
  final String value;
  final Color tint;
  final String? unit;
  final bool ready;
  final bool measuring;
  final VoidCallback? start;
  final VoidCallback? stop;
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle(this.title);

  final String title;

  @override
  Widget build(BuildContext context) {
    return Text(
      title,
      style: Theme.of(
        context,
      ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
    );
  }
}
