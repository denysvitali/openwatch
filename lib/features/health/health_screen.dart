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

    return Scaffold(
      appBar: AppBar(title: const Text('Health')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 28),
        children: [
          _HeartRateCard(
            bpm: manager.lastHeartRate,
            supported: hrSupported,
            ready: ready,
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
                  tint: Color(0xFF007AFF),
                ),
              if (caps.bloodPressure)
                const _HealthMetric(
                  icon: CupertinoIcons.waveform_path_ecg,
                  title: 'Blood pressure',
                  tint: Color(0xFFFF3B30),
                ),
              if (caps.sleep)
                const _HealthMetric(
                  icon: CupertinoIcons.moon_fill,
                  title: 'Sleep',
                  tint: Color(0xFF5856D6),
                ),
              if (caps.stress)
                const _HealthMetric(
                  icon: CupertinoIcons.bolt_fill,
                  title: 'Stress',
                  tint: Color(0xFFFF9500),
                ),
              if (caps.hrv)
                const _HealthMetric(
                  icon: CupertinoIcons.chart_bar_fill,
                  title: 'HRV',
                  tint: Color(0xFF34C759),
                ),
              if (caps.temperature)
                const _HealthMetric(
                  icon: CupertinoIcons.thermometer,
                  title: 'Temperature',
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
    required this.start,
    required this.stop,
  });

  final int? bpm;
  final bool supported;
  final bool ready;
  final VoidCallback start;
  final VoidCallback stop;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
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
              supported
                  ? (ready ? 'Ready to measure' : 'Connect your watch')
                  : 'Not supported on this device',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: FilledButton.icon(
                    onPressed: (ready && supported) ? start : null,
                    icon: const Icon(CupertinoIcons.play_fill),
                    label: const Text('Start'),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: (ready && supported) ? stop : null,
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
              trailing: Text(
                '-',
                style: theme.textTheme.titleMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
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
    required this.tint,
  });

  final IconData icon;
  final String title;
  final Color tint;
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
