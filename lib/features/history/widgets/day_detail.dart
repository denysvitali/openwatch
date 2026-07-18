import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';

import '../../../core/ui/ui_constants.dart';
import '../../widgets/health_widgets.dart';
import '../../../core/services/history_debug_export.dart';
import '../../../core/services/history_sync.dart';
import '../sleep_session_summary.dart';
import 'hr_chart.dart';
import 'sleep_chart.dart';
import 'scalar_chart.dart';
import '../hr_slots.dart';

class DailyDetailSelector extends _DailyDetailSelector {
  const DailyDetailSelector({
    super.key,
    required super.days,
    required super.sync,
    required super.debugContext,
  });
}

class _DailyDetailSelector extends StatefulWidget {
  const _DailyDetailSelector({
    super.key,
    required this.days,
    required this.sync,
    required this.debugContext,
  });

  final List<DailyHistory> days;
  final HistorySync sync;
  final HistoryDebugContext debugContext;

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
        Container(
          padding: const EdgeInsets.symmetric(vertical: kSpacingTiny),
          decoration: BoxDecoration(
            color: theme.colorScheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(kPillRadius),
          ),
          child: Row(
            children: [
              IconButton(
                tooltip: 'Newer day',
                icon: const Icon(
                  CupertinoIcons.chevron_left,
                  size: kIconSizeSmall,
                ),
                padding: EdgeInsets.zero,
                onPressed: _index > 0 ? () => setState(() => _index--) : null,
              ),
              Expanded(
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(
                    children: [
                      for (var i = 0; i < widget.days.length; i++) ...[
                        if (i > 0) const SizedBox(width: kSpacingTiny),
                        _DayChip(
                          label: _formatDayTab(widget.days[i].day),
                          selected: i == _index,
                          hasNewData: widget.sync.fetchedDays.contains(
                            widget.days[i].day,
                          ),
                          onTap: () => setState(() => _index = i),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
              IconButton(
                tooltip: 'Older day',
                icon: const Icon(
                  CupertinoIcons.chevron_right,
                  size: kIconSizeSmall,
                ),
                padding: EdgeInsets.zero,
                onPressed: _index < widget.days.length - 1
                    ? () => setState(() => _index++)
                    : null,
              ),
            ],
          ),
        ),
        const SizedBox(height: kGridSpacing),
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
              debugContext: widget.debugContext,
              freshlyFetched: widget.sync.fetchedDays.contains(current.day),
            ),
          ),
        ),
      ],
    );
  }
}

