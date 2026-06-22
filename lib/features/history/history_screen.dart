import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../core/ble/ble_transport.dart';
import '../../core/providers/app_providers.dart';
import '../../core/services/history_sync.dart';
import 'widgets/hr_chart.dart';
import 'widgets/scalar_chart.dart';
import 'widgets/sleep_chart.dart';

/// Local-first history view.
class HistoryScreen extends ConsumerWidget {
  const HistoryScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ready = ref.watch(linkStateProvider).value == LinkState.ready;
    final sync = ref.watch(historySyncProvider);
    final store = ref.watch(historyStoreProvider).asData?.value;

    ref.listen<HistorySync>(historySyncProvider, (prev, next) {});

    return Scaffold(
      appBar: AppBar(
        title: const Text('History'),
        actions: [
          IconButton(
            icon: const Icon(CupertinoIcons.arrow_clockwise),
            tooltip: 'Sync now',
            onPressed: (ready && !sync.syncing) ? () => sync.syncAll() : null,
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: () => sync.syncAll(),
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 28),
          children: [
            if (sync.days.isNotEmpty) ...[
              _SectionTitle(
                title: 'Daily detail',
                trailing: '${sync.days.length} days',
              ),
              const SizedBox(height: 6),
              _DailyDetailSelector(
                days: sync.days.reversed.toList(),
                sync: sync,
              ),
            ] else
              const _EmptyState(),
            if (store == null) ...[const SizedBox(height: 16), _StoreWarning()],
          ],
        ),
      ),
    );
  }
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle({required this.title, required this.trailing});

  final String title;
  final String trailing;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      children: [
        Expanded(
          child: Text(
            title,
            style: theme.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
        Text(
          trailing,
          style: theme.textTheme.labelLarge?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ],
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 56),
      child: Column(
        children: [
          Container(
            width: 72,
            height: 72,
            decoration: BoxDecoration(
              color: theme.colorScheme.primary.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Icon(
              CupertinoIcons.chart_bar,
              size: 34,
              color: theme.colorScheme.primary,
            ),
          ),
          const SizedBox(height: 16),
          Text('No history yet', style: theme.textTheme.titleMedium),
          const SizedBox(height: 4),
          Text(
            'Tap sync after connecting your watch.',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}

class _StoreWarning extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return _InsetCard(
      child: Row(
        children: [
          Icon(Icons.storage_rounded, color: theme.colorScheme.tertiary),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              'Local store unavailable. History will stay in memory until storage finishes initialising.',
              style: theme.textTheme.bodySmall,
            ),
          ),
        ],
      ),
    );
  }
}

class _DailyDetailSelector extends StatefulWidget {
  const _DailyDetailSelector({required this.days, required this.sync});

  final List<DailyHistory> days;
  final HistorySync sync;

  @override
  State<_DailyDetailSelector> createState() => _DailyDetailSelectorState();
}

class _DailyDetailSelectorState extends State<_DailyDetailSelector> {
  int _index = 0;

  @override
  void didUpdateWidget(_DailyDetailSelector oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (_index >= widget.days.length) {
      _index = widget.days.length - 1;
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final current = widget.days[_index.clamp(0, widget.days.length - 1)];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            IconButton(
              tooltip: 'Newer day',
              icon: const Icon(CupertinoIcons.chevron_left),
              onPressed: _index > 0 ? () => setState(() => _index--) : null,
            ),
            Expanded(
              child: DropdownButtonHideUnderline(
                child: DropdownButton<int>(
                  value: _index,
                  isExpanded: true,
                  borderRadius: BorderRadius.circular(8),
                  items: [
                    for (var i = 0; i < widget.days.length; i++)
                      DropdownMenuItem(
                        value: i,
                        child: Row(
                          children: [
                            Expanded(
                              child: Text(_formatDayTab(widget.days[i].day)),
                            ),
                            if (widget.sync.fetchedDays.contains(
                              widget.days[i].day,
                            ))
                              const _NewDot(),
                          ],
                        ),
                      ),
                  ],
                  onChanged: (value) {
                    if (value == null) return;
                    setState(() => _index = value);
                  },
                ),
              ),
            ),
            IconButton(
              tooltip: 'Older day',
              icon: const Icon(CupertinoIcons.chevron_right),
              onPressed: _index < widget.days.length - 1
                  ? () => setState(() => _index++)
                  : null,
            ),
          ],
        ),
        Divider(color: theme.colorScheme.outlineVariant),
        AnimatedSize(
          duration: const Duration(milliseconds: 180),
          curve: Curves.easeOutCubic,
          alignment: Alignment.topCenter,
          child: AnimatedSwitcher(
            duration: const Duration(milliseconds: 160),
            child: _DayDetailPage(
              key: ValueKey(current.day.iso),
              day: current,
              sync: widget.sync,
            ),
          ),
        ),
      ],
    );
  }
}

