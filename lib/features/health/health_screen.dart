import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/providers/app_providers.dart';
import '../../core/ui/app_colors.dart';
import '../../core/ui/ui_constants.dart';
import '../widgets/health_widgets.dart';

/// Live measure hub. Heart rate is the hero; other metrics are capability-gated.
class HealthScreen extends ConsumerWidget {
  const HealthScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = AppColors.of(context);
    final manager = ref.watch(watchManagerProvider);
    final ready = manager.isReady;
    final caps = manager.capabilities;
    final hrSupported = caps.heart;
    final bpSystolic = manager.lastBloodPressureSystolic;
    final bpDiastolic = manager.lastBloodPressureDiastolic;
    final bpValue = bpSystolic == null || bpDiastolic == null
        ? '—'
        : '$bpSystolic/$bpDiastolic';

    final metrics = <_HealthMetric>[
      if (caps.bloodOxygen)
        _HealthMetric(
          icon: CupertinoIcons.drop_fill,
          title: 'Blood oxygen',
          value: '—',
          unit: '%',
          tint: colors.spo2,
          subtitle: 'View trends in History',
          onTap: () => context.go('/history'),
        ),
      if (caps.bloodPressure)
        _HealthMetric(
          icon: CupertinoIcons.waveform_path_ecg,
          title: 'Blood pressure',
          value: bpValue,
          unit: 'mmHg',
          tint: colors.heart,
          ready: ready,
          measuring: manager.measuringBloodPressure,
          start: manager.startBloodPressure,
          stop: manager.stopBloodPressure,
        ),
      if (caps.sleep)
        _HealthMetric(
          icon: CupertinoIcons.moon_fill,
          title: 'Sleep',
          value: 'View',
          unit: 'history',
          tint: colors.sleep,
          subtitle: 'Stages and sessions',
          onTap: () => context.go('/history'),
        ),
      if (caps.stress)
        _HealthMetric(
          icon: CupertinoIcons.bolt_fill,
          title: 'Stress',
          value: manager.lastStress?.toString() ?? '—',
          tint: colors.stress,
          ready: ready,
          measuring: manager.measuringStress,
          start: manager.startStress,
          stop: manager.stopStress,
        ),
      if (caps.hrv)
        _HealthMetric(
          icon: CupertinoIcons.chart_bar_fill,
          title: 'HRV',
          value: manager.lastHrv?.toString() ?? '—',
          unit: 'ms',
          tint: colors.hrv,
          ready: ready,
          measuring: manager.measuringHrv,
          start: manager.startHrv,
          stop: manager.stopHrv,
        ),
      if (caps.temperature)
        _HealthMetric(
          icon: CupertinoIcons.thermometer,
          title: 'Temperature',
          value: '—',
          unit: '°C',
          tint: colors.nutrition,
          subtitle: 'View trends in History',
          onTap: () => context.go('/history'),
        ),
    ];

    return Scaffold(
      appBar: AppBar(title: const Text('Health')),
      body: MaxWidthContainer(
        child: ListView(
          padding: kScreenListPadding,
          children: [
            _HeartRateHero(
              bpm: manager.lastHeartRate,
              supported: hrSupported,
              ready: ready,
              measuring: manager.measuringHeartRate,
              start: manager.startHeartRate,
              stop: manager.stopHeartRate,
              metricColor: colors.heart,
              onViewHistory: () => context.go('/history'),
            ),
            const HealthSectionHeader(title: 'Available metrics'),
            _MetricList(metrics: metrics),
          ],
        ),
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
    required this.metricColor,
    required this.onViewHistory,
  });

  final int? bpm;
  final bool supported;
  final bool ready;
  final bool measuring;
  final VoidCallback start;
  final VoidCallback stop;
  final Color metricColor;
  final VoidCallback onViewHistory;

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
      value: bpm == null ? '—' : '$bpm',
      unit: bpm == null ? null : 'bpm',
      caption: statusText,
      icon: CupertinoIcons.heart_fill,
      metricColor: metricColor,
      trailing: AnimatedHeartBadge(
        color: metricColor,
        isAnimating: supported && ready && measuring,
        size: kIconCircleSizeSmall,
        iconSize: kIconSizeSmall,
      ),
      child: Padding(
        padding: const EdgeInsets.only(top: kCardInternalSpacing),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: PrimaryHealthButton(
                    label: measuring ? 'Measuring…' : 'Start',
                    icon: CupertinoIcons.play_fill,
                    onPressed: ready && supported && !measuring ? start : null,
                  ),
                ),
                const SizedBox(width: kGridSpacing),
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
            const SizedBox(height: kSpacingSmall),
            TextButton(
              onPressed: onViewHistory,
              child: const Text('See history charts'),
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

    return InsetCard(
      padding: EdgeInsets.zero,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (var i = 0; i < metrics.length; i++)
            _MetricTile(
              metric: metrics[i],
              showDivider: i != metrics.length - 1,
            ),
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
    final theme = Theme.of(context);
    final effectiveValue =
        metric.measuring && (metric.value == '—' || metric.value == '-')
        ? 'Measuring'
        : metric.value;

    Widget? trailing;
    if (metric.start != null) {
      trailing = Row(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Row(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Text(
                effectiveValue,
                style: AppTextStyles.titleLarge(
                  context,
                )?.copyWith(color: theme.colorScheme.onSurfaceVariant),
              ),
              if (metric.unit != null) ...[
                const SizedBox(width: kSpacingTiny),
                Text(
                  metric.unit!,
                  style: AppTextStyles.bodySmall(
                    context,
                  )?.copyWith(height: 1.0),
                ),
              ],
            ],
          ),
          const SizedBox(width: kSpacingSmall),
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
      subtitle: metric.subtitle ?? metric.unit,
      value: metric.start == null ? effectiveValue : null,
      unit:
          metric.start == null && metric.unit != null && metric.subtitle == null
          ? metric.unit
          : null,
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
    this.subtitle,
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
  final String? subtitle;
  final bool ready;
  final bool measuring;
  final VoidCallback? start;
  final VoidCallback? stop;
  final VoidCallback? onTap;
}
