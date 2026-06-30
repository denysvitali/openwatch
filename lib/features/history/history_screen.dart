import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../core/ble/ble_transport.dart';
import '../../core/providers/app_providers.dart';
import '../../core/services/history_debug_export.dart';
import '../../core/services/history_sync.dart';
import '../widgets/inset_card.dart';
import '../widgets/sync_status_pill.dart';
import 'sleep_session_summary.dart';
import 'widgets/hr_chart.dart';
import 'widgets/scalar_chart.dart';
import 'widgets/sleep_chart.dart';
import 'widgets/sleep_trend_chart.dart';
import 'widgets/steps_chart.dart';

/// Local-first history view.
class HistoryScreen extends ConsumerWidget {
  const HistoryScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final linkState =
        ref.watch(linkStateProvider).value ?? LinkState.disconnected;
    final ready = linkState == LinkState.ready;
    final sync = ref.watch(historySyncProvider);
    final store = ref.watch(historyStoreProvider).asData?.value;
    final manager = ref.watch(watchManagerProvider);
    final lastSyncedAt = store?.lastSyncedAt;
    final lastSyncedDayIso = store?.lastSyncedDay?.iso;
    final days = sync.days;

    final ctx = HistoryDebugContext(
      firmware: manager.firmwareRevision.isEmpty
          ? null
          : manager.firmwareRevision,
      hardware: manager.hardwareRevision.isEmpty
          ? null
          : manager.hardwareRevision,
      linkState: linkState.name,
      lastSyncedAt: lastSyncedAt,
      lastSyncedDayIso: lastSyncedDayIso,
    );