class _NewDot extends StatelessWidget {
  const _NewDot();

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.primary,
        shape: BoxShape.circle,
      ),
      child: const SizedBox(width: 6, height: 6),
    );
  }
}

class _DayDetailPage extends StatelessWidget {
  const _DayDetailPage({super.key, required this.day, required this.sync});

  final DailyHistory day;
  final HistorySync sync;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isToday = day.day == DateOnly.today();
    final isEmpty = _isEmpty(day);

    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      _formatDayHeader(day.day),
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    if (day.lastUpdated != null)
                      Text(
                        'Updated ${DateFormat.jm().format(day.lastUpdated!)}',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                  ],
                ),
              ),
              if (sync.fetchedDays.contains(day.day)) _NewBadge(),
            ],
          ),
          const SizedBox(height: 14),
          if (isEmpty)
            Text(
              isToday ? 'No data today' : 'No watch data',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            )
          else ...[
            Wrap(
              spacing: 10,
              runSpacing: 8,
              children: [
                _MetricPill(
                  icon: CupertinoIcons.heart_fill,
                  label: day.hr.isEmpty ? '-' : '${_avgBpm(day.hr)} bpm',
                  tint: const Color(0xFFFF3B30),
                ),
                _MetricPill(
                  icon: CupertinoIcons.moon_fill,
                  label: _sleepSummary(day),
                  tint: const Color(0xFF5856D6),
                ),
                _MetricPill(
                  icon: CupertinoIcons.arrow_up_right,
                  label: day.steps == null
                      ? '-'
                      : NumberFormat.compact().format(day.steps),
                  tint: theme.colorScheme.primary,
                ),
                _MetricPill(
                  icon: CupertinoIcons.bolt_fill,
                  label: day.stress.isEmpty
                      ? '-'
                      : '${_avgValue(day.stress)} stress',
                  tint: const Color(0xFFFF9500),
                ),
                _MetricPill(
                  icon: CupertinoIcons.chart_bar_fill,
                  label: day.hrv.isEmpty ? '-' : '${_avgValue(day.hrv)} ms',
                  tint: const Color(0xFF34C759),
                ),
                _MetricPill(
                  icon: CupertinoIcons.waveform_path_ecg,
                  label: day.bloodPressure.isEmpty
                      ? '-'
                      : _formatBp(day.bloodPressure.last),
                  tint: const Color(0xFFFF3B30),
                ),
              ],
            ),
            if (day.hr.isNotEmpty) ...[
              const SizedBox(height: 20),
              _ChartHeader(
                title: 'Heart rate',
                detail: '${_avgBpm(day.hr)} bpm avg',
              ),
              const SizedBox(height: 10),
              SizedBox(height: 184, child: HrLineChart(samples: day.hr)),
            ] else ...[
              const SizedBox(height: 20),
              SizedBox(
                height: 64,
                child: Center(
                  child: Text(
                    'No heart-rate samples',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ),
            ],
            if (day.sleep.isNotEmpty) ...[
              const SizedBox(height: 20),
              _ChartHeader(title: 'Sleep', detail: _sleepLongSummary(day)),
              const SizedBox(height: 10),
              SleepTimeline(segments: day.sleep, height: 110),
            ],
            if (day.stress.isNotEmpty ||
                day.hrv.isNotEmpty ||
                day.bloodPressure.isNotEmpty) ...[
              const SizedBox(height: 20),
              _ChartHeader(title: 'Other metrics', detail: 'Synced values'),
              const SizedBox(height: 10),
              if (day.stress.isNotEmpty) ...[
                _ChartHeader(
                  title: 'Stress',
                  detail: _scalarRange(day.stress),
                ),
                const SizedBox(height: 8),
                SizedBox(
                  height: 132,
                  child: ScalarMetricChart(
                    samples: day.stress,
                    color: const Color(0xFFFF9500),
                    minValue: 0,
                    maxValue: 100,
                  ),
                ),
                const SizedBox(height: 14),
              ],
              if (day.hrv.isNotEmpty) ...[
                _ChartHeader(title: 'HRV', detail: _scalarRange(day.hrv)),
                const SizedBox(height: 8),
                SizedBox(
                  height: 132,
                  child: ScalarMetricChart(
                    samples: day.hrv,
                    color: const Color(0xFF34C759),
                  ),
                ),
                const SizedBox(height: 14),
              ],
              _MetricValueList(day: day),
            ],
          ],
        ],
      ),
    );
  }
}

