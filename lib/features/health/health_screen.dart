import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/providers/app_providers.dart';
import '../widgets/health_widgets.dart';

/// Health metrics. Heart rate is wired to the live-measure commands; the
/// remaining metrics are gated on device capabilities.
class HealthScreen extends ConsumerWidget {
  const HealthScreen({super.key});

  static const Color _heartRed = Color(0xFFFF3B30);
  static const Color _sleepPurple = Color(0xFF5856D6);
  static const Color _activityGreen = Color(0xFF34C759);
  static const Color _nutritionOrange = Color(0xFFFF9500);
  static const Color _hydrationBlue = Color(0xFF32ADE6);

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final manager = ref.watch(watchManagerProvider);
    final ready = manager.isReady;
    final caps = manager.capabilities;
    final hrSupported = caps.heart;
    final bpSystolic = manager.lastBloodPressureSystolic;
    final bpDiastolic = manager.lastBloodPressureDiastolic;
    final bpValue = bpSystolic == null || bpDiastolic == null
        ? '-'
        : '$bpSystolic/$bpDiastolic';

    final metrics = <_HealthMetric>[
      if (caps.bloodOxygen)
        _HealthMetric(
          icon: CupertinoIcons.drop_fill,
          title: 'Blood oxygen',
          value: '-',
          unit: '%',
          tint: _hydrationBlue,
          onTap: () => context.push('/history'),
        ),
      if (caps.bloodPressure)
        _HealthMetric(
          icon: CupertinoIcons.waveform_path_ecg,
          title: 'Blood pressure',
          value: bpValue,
          unit: 'mmHg',
          tint: _heartRed,
          ready: ready,
          measuring: manager.measuringBloodPressure,
          start: manager.startBloodPressure,
          stop: manager.stopBloodPressure,
        ),
      if (caps.sleep)
        _HealthMetric(
          icon: CupertinoIcons.moon_fill,
          title: 'Sleep',
          value: 'History',
          tint: _sleepPurple,
          onTap: () => context.push('/history'),
        ),
      if (caps.stress)
        _HealthMetric(
          icon: CupertinoIcons.bolt_fill,
          title: 'Stress',
          value: manager.lastStress?.toString() ?? '-',
          tint: _nutritionOrange,
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
          tint: _activityGreen,
          ready: ready,
          measuring: manager.measuringHrv,
          start: manager.startHrv,
          stop: manager.stopHrv,
        ),
      if (caps.temperature)
        _HealthMetric(
          icon: CupertinoIcons.thermometer,
          title: 'Temperature',
          value: '-',
          unit: '°C',
          tint: _nutritionOrange,
          onTap: () => context.push('/history'),
        ),
    ];

    return Scaffold(
      appBar: AppBar(title: const Text('Health')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 28),
        children: [
          _HeartRateHero(
            bpm: manager.lastHeartRate,
            supported: hrSupported,
            ready: ready,
            measuring: manager.measuringHeartRate,
            start: manager.startHeartRate,
            stop: manager.stopHeartRate,
          ),
          const HealthSectionHeader(title: 'Available metrics'),
          _MetricList(metrics: metrics),
        ],
      ),
    );
  }
}

class _HeartRateHero extends StatelessWidget {
  const _HeartRateHero({
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
    final String statusText;
    if (!supported) {
      statusText = 'Not supported on this device';
    } else if (!ready) {
      statusText = 'Connect your watch to measure';
    } else if (measuring) {
      statusText = 'Keep still while measuring';
    } else {
      statusText = 'Ready to measure';
    }

    return HealthCard(
      title: 'Heart rate',
      value: bpm == null ? '-' : '$bpm',
      unit: bpm == null ? null : 'bpm',
      caption: statusText,
      icon: CupertinoIcons.heart_fill,
      metricColor: HealthScreen._heartRed,
      trailing: AnimatedHeartBadge(
        color: HealthScreen._heartRed,
        isAnimating: supported && ready && measuring,
        size: 40,
        iconSize: 24,
      ),
      child: Padding(
        padding: const EdgeInsets.only(top: 16),
        child: Row(
          children: [
            Expanded(
              child: PrimaryHealthButton(
                label: 'Start',
                icon: CupertinoIcons.play_fill,
                onPressed: ready && supported && !measuring ? start : null,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: PrimaryHealthButton(
                label: 'Stop',
                icon: CupertinoIcons.stop_fill,
                onPressed: ready && supported && measuring ? stop : null,
                elevated: false,
              ),
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
    if (metrics.isEmpty) {
      return const HealthCard(
        title: 'Available metrics',
        caption: 'No additional metrics reported by this watch.',
        icon: CupertinoIcons.heart,
      );
    }

    return Card(
      margin: EdgeInsets.zero,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (var i = 0; i < metrics.length; i++) ...[
            _MetricTile(
              metric: metrics[i],
              showDivider: i != metrics.length - 1,
            ),
          ],
        ],
      ),
    );
  }
}

class _MetricTile extends StatelessWidget {
  const _MetricTile({required this.metric, required this.showDivider});

  final _HealthMetric metric;
  final bool showDivider;

  @override
  Widget build(BuildContext context) {
    final effectiveValue = metric.measuring && metric.value == '-'
        ? 'Measuring'
        : metric.value;

    Widget? trailing;
    if (metric.start != null) {
      trailing = Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            effectiveValue,
            style: Theme.of(context).textTheme.headlineMedium?.copyWith(
              fontSize: 20,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
          if (metric.unit != null) ...[
            const SizedBox(width: 4),
            Text(metric.unit!, style: Theme.of(context).textTheme.bodySmall),
          ],
          const SizedBox(width: 8),
          IconButton(
            tooltip: 'Start ${metric.title}',
            icon: Icon(CupertinoIcons.play_fill, color: metric.tint),
            onPressed: metric.ready && !metric.measuring ? metric.start : null,
          ),
          IconButton(
            tooltip: 'Stop ${metric.title}',
            icon: Icon(CupertinoIcons.stop_fill, color: metric.tint),
            onPressed: metric.ready && metric.measuring ? metric.stop : null,
          ),
        ],
      );
    }

    return HealthListTile(
      title: metric.title,
      subtitle: metric.unit,
      value: metric.start == null ? effectiveValue : null,
      unit: metric.start == null ? null : metric.unit,
      leadingIcon: metric.icon,
      leadingColor: metric.tint,
      trailing: trailing,
      onTap: metric.onTap,
      showDivider: showDivider,
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
    this.onTap,
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
  final VoidCallback? onTap;
}
