import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:openwatch/core/ui/ui_constants.dart';

import '../../core/ble/ble_transport.dart';
import '../../core/providers/app_providers.dart';
import '../../core/services/history_debug_export.dart';
import '../../core/services/history_sync.dart';
import '../widgets/health_widgets.dart';
import '../widgets/max_width_container.dart';
import '../widgets/sync_status_pill.dart' show formatRelativeTime;
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
                child: SizedBox(
                  width: 220,
                  child: Row(
                    children: [
                      const Icon(CupertinoIcons.arrow_counterclockwise),
                      const SizedBox(width: kGridSpacing),
                      const Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text('Full resync'),
                            Text(
                              'Re-fetch stored days',
                              style: TextStyle(fontSize: kBodySmall),
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
      body: MaxWidthContainer(
        child: RefreshIndicator(
          onRefresh: () => _runHistorySync(context, sync, ready),
          child: ListView(
            physics: const AlwaysScrollableScrollPhysics(),
            padding: const EdgeInsets.fromLTRB(
              kCardPadding,
              kSpacingSmall,
              kCardPadding,
              kSectionHeaderPaddingTop,
            ),
            children: [
              Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const HealthSectionHeader(title: 'Local history'),
                  _HistoryOverviewCard(
                    ready: ready,
                    linkState: linkState,
                    sync: sync,
                    storeReady: store != null,
                    days: days,
                    onSync: () => _runHistorySync(context, sync, ready),
                  ),
                  if (sync.lastSyncError != null) ...[
                    const SizedBox(height: kGridSpacing),
                    _SyncErrorBanner(message: sync.lastSyncError!),
                  ],
                  if (days.isNotEmpty) ...[
                    const HealthSectionHeader(title: 'Last 7 days'),
                    _HistoryTrendCard(days: _recentDays(days)),
                    const HealthSectionHeader(title: 'Daily detail'),
                    _DailyDetailSelector(
                      days: days.reversed.toList(),
                      sync: sync,
                      debugContext: ctx,
                    ),
                  ] else ...[
                    const SizedBox(height: kGridSpacing),
                    _EmptyState(ready: ready, syncing: sync.syncing),
                  ],
                  if (store == null) ...[
                    const SizedBox(height: kCardInternalSpacing),
                    _StoreWarning(),
                  ],
                ],
              ),
            ],
          ),
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

    return HealthCard(
      icon: CupertinoIcons.chart_bar_alt_fill,
      title: 'Local history',
      metricColor: theme.colorScheme.primary,
      trailing: _SyncStatusPill(sync: sync),
      caption: latest == null
          ? _describeLink(linkState)
          : 'Latest ${_formatDayTab(latest.day)}',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (sync.syncing) ...[
            LinearProgressIndicator(value: progress),
            const SizedBox(height: kSpacingSmall),
          ],
          Text(
            syncHint,
            style: AppTextStyles.bodySmall(
              context,
            )?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
          const SizedBox(height: kGridSpacing),
          MetricGrid(
            children: [
              HealthCard(
                icon: CupertinoIcons.calendar,
                value: '${days.length}',
                unit: days.length == 1 ? 'day' : 'days',
                caption: 'on phone',
                metricColor: theme.colorScheme.onSurfaceVariant,
              ),
              HealthCard(
                icon: CupertinoIcons.clock,
                value: sync.lastSyncedAt == null
                    ? 'Never'
                    : formatRelativeTime(sync.lastSyncedAt!),
                caption: storeReady ? 'local watermark' : 'storage starting',
                metricColor: theme.colorScheme.onSurfaceVariant,
              ),
              HealthCard(
                icon: CupertinoIcons.waveform_path,
                value: sync.watchDaysWithData.isEmpty
                    ? 'Unknown'
                    : '${sync.watchDaysWithData.length}',
                caption: 'reported last sync',
                metricColor: theme.colorScheme.onSurfaceVariant,
              ),
              HealthCard(
                icon: CupertinoIcons.sparkles,
                value: '${sync.fetchedDays.length}',
                unit: sync.fetchedDays.length == 1 ? 'day' : 'days',
                caption: 'new this sync',
                metricColor: theme.colorScheme.onSurfaceVariant,
              ),
            ],
          ),
          const SizedBox(height: kCardInternalSpacing),
          PrimaryHealthButton(
            label: sync.syncing ? 'Syncing' : 'Sync history',
            icon: sync.syncing ? null : CupertinoIcons.arrow_2_circlepath,
            onPressed: ready && !sync.syncing ? onSync : null,
          ),
        ],
      ),
    );
  }
}

class _SyncStatusPill extends StatelessWidget {
  const _SyncStatusPill({required this.sync});

  final HistorySync sync;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    late final String label;
    late final Color color;
    late final IconData icon;
    if (sync.syncing) {
      label = 'Syncing';
      color = theme.colorScheme.primary;
      icon = Icons.sync;
    } else if (sync.lastSyncError != null) {
      label = 'Error';
      color = theme.colorScheme.error;
      icon = CupertinoIcons.exclamationmark_circle;
    } else if (sync.lastSyncedAt == null) {
      label = 'No sync';
      color = theme.colorScheme.outline;
      icon = Icons.cloud_off_rounded;
    } else {
      label = formatRelativeTime(sync.lastSyncedAt!);
      color = theme.colorScheme.secondary;
      icon = CupertinoIcons.checkmark_circle_fill;
    }

    return StatusPill(icon: icon, label: label, color: color);
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

    return HealthCard(
      icon: CupertinoIcons.chart_bar_alt_fill,
      title: 'Last 7 days',
      metricColor: theme.colorScheme.onSurfaceVariant,
      caption: subtitle,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (latest?.hr.isNotEmpty == true) ...[
            _TrendHeader(
              icon: CupertinoIcons.heart_fill,
              title: 'Heart rate',
              detail: '${avgBpm(latest!.hr)} bpm avg',
              tint: kHeartRed(context),
            ),
            const SizedBox(height: kSpacingSmall),
            MiniHrSpark(
              samples: latest.hr,
              height: 48,
              color: kHeartRed(context),
            ),
          ],
          const SizedBox(height: kCardInternalSpacing),
          _TrendHeader(
            icon: CupertinoIcons.arrow_up_right,
            title: 'Steps',
            detail: latest?.steps == null
                ? 'No step total'
                : '${NumberFormat.decimalPattern().format(latest!.steps)} steps',
            tint: kActivityGreen(context),
          ),
          const SizedBox(height: kSpacingSmall),
          StepsBarChart(
            days: days,
            height: 100,
            barColor: kActivityGreen(context),
          ),
          if (sleepSummary.hasData) ...[
            const SizedBox(height: kCardInternalSpacing),
            _TrendHeader(
              icon: CupertinoIcons.moon_fill,
              title: 'Sleep',
              detail: 'Week avg ${_formatDuration(sleepSummary.average)}',
              tint: kSleepPurple(context),
            ),
            const SizedBox(height: kSpacingSmall),
            SleepTrendChart(
              days: days,
              height: 100,
              sleepColor: kSleepPurple(context),
            ),
          ],
        ],
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
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Icon(icon, size: kIconSizeTiny, color: tint),
        const SizedBox(width: kSpacingSmall),
        Expanded(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Expanded(
                child: Baseline(
                  baseline: kTitleSmall,
                  baselineType: TextBaseline.alphabetic,
                  child: Text(title, style: AppTextStyles.titleSmall(context)),
                ),
              ),
              Flexible(
                child: Baseline(
                  baseline: kTitleSmall,
                  baselineType: TextBaseline.alphabetic,
                  child: Text(
                    detail,
                    textAlign: TextAlign.end,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AppTextStyles.labelMedium(context)?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                      height: 1.0,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _SyncErrorBanner extends StatelessWidget {
  const _SyncErrorBanner({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return HealthCard(
      metricColor: theme.colorScheme.error,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            CupertinoIcons.exclamationmark_triangle,
            size: kIconSizeSmall,
            color: theme.colorScheme.error,
          ),
          const SizedBox(width: kGridSpacing),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Sync failed', style: AppTextStyles.titleSmall(context)),
                const SizedBox(height: kSpacingMini),
                Text(
                  message,
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                  style: AppTextStyles.bodySmall(
                    context,
                  )?.copyWith(color: theme.colorScheme.onSurfaceVariant),
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
      padding: const EdgeInsets.symmetric(
        vertical: kSectionHeaderPaddingTop * 2,
      ),
      child: Column(
        children: [
          Container(
            width: kIconCircleSizeLarge + kSpacingSmall * 2,
            height: kIconCircleSizeLarge + kSpacingSmall * 2,
            decoration: BoxDecoration(
              color: theme.colorScheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(kCardRadius),
            ),
            child: Icon(
              CupertinoIcons.chart_bar,
              size: kIconSizeLarge,
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: kCardInternalSpacing),
          Text('No history yet', style: AppTextStyles.titleMedium(context)),
          const SizedBox(height: kSpacingTiny),
          Text(
            message,
            textAlign: TextAlign.center,
            style: AppTextStyles.bodySmall(
              context,
            )?.copyWith(color: theme.colorScheme.onSurfaceVariant),
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
    return HealthCard(
      metricColor: theme.colorScheme.outline,
      child: Row(
        children: [
          Icon(
            Icons.storage_rounded,
            size: kIconSizeSmall,
            color: theme.colorScheme.outline,
          ),
          const SizedBox(width: kGridSpacing),
          Expanded(
            child: Text(
              'Local store unavailable. History will stay in memory until storage finishes initialising.',
              style: AppTextStyles.bodySmall(context),
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
                constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
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
                constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
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
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(
          horizontal: kGridSpacing,
          vertical: kSpacingTiny,
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
                constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
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
                        : _formatDuration(
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
                            value: _formatDuration(e.value.duration),
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
  return _formatDuration(total);
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