bool _isEmpty(DailyHistory day) =>
    day.hr.isEmpty &&
    day.sleep.isEmpty &&
    day.stress.isEmpty &&
    day.hrv.isEmpty &&
    day.bloodPressure.isEmpty &&
    day.steps == null;

String _formatDayTab(DateOnly d) {
  final today = DateOnly.today();
  if (d == today) return 'Today';
  if (d == today.addDays(-1)) return 'Yesterday';
  return DateFormat.MMMd().format(d.midnight);
}

String _formatDayHeader(DateOnly d) {
  final today = DateOnly.today();
  if (d == today) return 'Today · ${DateFormat.MMMd().format(d.midnight)}';
  if (d == today.addDays(-1)) {
    return 'Yesterday · ${DateFormat.MMMd().format(d.midnight)}';
  }
  return DateFormat('EEEE · MMM d').format(d.midnight);
}

int _avgBpm(List<HrSample> samples) {
  if (samples.isEmpty) return 0;
  final sum = samples.fold<int>(0, (a, s) => a + s.bpm);
  return (sum / samples.length).round();
}

int _avgValue(List<HealthMetricSample> samples) {
  if (samples.isEmpty) return 0;
  final sum = samples.fold<int>(0, (a, s) => a + s.value);
  return (sum / samples.length).round();
}

String _formatBp(BloodPressureSample sample) =>
    '${sample.systolic}/${sample.diastolic}';

String _sleepSummary(DailyHistory day) {
  if (day.sleep.isEmpty) return '-';
  final total = day.sleep.fold<Duration>(
    Duration.zero,
    (a, s) => a + s.duration,
  );
  final h = total.inHours;
  final m = total.inMinutes.remainder(60);
  return '${h}h ${m}m';
}

String _sleepLongSummary(DailyHistory day) {
  final byStage = <SleepStage, Duration>{};
  for (final s in day.sleep) {
    byStage[s.stage] = (byStage[s.stage] ?? Duration.zero) + s.duration;
  }
  final parts = <String>[];
  for (final s in [
    SleepStage.deep,
    SleepStage.light,
    SleepStage.rem,
    SleepStage.awake,
  ]) {
    final d = byStage[s];
    if (d == null || d == Duration.zero) continue;
    final h = d.inMinutes ~/ 60;
    final m = d.inMinutes.remainder(60);
    parts.add('${_label(s)} ${h}h ${m}m');
  }
  return parts.join(' · ');
}

