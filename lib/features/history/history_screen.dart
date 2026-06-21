import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../core/ble/ble_transport.dart';
import '../../core/providers/app_providers.dart';
import '../../core/services/history_sync.dart';
import 'widgets/hr_chart.dart';
import 'widgets/sleep_chart.dart';
import 'widgets/steps_chart.dart';

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
        title: const Text('Activity'),
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
            _SyncStatusCard(sync: sync),
            const SizedBox(height: 12),
            if (sync.days.isNotEmpty) ...[
              _SummaryStrip(days: sync.days),
              const SizedBox(height: 12),
              _StepsOverviewCard(days: sync.days),
              const SizedBox(height: 16),
              _SectionTitle(
                title: 'Daily detail',
                trailing: '${sync.days.length} days',
              ),
              const SizedBox(height: 8),
              ..._buildDayList(sync),
            ] else
              const _EmptyState(),
            const SizedBox(height: 20),
            OutlinedButton.icon(
              icon: const Icon(Icons.watch_rounded),
              label: const Text('Back to Device'),
              onPressed: () => context.go('/dashboard'),
            ),
            if (store == null) ...[const SizedBox(height: 16), _StoreWarning()],
          ],
        ),
      ),
    );
  }

  List<Widget> _buildDayList(HistorySync sync) {
    final reversed = sync.days.reversed.toList();
    return [
      for (var i = 0; i < reversed.length; i++)
        Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: _DayCard(day: reversed[i], isExpanded: i == 0, sync: sync),
        ),
    ];
  }
}

class _SyncStatusCard extends StatelessWidget {
  const _SyncStatusCard({required this.sync});
  final HistorySync sync;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final last = sync.lastSyncedAt;
    final error = sync.lastSyncError;

    final (title, detail, color, icon) = switch ((sync.syncing, last, error)) {
      (true, _, _) => (
        'Syncing',
        _progressLine(),
        theme.colorScheme.primary,
        CupertinoIcons.arrow_2_circlepath,
      ),
      (false, _, String e) => (
        'Sync failed',
        e,
        theme.colorScheme.error,
        CupertinoIcons.exclamationmark_circle,
      ),
      (false, null, _) => (
        'Never synced',
        'Pull from the watch to build local history',
        theme.colorScheme.outline,
        Icons.cloud_off_rounded,
      ),
      (false, DateTime l, _) => (
        'Up to date',
        'Last sync ${_formatRelative(l)}',
        theme.colorScheme.secondary,
        CupertinoIcons.checkmark_circle_fill,
      ),
    };

    return _InsetCard(
      child: Column(
        children: [
          Row(
            children: [
              if (sync.syncing)
                const SizedBox(
                  width: 24,
                  height: 24,
                  child: CircularProgressIndicator(strokeWidth: 2.4),
                )
              else
                Icon(icon, color: color),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title, style: theme.textTheme.titleMedium),
                    const SizedBox(height: 2),
                    Text(
                      detail,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
              Text(
                '${sync.days.length}d',
                style: theme.textTheme.titleMedium?.copyWith(color: color),
              ),
            ],
          ),
          if (sync.syncing && sync.progressTotal > 0) ...[
            const SizedBox(height: 12),
            ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: LinearProgressIndicator(
                value: sync.progressCurrent / sync.progressTotal,
                minHeight: 7,
              ),
            ),
          ],
        ],
      ),
    );
  }

  String _progressLine() {
    if (sync.progressTotal > 0) {
      return 'Fetching day ${sync.progressCurrent} of ${sync.progressTotal}';
    }
    if (sync.fetchedDays.isNotEmpty) {
      return '${sync.fetchedDays.length} new days pulled';
    }
    return 'Checking the watch';
  }

  String _formatRelative(DateTime when) {
    final delta = DateTime.now().difference(when);
    if (delta.inMinutes < 1) return 'just now';
    if (delta.inMinutes < 60) return '${delta.inMinutes}m ago';
    if (delta.inHours < 24) return '${delta.inHours}h ago';
    if (delta.inDays < 7) return '${delta.inDays}d ago';
    return DateFormat.yMMMd().format(when);
  }
}