    return Scaffold(
      appBar: AppBar(
        title: const Text('History'),
        actions: [
          PopupMenuButton<_HistoryMenuAction>(
            tooltip: 'History options',
            icon: const Icon(CupertinoIcons.ellipsis_circle),
            onSelected: (action) {
              switch (action) {
                case _HistoryMenuAction.fullSync:
                  _runHistorySync(context, sync, ready, force: true);
              }
            },
            itemBuilder: (context) => [
              PopupMenuItem(
                value: _HistoryMenuAction.fullSync,
                enabled: ready && !sync.syncing,
                child: const SizedBox(
                  width: 220,
                  child: Row(
                    children: [
                      Icon(CupertinoIcons.arrow_counterclockwise),
                      SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text('Full resync'),
                            Text(
                              'Re-fetch stored days',
                              style: TextStyle(fontSize: 12),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: () => _runHistorySync(context, sync, ready),
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 28),
          children: [
            Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 860),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _HistoryOverviewCard(
                      ready: ready,
                      linkState: linkState,
                      sync: sync,
                      storeReady: store != null,
                      days: days,
                      onSync: () => _runHistorySync(context, sync, ready),
                    ),
                    if (sync.lastSyncError != null) ...[
                      const SizedBox(height: 12),
                      _SyncErrorBanner(message: sync.lastSyncError!),
                    ],
                    if (days.isNotEmpty) ...[
                      const SizedBox(height: 14),
                      _HistoryTrendCard(days: _recentDays(days)),
                      const SizedBox(height: 14),
                      _SectionTitle(
                        title: 'Daily detail',
                        trailing: '${days.length} days',
                      ),
                      const SizedBox(height: 6),
                      _DailyDetailSelector(
                        days: days.reversed.toList(),
                        sync: sync,
                        debugContext: ctx,
                      ),
                    ] else ...[
                      const SizedBox(height: 14),
                      _EmptyState(ready: ready, syncing: sync.syncing),
                    ],
                    if (store == null) ...[
                      const SizedBox(height: 16),
                      _StoreWarning(),
                    ],
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

enum _HistoryMenuAction { fullSync }

Future<void> _runHistorySync(
  BuildContext context,
  HistorySync sync,
  bool ready, {
  bool force = false,
}) async {
  final messenger = ScaffoldMessenger.of(context);
  if (sync.syncing) return;
  if (!ready) {
    messenger.showSnackBar(
      const SnackBar(content: Text('Connect your watch to sync history')),
    );
    return;
  }

  await sync.syncAll(force: force);
  if (!context.mounted) return;
  final error = sync.lastSyncError;
  if (error != null) {
    messenger.showSnackBar(
      const SnackBar(content: Text('History sync failed')),
    );
  } else if (force) {
    messenger.showSnackBar(
      const SnackBar(content: Text('Full resync complete')),
    );
  }
}

class _HistoryOverviewCard extends StatelessWidget {
  const _HistoryOverviewCard({
    required this.ready,
    required this.linkState,
    required this.sync,
    required this.storeReady,
    required this.days,
    required this.onSync,
  });

  final bool ready;
  final LinkState linkState;
  final HistorySync sync;
  final bool storeReady;
  final List<DailyHistory> days;
  final VoidCallback onSync;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final latest = days.isEmpty ? null : days.last;
    final progressTotal = sync.progressTotal;
    final progress = progressTotal <= 0
        ? null
        : sync.progressCurrent.clamp(0, progressTotal) / progressTotal;
    final syncHint = sync.syncing
        ? progressTotal <= 0
              ? 'Preparing history sync'
              : 'Fetching day ${sync.progressCurrent.clamp(1, progressTotal)} of $progressTotal'
        : ready
        ? 'Pull down or use Sync history to update from the watch.'
        : 'Connect your watch to sync local history.';

    return InsetCard(
      padding: const EdgeInsets.all(18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 52,
                height: 52,
                decoration: BoxDecoration(
                  color: theme.colorScheme.primary.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Icon(
                  CupertinoIcons.chart_bar_alt_fill,
                  color: theme.colorScheme.primary,
                  size: 28,
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Local history',
                      style: theme.textTheme.titleLarge?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      latest == null
                          ? _describeLink(linkState)
                          : 'Latest ${_formatDayTab(latest.day)}',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 10),
              SyncStatusPill(sync: sync),
            ],
          ),
          const SizedBox(height: 16),
          if (sync.syncing) ...[
            LinearProgressIndicator(value: progress),
            const SizedBox(height: 10),
          ],
          Text(
            syncHint,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 14),
          _StatGrid(
            stats: [
              _HistoryStat(
                icon: CupertinoIcons.calendar,
                label: 'Stored',
                value: '${days.length}',
                detail: days.length == 1 ? 'day on phone' : 'days on phone',
              ),
              _HistoryStat(
                icon: CupertinoIcons.clock,
                label: 'Last sync',
                value: sync.lastSyncedAt == null
                    ? 'Never'
                    : formatRelativeTime(sync.lastSyncedAt!),
                detail: storeReady ? 'local watermark' : 'storage starting',
              ),
              _HistoryStat(
                icon: CupertinoIcons.waveform_path,
                label: 'Watch data',
                value: sync.watchDaysWithData.isEmpty
                    ? 'Unknown'
                    : '${sync.watchDaysWithData.length}',
                detail: 'reported last sync',
              ),
              _HistoryStat(
                icon: CupertinoIcons.sparkles,
                label: 'Fetched',
                value: '${sync.fetchedDays.length}',
                detail: 'new this sync',
              ),
            ],
          ),
          const SizedBox(height: 16),
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              onPressed: ready && !sync.syncing ? onSync : null,
              icon: sync.syncing
                  ? const SizedBox.square(
                      dimension: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(CupertinoIcons.arrow_2_circlepath),
              label: Text(sync.syncing ? 'Syncing' : 'Sync history'),
            ),
          ),
        ],
      ),
    );
  }
}

class _HistoryTrendCard extends StatelessWidget {
  const _HistoryTrendCard({required this.days});

  final List<DailyHistory> days;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final latest = days.isEmpty ? null : days.last;
    final sleepSummary = SleepTrendSummary.fromDays(days);
    final subtitle = days.isEmpty
        ? 'No stored days'
        : '${DateFormat.MMMd().format(days.first.day.midnight)} - '
              '${DateFormat.MMMd().format(days.last.day.midnight)}';

    return InsetCard(
      padding: const EdgeInsets.all(18),
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
                      'Last 7 days',
                      style: theme.textTheme.titleLarge?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      subtitle,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              if (latest != null) ...[
                const SizedBox(width: 12),
                Flexible(
                  child: Align(
                    alignment: Alignment.centerRight,
                    child: _LatestDaySummary(day: latest),
                  ),
                ),
              ],
            ],
          ),
          if (latest?.hr.isNotEmpty == true) ...[
            const SizedBox(height: 16),
            _TrendHeader(
              icon: CupertinoIcons.heart_fill,
              title: 'Heart rate',
              detail: '${avgBpm(latest!.hr)} bpm avg',
              tint: const Color(0xFFFF3B30),
            ),
            const SizedBox(height: 8),
            MiniHrSpark(samples: latest.hr, height: 58),
          ],
          const SizedBox(height: 16),
          _TrendHeader(
            icon: CupertinoIcons.arrow_up_right,
            title: 'Steps',
            detail: latest?.steps == null
                ? 'No step total'
                : '${NumberFormat.decimalPattern().format(latest!.steps)} steps',
            tint: theme.colorScheme.primary,
          ),
          const SizedBox(height: 8),
          StepsBarChart(days: days, height: 118),
          if (sleepSummary.hasData) ...[
            const SizedBox(height: 16),
            _TrendHeader(
              icon: CupertinoIcons.moon_fill,
              title: 'Sleep',
              detail: 'Week avg ${_formatDuration(sleepSummary.average)}',
              tint: const Color(0xFF5856D6),
            ),
            const SizedBox(height: 8),
            SleepTrendChart(days: days, height: 118),
          ],
        ],
      ),
    );
  }
}

class _LatestDaySummary extends StatelessWidget {
  const _LatestDaySummary({required this.day});