String _label(SleepStage s) => switch (s) {
  SleepStage.awake => 'Awake',
  SleepStage.rem => 'REM',
  SleepStage.light => 'Light',
  SleepStage.deep => 'Deep',
};

class _ChartHeader extends StatelessWidget {
  const _ChartHeader({required this.title, required this.detail});

  final String title;
  final String detail;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      children: [
        Expanded(child: Text(title, style: theme.textTheme.titleSmall)),
        Flexible(
          child: Text(
            detail,
            textAlign: TextAlign.end,
            style: theme.textTheme.labelMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ],
    );
  }
}

class _MetricPill extends StatelessWidget {
  const _MetricPill({
    required this.icon,
    required this.label,
    required this.tint,
  });

  final IconData icon;
  final String label;
  final Color tint;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
      decoration: BoxDecoration(
        color: tint.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 15, color: tint),
          const SizedBox(width: 6),
          Text(label, style: theme.textTheme.labelMedium),
        ],
      ),
    );
  }
}

class _MetricValueList extends StatelessWidget {
  const _MetricValueList({required this.day});

  final DailyHistory day;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final rows = <Widget>[
      if (day.stress.isNotEmpty)
        _MetricValueRow(
          icon: CupertinoIcons.bolt_fill,
          title: 'Stress',
          detail: _scalarRange(day.stress),
          value: _latestScalar(day.stress),
          tint: const Color(0xFFFF9500),
        ),
      if (day.hrv.isNotEmpty)
        _MetricValueRow(
          icon: CupertinoIcons.chart_bar_fill,
          title: 'HRV',
          detail: _scalarRange(day.hrv, unit: 'ms'),
          value: '${day.hrv.last.value} ms',
          tint: const Color(0xFF34C759),
        ),
      if (day.bloodPressure.isNotEmpty)
        _MetricValueRow(
          icon: CupertinoIcons.waveform_path_ecg,
          title: 'Blood pressure',
          detail: DateFormat.jm().format(day.bloodPressure.last.timestamp),
          value: '${_formatBp(day.bloodPressure.last)} mmHg',
          tint: const Color(0xFFFF3B30),
        ),
    ];

    return Card(
      child: Column(
        children: [
          for (var i = 0; i < rows.length; i++) ...[
            rows[i],
            if (i != rows.length - 1)
              Divider(
                height: 1,
                indent: 56,
                color: theme.colorScheme.outlineVariant.withValues(alpha: 0.7),
              ),
          ],
        ],
      ),
    );
  }
}

class _MetricValueRow extends StatelessWidget {
  const _MetricValueRow({
    required this.icon,
    required this.title,
    required this.detail,
    required this.value,
    required this.tint,
  });

  final IconData icon;
  final String title;
  final String detail;
  final String value;
  final Color tint;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListTile(
      leading: Icon(icon, color: tint),
      title: Text(title),
      subtitle: Text(detail),
      trailing: Text(
        value,
        style: theme.textTheme.titleMedium?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }
}

String _scalarRange(List<HealthMetricSample> samples, {String unit = ''}) {
  final values = samples.map((s) => s.value).toList();
  final min = values.reduce((a, b) => a < b ? a : b);
  final max = values.reduce((a, b) => a > b ? a : b);
  final suffix = unit.isEmpty ? '' : ' $unit';
  return '${samples.length} samples · min $min$suffix · '
      'avg ${_avgValue(samples)}$suffix · max $max$suffix';
}

String _latestScalar(List<HealthMetricSample> samples) =>
    '${samples.last.value} · ${DateFormat.jm().format(samples.last.timestamp)}';

class _NewBadge extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(
          color: theme.colorScheme.primary.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Text(
          'New',
          style: theme.textTheme.labelSmall?.copyWith(
            color: theme.colorScheme.primary,
            fontWeight: FontWeight.w700,
          ),
        ),
      ),
    );
  }
}

class _InsetCard extends StatelessWidget {
  const _InsetCard({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(padding: const EdgeInsets.all(16), child: child),
    );
  }
}
