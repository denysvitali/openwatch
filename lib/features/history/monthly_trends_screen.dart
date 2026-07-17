import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../core/providers/app_providers.dart';
import '../../core/services/monthly_trends.dart';
import '../../core/ui/ui_constants.dart';
import '../widgets/health_widgets.dart';
import 'widgets/monthly_bar_chart.dart';

/// Month-over-month view of the locally-stored health history.
///
/// Buckets every stored [DailyHistory] by calendar month (see
/// [MonthlyTrends]) and lets the user flip between metrics. Purely a read
/// view — it never triggers a sync, so it works fully offline against
/// whatever the history store already holds.
class MonthlyTrendsScreen extends ConsumerStatefulWidget {
  const MonthlyTrendsScreen({super.key});

  @override
  ConsumerState<MonthlyTrendsScreen> createState() =>
      _MonthlyTrendsScreenState();
}

class _MonthlyTrendsScreenState extends ConsumerState<MonthlyTrendsScreen> {
  TrendMetric _metric = TrendMetric.steps;

  @override
  Widget build(BuildContext context) {
    final sync = ref.watch(historySyncProvider);
    final trends = MonthlyTrends.fromDays(sync.days);

    return Scaffold(
      appBar: AppBar(title: const Text('Monthly trends')),
      body: MaxWidthContainer(
        child: trends.isEmpty
            ? _EmptyBody()
            : ListView(
                padding: const EdgeInsets.fromLTRB(
                  kCardPadding,
                  kSpacingSmall,
                  kCardPadding,
                  kSectionHeaderPaddingTop,
                ),
                children: [
                  _MetricSelector(
                    metric: _metric,
                    onChanged: (m) => setState(() => _metric = m),
                  ),
                  const SizedBox(height: kGridSpacing),
                  _ChartCard(metric: _metric, trends: trends),
                  const HealthSectionHeader(title: 'This month'),
                  _MonthSummaryCard(trends: trends),
                  const HealthSectionHeader(title: 'By month'),
                  _MonthListCard(trends: trends),
                ],
              ),
      ),
    );
  }
}

class _EmptyBody extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(kCardPadding),
      children: const [
        SizedBox(height: kSectionHeaderPaddingTop),
        EmptyState(
          icon: CupertinoIcons.chart_bar_alt_fill,
          title: 'No monthly data yet',
          caption:
              'Sync history from the History tab. Once a few days are '
              'stored, monthly trends appear here.',
        ),
      ],
    );
  }
}

/// Describes how to render one metric: label, tint, and how to pull a
/// comparable per-month value out of a [MonthlyTrend].
class _MetricSpec {
  const _MetricSpec({
    required this.label,
    required this.icon,
    required this.color,
    required this.value,
    required this.barLabel,
    required this.summaryValue,
    this.averageLine = true,
  });

  final String label;
  final IconData icon;
  final Color color;

  /// Comparable per-month magnitude, or null when the month lacks the metric.
  final num? Function(MonthlyTrend) value;

  /// Compact label drawn above a bar for a given raw value.
  final String Function(num) barLabel;

  /// Longer label for the summary card (e.g. "8,241 /day").
  final String Function(num) summaryValue;

  final bool averageLine;
}