  final DailyHistory day;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final items = <String>[];
    final avg = avgBpm(day.hr);
    if (avg > 0) items.add('$avg bpm');
    if (day.steps != null) {
      items.add('${NumberFormat.compact().format(day.steps)} steps');
    }
    if (day.sleep.isNotEmpty) items.add(_sleepSummary(day));

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        items.isEmpty ? _formatDayTab(day.day) : items.join(' · '),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: theme.textTheme.labelMedium?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }
}

class _TrendHeader extends StatelessWidget {
  const _TrendHeader({
    required this.icon,
    required this.title,
    required this.detail,
    required this.tint,
  });

  final IconData icon;
  final String title;
  final String detail;
  final Color tint;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      children: [
        Icon(icon, size: 17, color: tint),
        const SizedBox(width: 7),
        Expanded(child: Text(title, style: theme.textTheme.titleSmall)),
        Flexible(
          child: Text(
            detail,
            textAlign: TextAlign.end,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.labelMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ),
      ],
    );
  }
}

class _HistoryStat {
  const _HistoryStat({
    required this.icon,
    required this.label,
    required this.value,
    required this.detail,
  });

  final IconData icon;
  final String label;
  final String value;
  final String detail;
}

class _StatGrid extends StatelessWidget {
  const _StatGrid({required this.stats});

  final List<_HistoryStat> stats;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final columns = constraints.maxWidth >= 620 ? 4 : 2;
        final width = (constraints.maxWidth - (columns - 1) * 8) / columns;
        return Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final stat in stats)
              SizedBox(
                width: width.clamp(120.0, constraints.maxWidth),
                child: _StatCell(stat: stat),
              ),
          ],
        );
      },
    );
  }
}

class _StatCell extends StatelessWidget {
  const _StatCell({required this.stat});

  final _HistoryStat stat;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                stat.icon,
                size: 16,
                color: theme.colorScheme.onSurfaceVariant,
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  stat.label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            stat.value,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            stat.detail,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.labelSmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}