class _DayChip extends StatelessWidget {
  const _DayChip({
    required this.label,
    required this.selected,
    required this.hasNewData,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final bool hasNewData;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final bgColor = selected ? theme.colorScheme.primary : Colors.transparent;
    final fgColor = selected
        ? theme.colorScheme.onPrimary
        : theme.colorScheme.onSurface;
    return Semantics(
      button: true,
      selected: selected,
      label: label,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(kChipRadius),
        child: Container(
          padding: EdgeInsets.symmetric(
            horizontal: kChipPaddingH,
            vertical: kChipPaddingV + 8,
          ),
          decoration: BoxDecoration(
            color: bgColor,
            borderRadius: BorderRadius.circular(kChipRadius),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                label,
                style: AppTextStyles.labelMedium(context)?.copyWith(
                  color: fgColor,
                  fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                ),
              ),
              if (hasNewData) ...[
                const SizedBox(width: kSpacingTiny),
                Container(
                  width: 6,
                  height: 6,
                  decoration: BoxDecoration(
                    color: selected
                        ? theme.colorScheme.onPrimary
                        : theme.colorScheme.primary,
                    shape: BoxShape.circle,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _DayDetailPage extends StatelessWidget {
  const _DayDetailPage({
    super.key,
    required this.day,
    required this.sync,
    required this.debugContext,
    required this.freshlyFetched,
  });

  final DailyHistory day;
  final HistorySync sync;
  final HistoryDebugContext debugContext;
  final bool freshlyFetched;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final displayDay = _displayDayForNow(day, DateTime.now());
    final isToday = displayDay.day == DateOnly.today();
    final isEmpty = _isEmpty(displayDay);

    return Padding(
      padding: const EdgeInsets.only(bottom: kSpacingSmall),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Expanded(
                child: Text(
                  _formatDayHeader(displayDay.day),
                  style: AppTextStyles.titleMedium(
                    context,
                  )?.copyWith(fontWeight: FontWeight.w700),
                ),
              ),
              IconButton(
                tooltip: 'Copy day debug',
                icon: const Icon(
                  Icons.bug_report_outlined,
                  size: kIconSizeSmall,
                ),
                padding: EdgeInsets.zero,
                onPressed: () {
                  final ctx = debugContext;
                  final fresh = freshlyFetched;
                  _copyDayDebug(context, day, ctx, fresh);
                },
              ),
              if (freshlyFetched) const _NewBadge(),
            ],
          ),
          if (displayDay.lastUpdated != null)
            Text(
              'Updated ${DateFormat.jm().format(displayDay.lastUpdated!)}',
              style: AppTextStyles.bodySmall(
                context,
              )?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
          const SizedBox(height: kGridSpacing),
          if (isEmpty)
            HealthCard(
              metricColor: theme.colorScheme.onSurfaceVariant,
              child: Row(
                children: [
                  Icon(
                    CupertinoIcons.chart_bar,
                    size: kIconSizeSmall,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                  const SizedBox(width: kGridSpacing),
                  Text(
                    isToday ? 'No data today' : 'No watch data',
                    style: AppTextStyles.bodyMedium(
                      context,
                    )?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                  ),
                ],
              ),
            )
          else ...[
            HealthCard(
              icon: CupertinoIcons.heart_fill,
              title: 'Daily summary',
              metricColor: theme.colorScheme.onSurfaceVariant,
              child: Column(
                children: [
                  HealthListTile(
                    leadingIcon: CupertinoIcons.heart_fill,
                    leadingColor: kHeartRed(context),
                    title: 'Heart rate',
                    subtitle: displayDay.hr.isEmpty
                        ? 'No samples'
                        : '${displayDay.hr.length} samples',
                    value: displayDay.hr.isEmpty
                        ? '-'
                        : '${avgBpm(displayDay.hr)}',
                    unit: 'bpm',
                    showDivider: true,
                  ),
                  HealthListTile(
                    leadingIcon: CupertinoIcons.moon_fill,
                    leadingColor: kSleepPurple(context),
                    title: 'Sleep',
                    subtitle: displayDay.sleep.isEmpty
                        ? 'No sessions'
                        : '${SleepSessionSummary.fromSegments(displayDay.sleep).length} sessions',
                    value: displayDay.sleep.isEmpty
                        ? '-'
                        : _sleepDuration(
                            displayDay.sleep.fold<Duration>(
                              Duration.zero,
                              (a, s) => a + s.duration,
                            ),
                          ),
                    showDivider: true,
                  ),
                  HealthListTile(
                    leadingIcon: CupertinoIcons.arrow_up_right,
                    leadingColor: kActivityGreen(context),
                    title: 'Steps',
                    subtitle: displayDay.steps == null ? 'No step total' : null,
                    value: displayDay.steps == null
                        ? '-'
                        : NumberFormat.compact().format(displayDay.steps),
                    showDivider: true,
                  ),
                  HealthListTile(
                    leadingIcon: CupertinoIcons.drop_fill,
                    leadingColor: kSpo2Blue(context),
                    title: 'Blood oxygen',
                    subtitle: displayDay.spo2Max == null
                        ? 'No hourly SpO2'
                        : '${displayDay.spo2Hours.where((s) => s.hasData).length} hours',
                    value: displayDay.spo2Max == null
                        ? '-'
                        : '${displayDay.spo2Min}-${displayDay.spo2Max}',
                    unit: '%',
                    showDivider: true,
                  ),
                  HealthListTile(
                    leadingIcon: CupertinoIcons.bolt_fill,
                    leadingColor: kStressOrange(context),
                    title: 'Stress',
                    subtitle: displayDay.stress.isEmpty
                        ? 'No samples'
                        : _scalarRange(displayDay.stress),
                    value: displayDay.stress.isEmpty
                        ? '-'
                        : '${avgValue(displayDay.stress).round()}',
                    unit: 'avg',
                    showDivider: true,
                  ),
                  HealthListTile(
                    leadingIcon: CupertinoIcons.chart_bar_fill,
                    leadingColor: kActivityGreen(context),
                    title: 'HRV',
                    subtitle: displayDay.hrv.isEmpty
                        ? 'No samples'
                        : _scalarRange(displayDay.hrv, unit: 'ms'),
                    value: displayDay.hrv.isEmpty
                        ? '-'
                        : '${avgValue(displayDay.hrv).round()}',
                    unit: 'ms',
                    showDivider: true,
                  ),
                  HealthListTile(
                    leadingIcon: CupertinoIcons.waveform_path_ecg,
                    leadingColor: kHeartRed(context),
                    title: 'Blood pressure',
                    subtitle: displayDay.bloodPressure.isEmpty
                        ? 'No readings'
                        : _bpMetricDetail(displayDay.bloodPressure),
                    value: displayDay.bloodPressure.isEmpty
                        ? '-'
                        : _bpMetricValue(
                            displayDay.bloodPressure,
                          ).replaceAll(' mmHg', ''),
                    unit: displayDay.bloodPressure.isEmpty ? null : 'mmHg',
                    showDivider: false,
                  ),
                ],
              ),
            ),
            if (displayDay.hr.isNotEmpty) ...[
              const SizedBox(height: kGridSpacing),
              HealthCard(
                icon: CupertinoIcons.heart_fill,
                title: 'Heart rate',
                metricColor: kHeartRed(context),
                caption: '${avgBpm(displayDay.hr)} bpm average',
                child: SizedBox(
                  height: 160,
                  child: HrLineChart(
                    samples: displayDay.hr,
                    color: kHeartRed(context),
                  ),
                ),
              ),
            ],
            if (displayDay.sleep.isNotEmpty) ...[
              const SizedBox(height: kGridSpacing),
              HealthCard(
                icon: CupertinoIcons.moon_fill,
                title: 'Sleep',
                metricColor: kSleepPurple(context),
                caption:
                    'Total ${_sleepSummary(displayDay)} · ${_sleepLongSummary(displayDay)}',
                child: Builder(
                  builder: (context) {
                    final sessions = SleepSessionSummary.fromSegments(
                      displayDay.sleep,
                    );
                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        SleepTimeline(segments: displayDay.sleep, height: 100),
                        const SizedBox(height: kGridSpacing),
                        ...sessions.asMap().entries.map(
                          (e) => HealthListTile(
                            leadingIcon: CupertinoIcons.moon_fill,
                            leadingColor: kSleepPurple(context),
                            title: 'Session ${e.key + 1}',
                            subtitle:
                                '${DateFormat.jm().format(e.value.start)} - '
                                '${DateFormat.jm().format(e.value.end)}',
                            value: _sleepDuration(e.value.duration),
                            showDivider: e.key != sessions.length - 1,
                          ),
                        ),
                      ],
                    );
                  },
                ),
              ),
            ],
            if (displayDay.stress.isNotEmpty) ...[
              const SizedBox(height: kGridSpacing),
              HealthCard(
                icon: CupertinoIcons.bolt_fill,
                title: 'Stress',
                metricColor: kStressOrange(context),
                caption: _scalarRange(displayDay.stress),
                child: SizedBox(
                  height: 120,
                  child: ScalarMetricChart(
                    samples: displayDay.stress,
                    color: kStressOrange(context),
                    minValue: 0,
                    maxValue: 100,
                  ),
                ),
              ),
            ],
            if (displayDay.hrv.isNotEmpty) ...[
              const SizedBox(height: kGridSpacing),
              HealthCard(
                icon: CupertinoIcons.chart_bar_fill,
                title: 'HRV',
                metricColor: kActivityGreen(context),
                caption: _scalarRange(displayDay.hrv, unit: 'ms'),
                child: SizedBox(
                  height: 120,
                  child: ScalarMetricChart(
                    samples: displayDay.hrv,
                    color: kActivityGreen(context),
                  ),
                ),
              ),
            ],
            if (displayDay.bloodPressure.isNotEmpty) ...[
              const SizedBox(height: kGridSpacing),
              HealthCard(
                icon: CupertinoIcons.waveform_path_ecg,
                title: 'Blood pressure',
                metricColor: kHeartRed(context),
                caption: _bpMetricDetail(displayDay.bloodPressure),
                child: SizedBox(
                  height: 120,
                  child: ScalarMetricChart(
                    samples: [
                      for (final bp in displayDay.bloodPressure)
                        if (!_isRawBpSlot(bp))
                          HealthMetricSample(bp.timestamp, bp.systolic),
                    ],
                    color: kHeartRed(context),
                  ),
                ),
              ),
            ],
          ],
        ],
      ),
    );
  }
}

DailyHistory _displayDayForNow(DailyHistory day, DateTime now) {
  final dayStart = day.day.midnight;
  final dayEnd = dayStart
      .add(const Duration(days: 1))
      .subtract(const Duration(microseconds: 1));
  final end = now.isBefore(dayEnd) ? now : dayEnd;
  return day.copyWith(
    hr: clipAndDedupeHr(day.hr, dayStart, end),
    stress: _clipScalar(day.stress, end),
    hrv: _clipScalar(day.hrv, end),
    bloodPressure: _clipBp(day.bloodPressure, end),
  );
}

bool _isEmpty(DailyHistory day) =>
    day.hr.isEmpty &&
    day.sleep.isEmpty &&
    day.stress.isEmpty &&
    day.hrv.isEmpty &&
    day.bloodPressure.isEmpty &&
    day.spo2Max == null &&
    day.steps == null;

List<HealthMetricSample> _clipScalar(
  List<HealthMetricSample> samples,
  DateTime now,
) {
  return [
    for (final sample in samples)
      if (!sample.timestamp.isAfter(now)) sample,
  ];
}

List<BloodPressureSample> _clipBp(
  List<BloodPressureSample> samples,
  DateTime now,
) {
  return [
    for (final sample in samples)
      if (!sample.timestamp.isAfter(now)) sample,
  ];
}

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

String _formatBp(BloodPressureSample sample) =>
    '${sample.systolic}/${sample.diastolic}';

bool _isRawBpSlot(BloodPressureSample sample) =>
    sample.systolic == 0 && sample.diastolic == 0;

BloodPressureSample? _latestDecodedBp(List<BloodPressureSample> samples) {
  for (final sample in samples.reversed) {
    if (!_isRawBpSlot(sample)) return sample;
  }
  return null;
}

String _bpMetricDetail(List<BloodPressureSample> samples) {
  final decoded = _latestDecodedBp(samples);
  if (decoded != null) return DateFormat.jm().format(decoded.timestamp);
  return 'Raw compact BP history';
}

String _bpMetricValue(List<BloodPressureSample> samples) {
  final decoded = _latestDecodedBp(samples);
  if (decoded != null) return '${_formatBp(decoded)} mmHg';
  return '${samples.length} raw ${samples.length == 1 ? 'slot' : 'slots'}';
}

String _sleepSummary(DailyHistory day) {
  if (day.sleep.isEmpty) return '-';
  final total = day.sleep.fold<Duration>(
    Duration.zero,
    (a, s) => a + s.duration,
  );
  return _sleepDuration(total);
}

Future<void> _copyDayDebug(
  BuildContext context,
  DailyHistory day,
  HistoryDebugContext debugCtx,
  bool freshlyFetched,
) async {
  final messenger = ScaffoldMessenger.of(context);
  final ctx = HistoryDebugContext(
    firmware: debugCtx.firmware,
    hardware: debugCtx.hardware,
    linkState: debugCtx.linkState,
    lastSyncedAt: debugCtx.lastSyncedAt,
    lastSyncedDayIso: debugCtx.lastSyncedDayIso,
    fetched: freshlyFetched,
  );
  final text = HistoryDebugExport.formatDay(day, context: ctx);
  await Clipboard.setData(ClipboardData(text: text));
  if (!context.mounted) return;
  final kb = (text.length / 1024).toStringAsFixed(1);
  messenger.showSnackBar(
    SnackBar(content: Text('Day debug copied (${text.length} chars / $kb kB)')),
  );
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
    parts.add('${_label(s)} ${_sleepDuration(d)}');
  }
  return parts.join(' · ');
}

String _sleepDuration(Duration duration) {
  final h = duration.inMinutes ~/ 60;
  final m = duration.inMinutes.remainder(60);
  if (h == 0) return '${m}m';
  if (m == 0) return '${h}h';
  return '${h}h ${m}m';
}

String _label(SleepStage s) => switch (s) {
  SleepStage.awake => 'Awake',
  SleepStage.rem => 'REM',
  SleepStage.light => 'Light',
  SleepStage.deep => 'Deep',
};

String _scalarRange(List<HealthMetricSample> samples, {String unit = ''}) {
  final values = samples.map((s) => s.value).toList();
  final min = values.reduce((a, b) => a < b ? a : b);
  final max = values.reduce((a, b) => a > b ? a : b);
  final suffix = unit.isEmpty ? '' : ' $unit';
  return '${samples.length} samples · min $min$suffix · '
      'avg ${avgValue(samples).round()}$suffix · max $max$suffix';
}

class _NewBadge extends StatelessWidget {
  const _NewBadge();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(right: kSpacingSmall),
      child: Container(
        padding: const EdgeInsets.symmetric(
          horizontal: kSpacingSmall,
          vertical: kSpacingTiny,
        ),
        decoration: BoxDecoration(
          color: theme.colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(kChipRadius),
        ),
        child: Text(
          'New',
          style: AppTextStyles.labelSmall(context)?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
            fontWeight: FontWeight.w700,
          ),
        ),
      ),
    );
  }
}
