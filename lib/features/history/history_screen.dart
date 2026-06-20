import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../core/ble/ble_transport.dart';
import '../../core/providers/app_providers.dart';
import '../../core/services/history_sync.dart';
import 'widgets/hr_chart.dart';
import 'widgets/sleep_chart.dart';

/// Local-first history view.
///
/// Shows every day we have stored on the phone (HR + sleep + steps) with
/// a small per-day summary card and a detail expansion that renders
/// the full chart. The "Sync now" button is incremental: it only
/// re-fetches days the watch says have new data AND we don't already
/// have on disk.
class HistoryScreen extends ConsumerWidget {
  const HistoryScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ready = ref.watch(linkStateProvider).value == LinkState.ready;
    final sync = ref.watch(historySyncProvider);
    final store = ref.watch(historyStoreProvider).asData?.value;

    // Listen for changes so the chart rebuilds when samples land.
    ref.listen<HistorySync>(historySyncProvider, (prev, next) {
      // No-op — the ConsumerWidget already rebuilds via watch.
    });

    return Scaffold(
      appBar: AppBar(
        title: const Text('History'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: 'Sync now',
            onPressed: (ready && !sync.syncing) ? () => sync.syncAll() : null,
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: () => sync.syncAll(),
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            _SyncStatusCard(sync: sync),
            const SizedBox(height: 12),
            _Legend(),
            const SizedBox(height: 16),
            if (sync.days.isEmpty)
              const _EmptyState()
            else
              ..._buildDayList(context, sync),
            const SizedBox(height: 24),
            OutlinedButton.icon(
              icon: const Icon(Icons.watch),
              label: const Text('Back to device'),
              onPressed: () => context.go('/dashboard'),
            ),
            if (store == null) ...[
              const SizedBox(height: 16),
              const Card(
                color: Color(0xFFFFF3E0),
                child: ListTile(
                  leading: Icon(Icons.storage, color: Colors.orange),
                  title: Text('Local store unavailable'),
                  subtitle: Text(
                    'History will be kept in memory only until the storage '
                    'layer finishes initialising. Pull to refresh once it '
                    'does.',
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  List<Widget> _buildDayList(BuildContext context, HistorySync sync) {
    final reversed = sync.days.reversed.toList(); // newest first
    return [
      for (var i = 0; i < reversed.length; i++)
        _DayCard(
          day: reversed[i],
          isExpanded: i == 0, // today expanded by default
          sync: sync,
        ),
    ];
  }
}

/// "Last sync X ago" + status pill. Visible at the top of the history
/// screen — the most important affordance for the local-first model.
class _SyncStatusCard extends StatelessWidget {
  const _SyncStatusCard({required this.sync});
  final HistorySync sync;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final last = sync.lastSyncedAt;
    final error = sync.lastSyncError;

    final (label, color, icon) = switch ((sync.syncing, last, error)) {
      (true, _, _) => ('Syncing…', theme.colorScheme.primary, Icons.sync),
      (false, _, String e) => (
        'Sync failed: $e',
        theme.colorScheme.error,
        Icons.error_outline,
      ),
      (false, null, _) => (
        'Never synced',
        theme.colorScheme.outline,
        Icons.cloud_off,
      ),
      (false, DateTime l, _) => (
        'Up to date — last sync ${_formatRelative(l)}',
        Colors.green,
        Icons.check_circle,
      ),
    };

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
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
                  Text(label, style: theme.textTheme.bodyMedium),
                  const SizedBox(height: 2),
                  Text(
                    _detailLine(),
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _detailLine() {
    final count = sync.days.length;
    final fetched = sync.fetchedDays.length;
    if (sync.syncing) {
      return 'Fetching $fetched new day(s)…';
    }
    if (count == 0) return 'No data yet — tap sync to pull from the watch.';
    final hours = sync.days.expand((d) => d.hr).where((h) => h.bpm > 0).length;
    return '$count day(s) stored · $hours HR sample(s) on disk';
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

class _Legend extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 12,
      runSpacing: 6,
      children: const [
        _LegendChip(color: Color(0xFF1E88E5), label: 'Deep'),
        _LegendChip(color: Color(0xFF64B5F6), label: 'Light'),
        _LegendChip(color: Color(0xFF7E57C2), label: 'REM'),
        _LegendChip(color: Color(0xFFE57373), label: 'Awake'),
      ],
    );
  }
}

class _LegendChip extends StatelessWidget {
  const _LegendChip({required this.color, required this.label});
  final Color color;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 10,
          height: 10,
          decoration: BoxDecoration(
            color: color,
            borderRadius: BorderRadius.circular(2),
          ),
        ),
        const SizedBox(width: 6),
        Text(label, style: Theme.of(context).textTheme.bodySmall),
      ],
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 32),
      child: Column(
        children: [
          Icon(
            Icons.timeline,
            size: 64,
            color: Theme.of(context).colorScheme.outline,
          ),
          const SizedBox(height: 12),
          const Text(
            'No history yet.\nTap Sync to pull from the watch.',
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }
}

/// Per-day summary card with HR spark + sleep mini-timeline + steps.
/// Tap the card to expand the full charts for that day.
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

    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: InkWell(
        onTap: () => setState(() => _expanded = !_expanded),
        borderRadius: BorderRadius.circular(12),
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
                          style: theme.textTheme.titleMedium,
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
                  if (widget.sync.fetchedDays.contains(day.day))
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 2,
                      ),
                      decoration: BoxDecoration(
                        color: theme.colorScheme.primaryContainer,
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Text(
                        'new',
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: theme.colorScheme.onPrimaryContainer,
                        ),
                      ),
                    ),
                  Icon(
                    _expanded ? Icons.expand_less : Icons.expand_more,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ],
              ),
              const SizedBox(height: 12),
              if (isEmpty)
                Text(
                  isToday ? 'No data yet today' : 'No data on watch',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                )
              else ...[
                if (day.hr.isNotEmpty)
                  MiniHrSpark(samples: day.hr, height: 44)
                else
                  Container(
                    height: 44,
                    alignment: Alignment.center,
                    child: Text(
                      'No HR samples',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 16,
                  runSpacing: 4,
                  children: [
                    _DayMetric(
                      icon: Icons.favorite,
                      label: 'HR',
                      value: day.hr.isEmpty
                          ? '—'
                          : '${_avgBpm(day.hr)} avg bpm',
                    ),
                    _DayMetric(
                      icon: Icons.bedtime,
                      label: 'Sleep',
                      value: _sleepSummary(day),
                    ),
                    _DayMetric(
                      icon: Icons.directions_walk,
                      label: 'Steps',
                      value: day.steps?.toString() ?? '—',
                    ),
                  ],
                ),
              ],
              if (_expanded && !isEmpty) ...[
                const Divider(height: 24),
                if (day.hr.isNotEmpty) ...[
                  Text('Heart rate', style: theme.textTheme.titleSmall),
                  const SizedBox(height: 8),
                  SizedBox(height: 180, child: HrLineChart(samples: day.hr)),
                  const SizedBox(height: 16),
                ],
                if (day.sleep.isNotEmpty) ...[
                  Text('Sleep stages', style: theme.textTheme.titleSmall),
                  const SizedBox(height: 8),
                  SleepTimeline(segments: day.sleep, height: 96),
                  const SizedBox(height: 8),
                  Text(
                    _sleepLongSummary(day),
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 16),
                ],
                if (day.energyKcal != null || day.distanceMeters != null) ...[
                  Text('Activity', style: theme.textTheme.titleSmall),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 16,
                    runSpacing: 4,
                    children: [
                      _DayMetric(
                        icon: Icons.local_fire_department,
                        label: 'Calories',
                        value: day.energyKcal?.toString() ?? '—',
                      ),
                      _DayMetric(
                        icon: Icons.straighten,
                        label: 'Distance',
                        value: day.distanceMeters == null
                            ? '—'
                            : '${(day.distanceMeters! / 1000).toStringAsFixed(2)} km',
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
    if (day.sleep.isEmpty) return '—';
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

  static String _label(SleepStage s) => switch (s) {
    SleepStage.awake => 'Awake',
    SleepStage.rem => 'REM',
    SleepStage.light => 'Light',
    SleepStage.deep => 'Deep',
  };
}

class _DayMetric extends StatelessWidget {
  const _DayMetric({
    required this.icon,
    required this.label,
    required this.value,
  });
  final IconData icon;
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 16, color: theme.colorScheme.onSurfaceVariant),
        const SizedBox(width: 4),
        Text(
          '$label: ',
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        Text(value, style: theme.textTheme.bodyMedium),
      ],
    );
  }
}