_MetricSpec _specFor(TrendMetric metric, BuildContext context) {
  switch (metric) {
    case TrendMetric.steps:
      return _MetricSpec(
        label: 'Steps',
        icon: CupertinoIcons.arrow_up_right,
        color: kActivityGreen(context),
        value: (t) => t.stepsAvg,
        barLabel: _compactCount,
        summaryValue: (v) =>
            '${NumberFormat.decimalPattern().format(v.round())} /day',
      );
    case TrendMetric.sleep:
      return _MetricSpec(
        label: 'Sleep',
        icon: CupertinoIcons.moon_fill,
        color: kSleepPurple(context),
        value: (t) => t.sleepAvgMinutes,
        barLabel: (v) => _hours(v.toInt()),
        summaryValue: (v) => '${_hoursLong(v.toInt())} /night',
      );
    case TrendMetric.heartRate:
      return _MetricSpec(
        label: 'Heart rate',
        icon: CupertinoIcons.heart_fill,
        color: kHeartRed(context),
        value: (t) => t.hrAvg,
        barLabel: (v) => '${v.round()}',
        summaryValue: (v) => '${v.round()} bpm avg',
      );
    case TrendMetric.spo2:
      return _MetricSpec(
        label: 'SpO2',
        icon: CupertinoIcons.drop_fill,
        color: kSpo2Blue(context),
        value: (t) => t.spo2Avg,
        barLabel: (v) => '${v.round()}%',
        summaryValue: (v) => '${v.round()}% avg',
        averageLine: false,
      );
    case TrendMetric.stress:
      return _MetricSpec(
        label: 'Stress',
        icon: CupertinoIcons.bolt_fill,
        color: kStressOrange(context),
        value: (t) => t.stressAvg,
        barLabel: (v) => '${v.round()}',
        summaryValue: (v) => '${v.round()} avg',
      );
    case TrendMetric.hrv:
      return _MetricSpec(
        label: 'HRV',
        icon: CupertinoIcons.chart_bar_fill,
        color: kActivityGreen(context),
        value: (t) => t.hrvAvg,
        barLabel: (v) => '${v.round()}',
        summaryValue: (v) => '${v.round()} ms avg',
      );
  }
}

class _MetricSelector extends StatelessWidget {
  const _MetricSelector({required this.metric, required this.onChanged});

  final TrendMetric metric;
  final ValueChanged<TrendMetric> onChanged;

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: [
          for (final m in TrendMetric.values) ...[
            if (m != TrendMetric.values.first)
              const SizedBox(width: kSpacingSmall),
            _MetricChip(
              spec: _specFor(m, context),
              selected: m == metric,
              onTap: () => onChanged(m),
            ),
          ],
        ],
      ),
    );
  }
}

class _MetricChip extends StatelessWidget {
  const _MetricChip({
    required this.spec,
    required this.selected,
    required this.onTap,
  });