class _SyncErrorBanner extends StatelessWidget {
  const _SyncErrorBanner({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return InsetCard(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            CupertinoIcons.exclamationmark_triangle,
            color: theme.colorScheme.error,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Sync failed', style: theme.textTheme.titleSmall),
                const SizedBox(height: 2),
                Text(
                  message,
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

List<DailyHistory> _recentDays(List<DailyHistory> days, {int count = 7}) {
  if (days.isEmpty) return const [];
  final byDay = {for (final day in days) day.day: day};
  final end = days.last.day;
  return [
    for (var offset = -count + 1; offset <= 0; offset++)
      byDay[end.addDays(offset)] ?? DailyHistory(day: end.addDays(offset)),
  ];
}

String _describeLink(LinkState state) => switch (state) {
  LinkState.ready => 'Connected and ready to sync',
  LinkState.connecting => 'Connecting to watch',
  LinkState.disconnected => 'Watch disconnected',
  LinkState.discovering => 'Discovering watch services',
  LinkState.readingDeviceInfo => 'Reading watch info',
};

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
  const _EmptyState({required this.ready, required this.syncing});

  final bool ready;
  final bool syncing;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final message = syncing
        ? 'Fetching history from your watch.'
        : ready
        ? 'Use Sync history to pull local watch data.'
        : 'Connect your watch, then sync history.';
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
            message,
            textAlign: TextAlign.center,
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
    return InsetCard(
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
  const _DailyDetailSelector({
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
              debugContext: widget.debugContext,
              freshlyFetched: widget.sync.fetchedDays.contains(current.day),
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
                      _formatDayHeader(displayDay.day),
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    if (displayDay.lastUpdated != null)
                      Text(
                        'Updated ${DateFormat.jm().format(displayDay.lastUpdated!)}',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                  ],
                ),
              ),
              IconButton(
                tooltip: 'Copy day debug',
                icon: const Icon(Icons.bug_report_outlined, size: 20),
                onPressed: () {
                  final ctx = debugContext;
                  final fresh = freshlyFetched;
                  _copyDayDebug(context, day, ctx, fresh);
                },
              ),
              if (freshlyFetched) _NewBadge(),
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
                  label: displayDay.hr.isEmpty
                      ? '-'
                      : '${avgBpm(displayDay.hr)} bpm',
                  tint: const Color(0xFFFF3B30),
                ),
                _MetricPill(
                  icon: CupertinoIcons.moon_fill,
                  label: _sleepSummary(displayDay),
                  tint: const Color(0xFF5856D6),
                ),
                _MetricPill(
                  icon: CupertinoIcons.arrow_up_right,
                  label: displayDay.steps == null
                      ? '-'
                      : NumberFormat.compact().format(displayDay.steps),
                  tint: theme.colorScheme.primary,
                ),
                _MetricPill(
                  icon: CupertinoIcons.bolt_fill,
                  label: displayDay.stress.isEmpty
                      ? '-'
                      : '${avgValue(displayDay.stress).round()} stress',
                  tint: const Color(0xFFFF9500),
                ),
                _MetricPill(
                  icon: CupertinoIcons.chart_bar_fill,
                  label: displayDay.hrv.isEmpty
                      ? '-'
                      : '${avgValue(displayDay.hrv).round()} ms',
                  tint: const Color(0xFF34C759),
                ),
                _MetricPill(
                  icon: CupertinoIcons.waveform_path_ecg,
                  label: displayDay.bloodPressure.isEmpty
                      ? '-'
                      : _formatBp(displayDay.bloodPressure.last),
                  tint: const Color(0xFFFF3B30),
                ),
              ],
            ),
            if (displayDay.hr.isNotEmpty) ...[
              const SizedBox(height: 20),
              _ChartHeader(
                title: 'Heart rate',
                detail: '${avgBpm(displayDay.hr)} bpm avg',
              ),
              const SizedBox(height: 10),
              SizedBox(height: 184, child: HrLineChart(samples: displayDay.hr)),
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
            if (displayDay.sleep.isNotEmpty) ...[
              const SizedBox(height: 20),
              _ChartHeader(
                title: 'Sleep',
                detail: 'Total ${_sleepSummary(displayDay)}',
              ),
              const SizedBox(height: 8),
              _SleepSessionRows(
                sessions: SleepSessionSummary.fromSegments(displayDay.sleep),
              ),
              const SizedBox(height: 8),
              Text(
                _sleepLongSummary(displayDay),
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 10),
              SleepTimeline(segments: displayDay.sleep, height: 110),
            ],
            if (displayDay.stress.isNotEmpty ||
                displayDay.hrv.isNotEmpty ||
                displayDay.bloodPressure.isNotEmpty) ...[
              const SizedBox(height: 20),
              _ChartHeader(title: 'Other metrics', detail: 'Synced values'),
              const SizedBox(height: 10),
              if (displayDay.stress.isNotEmpty) ...[
                _ChartHeader(
                  title: 'Stress',
                  detail: _scalarRange(displayDay.stress),
                ),
                const SizedBox(height: 8),
                SizedBox(
                  height: 132,
                  child: ScalarMetricChart(
                    samples: displayDay.stress,
                    color: const Color(0xFFFF9500),
                    minValue: 0,
                    maxValue: 100,
                  ),
                ),
                const SizedBox(height: 14),
              ],
              if (displayDay.hrv.isNotEmpty) ...[
                _ChartHeader(
                  title: 'HRV',
                  detail: _scalarRange(displayDay.hrv),
                ),
                const SizedBox(height: 8),
                SizedBox(
                  height: 132,
                  child: ScalarMetricChart(
                    samples: displayDay.hrv,
                    color: const Color(0xFF34C759),
                  ),
                ),
                const SizedBox(height: 14),
              ],
              _MetricValueList(day: displayDay),
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

DailyHistory _displayDayForNow(DailyHistory day, DateTime now) {
  return day.copyWith(
    hr: _clipAndDedupeHr(day.hr, now),
    stress: _clipScalar(day.stress, now),
    hrv: _clipScalar(day.hrv, now),
    bloodPressure: _clipBp(day.bloodPressure, now),
  );
}

List<HrSample> _clipAndDedupeHr(List<HrSample> samples, DateTime now) {
  final bySlot = <int, HrSample>{};
  for (final sample in samples) {
    final snapped = _snapToHrSlot(sample.timestamp);
    if (snapped.isAfter(now)) continue;
    final key = snapped.millisecondsSinceEpoch;
    final existing = bySlot[key];
    if (existing == null || sample.timestamp.isAfter(existing.timestamp)) {
      bySlot[key] = HrSample(snapped, sample.bpm);
    }
  }
  return bySlot.values.toList()
    ..sort((a, b) => a.timestamp.compareTo(b.timestamp));
}

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

DateTime _snapToHrSlot(DateTime t) =>
    DateTime(t.year, t.month, t.day, t.hour, (t.minute ~/ 5) * 5);

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

String _sleepSummary(DailyHistory day) {
  if (day.sleep.isEmpty) return '-';
  final total = day.sleep.fold<Duration>(
    Duration.zero,
    (a, s) => a + s.duration,
  );
  return _formatDuration(total);
}

/// Copies a plain-text "day debug" package to the clipboard so users can
/// paste one day into a bug report without screenshots. A fully populated
/// day runs ~5–10 kB; if it ever creeps past 100 kB the snackbar will
/// flag it so we hear about it instead of silently truncating.
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
    parts.add('${_label(s)} ${_formatDuration(d)}');
  }
  return parts.join(' · ');
}

String _formatDuration(Duration duration) {
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

class _SleepSessionRows extends StatelessWidget {
  const _SleepSessionRows({required this.sessions});

  final List<SleepSessionSummary> sessions;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final timeFormat = DateFormat.jm();
    return Column(
      children: [
        for (var i = 0; i < sessions.length; i++) ...[
          if (i > 0) const SizedBox(height: 6),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            decoration: BoxDecoration(
              color: theme.colorScheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Row(
              children: [
                Icon(
                  CupertinoIcons.moon_fill,
                  size: 16,
                  color: const Color(0xFF5856D6),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '${timeFormat.format(sessions[i].start)} - ${timeFormat.format(sessions[i].end)}',
                        style: theme.textTheme.bodyMedium?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      if (sessions.length > 1)
                        Text(
                          'Session ${i + 1}',
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                    ],
                  ),
                ),
                Text(
                  _formatDuration(sessions[i].duration),
                  style: theme.textTheme.labelLarge,
                ),
              ],
            ),
          ),
        ],
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
      'avg ${avgValue(samples).round()}$suffix · max $max$suffix';
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