class _SummaryStrip extends StatelessWidget {
  const _SummaryStrip({required this.days});

  final List<DailyHistory> days;

  @override
  Widget build(BuildContext context) {
    final week = days.length <= 7 ? days : days.sublist(days.length - 7);
    final stepsTotal = week.fold<int>(0, (sum, d) => sum + (d.steps ?? 0));
    final hrSamples = week.expand((d) => d.hr).toList();
    final avgHr = hrSamples.isEmpty
        ? null
        : (hrSamples.fold<int>(0, (sum, h) => sum + h.bpm) / hrSamples.length)
              .round();
    final sleep = days.last.sleep.fold<Duration>(
      Duration.zero,
      (sum, s) => sum + s.duration,
    );

    return Row(
      children: [
        Expanded(
          child: _SummaryTile(
            icon: CupertinoIcons.arrow_up_right,
            label: '7-day steps',
            value: NumberFormat.compact().format(stepsTotal),
            tint: Theme.of(context).colorScheme.primary,
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: _SummaryTile(
            icon: CupertinoIcons.heart_fill,
            label: 'Avg heart',
            value: avgHr == null ? '-' : '$avgHr',
            unit: avgHr == null ? null : 'bpm',
            tint: const Color(0xFFFF3B30),
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: _SummaryTile(
            icon: CupertinoIcons.moon_fill,
            label: 'Sleep',
            value: sleep == Duration.zero
                ? '-'
                : '${sleep.inHours}h ${sleep.inMinutes.remainder(60)}m',
            tint: const Color(0xFF5856D6),
          ),
        ),
      ],
    );
  }
}

class _SummaryTile extends StatelessWidget {
  const _SummaryTile({
    required this.icon,
    required this.label,
    required this.value,
    required this.tint,
    this.unit,
  });

  final IconData icon;
  final String label;
  final String value;
  final String? unit;
  final Color tint;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return _InsetCard(
      padding: const EdgeInsets.all(12),
      child: SizedBox(
        height: 84,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, color: tint, size: 18),
            const Spacer(),
            FittedBox(
              alignment: Alignment.centerLeft,
              fit: BoxFit.scaleDown,
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(
                    value,
                    style: theme.textTheme.titleLarge?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  if (unit != null) ...[
                    const SizedBox(width: 3),
                    Padding(
                      padding: const EdgeInsets.only(bottom: 3),
                      child: Text(
                        unit!,
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
            Text(
              label,
              style: theme.textTheme.labelSmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ),
      ),
    );
  }
}

class _StepsOverviewCard extends StatelessWidget {
  const _StepsOverviewCard({required this.days});

  final List<DailyHistory> days;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final recent = days.length <= 7 ? days : days.sublist(days.length - 7);
    final best = recent.fold<int>(0, (max, d) {
      final steps = d.steps ?? 0;
      return steps > max ? steps : max;
    });

    return _InsetCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(child: Text('Steps', style: theme.textTheme.titleLarge)),
              Text(
                best == 0
                    ? 'No peak'
                    : 'Best ${NumberFormat.compact().format(best)}',
                style: theme.textTheme.labelLarge?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          StepsBarChart(days: recent, height: 156),
        ],
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

class _DayCard extends StatefulWidget {
  const _DayCard({
    required this.day,
    required this.isExpanded,
    required this.sync,
  });

  final DailyHistory day;
  final bool isExpanded;
  final HistorySync sync;

  @override
  State<_DayCard> createState() => _DayCardState();
}

class _DayCardState extends State<_DayCard> {
  late bool _expanded;

  @override
  void initState() {
    super.initState();
    _expanded = widget.isExpanded;
  }

  @override
  Widget build(BuildContext context) {
    final day = widget.day;
    final theme = Theme.of(context);
    final isToday = day.day == DateOnly.today();
    final isEmpty = day.hr.isEmpty && day.sleep.isEmpty && day.steps == null;

    return _InsetCard(
      padding: EdgeInsets.zero,
      child: InkWell(
        onTap: () => setState(() => _expanded = !_expanded),
        borderRadius: BorderRadius.circular(8),
        child: Padding(
          padding: const EdgeInsets.all(16),
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
                  if (widget.sync.fetchedDays.contains(day.day)) _NewBadge(),
                  Icon(
                    _expanded
                        ? CupertinoIcons.chevron_up
                        : CupertinoIcons.chevron_down,
                    color: theme.colorScheme.onSurfaceVariant,
                    size: 18,
                  ),
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
                if (day.hr.isNotEmpty)
                  MiniHrSpark(samples: day.hr, height: 46)
                else
                  SizedBox(
                    height: 46,
                    child: Center(
                      child: Text(
                        'No heart-rate samples',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                  ),
                const SizedBox(height: 12),
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
                  ],
                ),
              ],
              if (_expanded && !isEmpty) ...[
                const SizedBox(height: 18),
                Divider(color: theme.colorScheme.outlineVariant),
                if (day.hr.isNotEmpty) ...[
                  const SizedBox(height: 16),
                  _ChartHeader(
                    title: 'Heart rate',
                    detail: '${_avgBpm(day.hr)} bpm avg',
                  ),
                  const SizedBox(height: 10),
                  SizedBox(height: 184, child: HrLineChart(samples: day.hr)),
                ],
                if (day.sleep.isNotEmpty) ...[
                  const SizedBox(height: 18),
                  _ChartHeader(title: 'Sleep', detail: _sleepLongSummary(day)),
                  const SizedBox(height: 10),
                  SleepTimeline(segments: day.sleep, height: 110),
                ],
                if (day.energyKcal != null || day.distanceMeters != null) ...[
                  const SizedBox(height: 18),
                  _ChartHeader(title: 'Activity', detail: _activityDetail(day)),
                  const SizedBox(height: 10),
                  Wrap(
                    spacing: 10,
                    runSpacing: 8,
                    children: [
                      _MetricPill(
                        icon: CupertinoIcons.flame_fill,
                        label: day.energyKcal == null
                            ? '- kcal'
                            : '${day.energyKcal} kcal',
                        tint: const Color(0xFFFF9500),
                      ),
                      _MetricPill(
                        icon: CupertinoIcons.location_fill,
                        label: day.distanceMeters == null
                            ? '- km'
                            : '${(day.distanceMeters! / 1000).toStringAsFixed(2)} km',
                        tint: const Color(0xFF34C759),
                      ),
                    ],
                  ),
                ],
              ],
            ],
          ),
        ),
      ),
    );
  }

  static String _formatDayHeader(DateOnly d) {
    final today = DateOnly.today();
    if (d == today) return 'Today · ${DateFormat.MMMd().format(d.midnight)}';
    if (d == today.addDays(-1)) {
      return 'Yesterday · ${DateFormat.MMMd().format(d.midnight)}';
    }
    return DateFormat('EEEE · MMM d').format(d.midnight);
  }

  static int _avgBpm(List<HrSample> samples) {
    if (samples.isEmpty) return 0;
    final sum = samples.fold<int>(0, (a, s) => a + s.bpm);
    return (sum / samples.length).round();
  }

  static String _sleepSummary(DailyHistory day) {
    if (day.sleep.isEmpty) return '-';
    final total = day.sleep.fold<Duration>(
      Duration.zero,
      (a, s) => a + s.duration,
    );
    final h = total.inHours;
    final m = total.inMinutes.remainder(60);
    return '${h}h ${m}m';
  }

  static String _sleepLongSummary(DailyHistory day) {
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

  static String _activityDetail(DailyHistory day) {
    final parts = <String>[];
    if (day.energyKcal != null) parts.add('${day.energyKcal} kcal');
    if (day.distanceMeters != null) {
      parts.add('${(day.distanceMeters! / 1000).toStringAsFixed(2)} km');
    }
    return parts.join(' · ');
  }

  static String _label(SleepStage s) => switch (s) {
    SleepStage.awake => 'Awake',
    SleepStage.rem => 'REM',
    SleepStage.light => 'Light',
    SleepStage.deep => 'Deep',
  };
}

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
  const _InsetCard({
    required this.child,
    this.padding = const EdgeInsets.all(16),
  });

  final Widget child;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(padding: padding, child: child),
    );
  }
}