  final _MetricSpec spec;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final bg = selected
        ? spec.color
        : theme.colorScheme.surfaceContainerHighest;
    final fg = selected ? Colors.white : theme.colorScheme.onSurface;
    return Semantics(
      button: true,
      selected: selected,
      label: '${spec.label} trend',
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(
            horizontal: kGridSpacing,
            vertical: kSpacingSmall,
          ),
          decoration: BoxDecoration(
            color: bg,
            borderRadius: BorderRadius.circular(kChipRadius),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(spec.icon, size: kIconSizeTiny, color: fg),
              const SizedBox(width: kSpacingTiny),
              Text(
                spec.label,
                style: AppTextStyles.labelMedium(context)?.copyWith(
                  color: fg,
                  fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ChartCard extends StatelessWidget {
  const _ChartCard({required this.metric, required this.trends});

  final TrendMetric metric;
  final MonthlyTrends trends;

  @override
  Widget build(BuildContext context) {
    final spec = _specFor(metric, context);
    final recent = trends.recent(count: 6);
    final current = MonthKey.current();

    final bars = [
      for (final t in recent)
        MonthlyBar(
          month: t.month,
          value: (spec.value(t) ?? 0).toDouble(),
          label: () {
            final v = spec.value(t);
            return v == null ? '' : spec.barLabel(v);
          }(),
          isCurrent: t.month == current,
        ),
    ];

    final present = [
      for (final t in recent)
        if (spec.value(t) != null) spec.value(t)!.toDouble(),
    ];
    final average = !spec.averageLine || present.isEmpty
        ? null
        : present.reduce((a, b) => a + b) / present.length;

    final windowLabel = recent.isEmpty
        ? ''
        : '${_monthYear(recent.first.month)} - ${_monthYear(recent.last.month)}';

    return HealthCard(
      icon: spec.icon,
      title: '${spec.label} by month',
      metricColor: spec.color,
      caption: windowLabel,
      child: MonthlyBarChart(
        bars: bars,
        barColor: spec.color,
        averageValue: average,
        height: 160,
      ),
    );
  }
}

class _MonthSummaryCard extends StatelessWidget {
  const _MonthSummaryCard({required this.trends});

  final MonthlyTrends trends;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final latest = trends.latest;
    final previous = trends.previous;
    if (latest == null) return const SizedBox.shrink();

    return HealthCard(
      icon: CupertinoIcons.calendar,
      title: _monthYear(latest.month),
      metricColor: theme.colorScheme.primary,
      caption:
          '${latest.daysWithData} ${latest.daysWithData == 1 ? 'day' : 'days'} with data',
      child: Column(
        children: [
          for (final m in TrendMetric.values)
            _SummaryRow(
              spec: _specFor(m, context),
              latest: latest,
              previous: previous,
              showDivider: m != TrendMetric.values.last,
            ),
        ],
      ),
    );
  }
}

class _SummaryRow extends StatelessWidget {
  const _SummaryRow({
    required this.spec,
    required this.latest,
    required this.previous,
    required this.showDivider,
  });

  final _MetricSpec spec;
  final MonthlyTrend latest;
  final MonthlyTrend? previous;
  final bool showDivider;

  @override
  Widget build(BuildContext context) {
    final value = spec.value(latest);
    final prior = previous == null ? null : spec.value(previous!);
    final subtitle = _deltaLabel(value, prior);

    return HealthListTile(
      leadingIcon: spec.icon,
      leadingColor: spec.color,
      title: spec.label,
      subtitle: subtitle,
      value: value == null ? '-' : spec.summaryValue(value),
      showDivider: showDivider,
    );
  }

  String? _deltaLabel(num? value, num? prior) {
    if (value == null || prior == null || prior == 0) return null;
    final diff = value - prior;
    if (diff == 0) return 'No change vs last month';
    final pct = (diff / prior * 100).round();
    final arrow = diff > 0 ? '▲' : '▼';
    return '$arrow ${pct.abs()}% vs last month';
  }
}

class _MonthListCard extends StatelessWidget {
  const _MonthListCard({required this.trends});

  final MonthlyTrends trends;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final months = trends.months.reversed.toList();
    return HealthCard(
      metricColor: theme.colorScheme.onSurfaceVariant,
      child: Column(
        children: [
          for (var i = 0; i < months.length; i++)
            HealthListTile(
              leadingIcon: CupertinoIcons.calendar,
              leadingColor: theme.colorScheme.primary,
              title: _monthYear(months[i].month),
              subtitle: _stepsSummary(months[i]),
              value: months[i].sleepAvgMinutes == null
                  ? '-'
                  : _hoursLong(months[i].sleepAvgMinutes!),
              unit: months[i].sleepAvgMinutes == null ? null : 'sleep/night',
              showDivider: i != months.length - 1,
            ),
        ],
      ),
    );
  }

  String _stepsSummary(MonthlyTrend t) {
    final avg = t.stepsAvg;
    if (avg == null) return '${t.daysWithData} days · no steps';
    return '${NumberFormat.decimalPattern().format(avg)} steps/day · '
        '${t.daysWithData} days';
  }
}

String _monthYear(MonthKey m) =>
    DateFormat.yMMMM().format(DateTime(m.year, m.month));

String _compactCount(num v) {
  final n = v.round();
  if (n >= 1000) return '${(n / 1000).toStringAsFixed(n >= 10000 ? 0 : 1)}k';
  return '$n';
}

String _hours(int minutes) {
  final h = minutes / 60;
  return '${h.toStringAsFixed(h >= 10 ? 0 : 1)}h';
}

String _hoursLong(int minutes) {
  final h = minutes ~/ 60;
  final m = minutes.remainder(60);
  if (h == 0) return '${m}m';
  if (m == 0) return '${h}h';
  return '${h}h ${m}m';
}
