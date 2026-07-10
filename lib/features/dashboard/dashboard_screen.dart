import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../core/ble/ble_transport.dart';
import '../../core/protocol/channel_a.dart';
import '../../core/providers/app_providers.dart';
import '../../core/services/history_sync.dart';
import '../../core/ui/app_colors.dart';
import '../../core/ui/ui_constants.dart';
import '../history/widgets/sleep_trend_chart.dart';
import '../history/widgets/steps_chart.dart';
import '../widgets/health_widgets.dart';

/// Summary overview: connection, live metrics, recent activity, quick actions.
class DashboardScreen extends ConsumerWidget {
  const DashboardScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final link = ref.watch(linkStateProvider).value ?? LinkState.disconnected;
    final manager = ref.watch(watchManagerProvider);
    final sync = ref.watch(historySyncProvider);
    final device = ref.watch(connectedDeviceProvider);
    final name = device?.platformName.isNotEmpty == true
        ? device!.platformName
        : 'Watch';
    final today = sync.days.isEmpty ? null : sync.days.last;
    final heartRate = manager.lastHeartRate ?? avgBpm(today?.hr ?? const []);
    final armedAlarms = manager.alarms.where((alarm) => alarm.enabled).toList()
      ..sort((a, b) {
        final ah = a.hour.compareTo(b.hour);
        return ah != 0 ? ah : a.minute.compareTo(b.minute);
      });
    final colors = AppColors.of(context);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Summary'),
        actions: [
          IconButton(
            icon: const Icon(CupertinoIcons.arrow_clockwise),
            tooltip: 'Refresh',
            onPressed: link == LinkState.ready
                ? () {
                    manager.refreshSteps();
                    manager.refreshBattery();
                  }
                : null,
          ),
          PopupMenuButton<_SummaryMenu>(
            tooltip: 'More',
            icon: const Icon(CupertinoIcons.ellipsis_circle),
            onSelected: (action) async {
              switch (action) {
                case _SummaryMenu.find:
                  manager.findDevice();
                  if (context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('Watch will ring shortly')),
                    );
                  }
                case _SummaryMenu.syncTime:
                  manager.syncTime();
                  if (context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('Watch clock updated')),
                    );
                  }
                case _SummaryMenu.disconnect:
                  final ok = await showConfirmDialog(
                    context,
                    title: 'Disconnect watch?',
                    message: 'You can reconnect anytime from the scan screen.',
                    confirmLabel: 'Disconnect',
                    destructive: true,
                  );
                  if (!ok || !context.mounted) return;
                  await ref.read(bleTransportProvider).disconnect();
                  if (context.mounted) context.go('/scan');
              }
            },
            itemBuilder: (context) => [
              PopupMenuItem(
                value: _SummaryMenu.find,
                enabled: link == LinkState.ready,
                child: const Text('Find watch'),
              ),
              PopupMenuItem(
                value: _SummaryMenu.syncTime,
                enabled: link == LinkState.ready,
                child: const Text('Sync time'),
              ),
              const PopupMenuDivider(),
              const PopupMenuItem(
                value: _SummaryMenu.disconnect,
                child: Text('Disconnect'),
              ),
            ],
          ),
        ],
      ),
      body: MaxWidthContainer(
        child: RefreshIndicator(
          onRefresh: () async {
            if (link == LinkState.ready) {
              manager.refreshSteps();
              manager.refreshBattery();
              await sync.syncAll();
            }
          },
          child: ListView(
            physics: const AlwaysScrollableScrollPhysics(),
            padding: kScreenListPadding,
            children: [
              _DeviceHeroCard(
                name: name,
                status: _describe(link),
                connected: link == LinkState.ready,
                connecting:
                    link == LinkState.connecting ||
                    link == LinkState.discovering ||
                    link == LinkState.readingDeviceInfo,
                batteryPercent: manager.batteryPercent,
                charging: manager.charging,
                onReconnect: link != LinkState.ready
                    ? () => context.go('/scan')
                    : null,
              ),
              if (manager.nowPlaying != null &&
                  manager.nowPlaying!.track.isNotEmpty) ...[
                const SizedBox(height: kGridSpacing),
                _NowPlayingCard(music: manager.nowPlaying!),
              ],
              const HealthSectionHeader(title: 'Today'),
              _MetricGrid(
                steps: manager.todaySteps ?? today?.steps,
                calories: manager.todayCalories ?? today?.energyKcal,
                heartRate: heartRate == 0 ? null : heartRate,
                distanceMeters: today?.distanceMeters,
                colors: colors,
              ),
              HealthSectionHeader(
                title: 'At a glance',
                onShowAll: () => context.go('/history'),
                actionLabel: 'History',
              ),
              _RecentActivityCard(sync: sync),
              const HealthSectionHeader(title: 'Quick actions'),
              _QuickActions(
                ready: link == LinkState.ready,
                syncingHistory: sync.syncing,
                findDevice: () {
                  manager.findDevice();
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Watch will ring shortly')),
                  );
                },
                syncTime: () {
                  manager.syncTime();
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Watch clock updated')),
                  );
                },
                syncHistory: () => sync.syncAll(),
              ),
              HealthSectionHeader(
                title: 'Alarms',
                onShowAll: link == LinkState.ready
                    ? () => context.push('/alarms')
                    : null,
                actionLabel: 'Manage',
              ),
              if (armedAlarms.isNotEmpty)
                _AlarmsSummary(
                  count: armedAlarms.length,
                  next: armedAlarms.first,
                )
              else
                HealthCard(
                  icon: CupertinoIcons.alarm,
                  title: 'No alarms armed',
                  caption: link == LinkState.ready
                      ? 'Tap to set a wake-up alarm on the watch.'
                      : 'Connect your watch to manage alarms.',
                  metricColor: colors.accent,
                  onTap: link == LinkState.ready
                      ? () => context.push('/alarms')
                      : null,
                ),
            ],
          ),
        ),
      ),
    );
  }

  String _describe(LinkState s) => switch (s) {
    LinkState.ready => 'Connected',
    LinkState.connecting => 'Connecting…',
    LinkState.disconnected => 'Disconnected',
    LinkState.discovering => 'Discovering…',
    LinkState.readingDeviceInfo => 'Reading device…',
  };
}

enum _SummaryMenu { find, syncTime, disconnect }

class _DeviceHeroCard extends StatelessWidget {
  const _DeviceHeroCard({
    required this.name,
    required this.status,
    required this.connected,
    required this.connecting,
    required this.batteryPercent,
    required this.charging,
    this.onReconnect,
  });

  final String name;
  final String status;
  final bool connected;
  final bool connecting;
  final int? batteryPercent;
  final bool charging;
  final VoidCallback? onReconnect;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = AppColors.of(context);
    final statusColor = connected
        ? colors.activity
        : connecting
        ? colors.stress
        : theme.colorScheme.onSurfaceVariant;

    return HealthCard(
      title: name,
      caption: status,
      icon: Icons.watch_rounded,
      metricColor: colors.accent,
      trailing: StatusPill(
        icon: charging
            ? CupertinoIcons.battery_charging
            : _batteryIcon(batteryPercent),
        label: batteryPercent == null ? '—' : '$batteryPercent%',
        color: charging
            ? colors.activity
            : (batteryPercent != null && batteryPercent! <= 20)
            ? colors.heart
            : theme.colorScheme.onSurface,
      ),
      child: Padding(
        padding: const EdgeInsets.only(top: kCardInternalSpacing),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Wrap(
              spacing: kSpacingSmall,
              runSpacing: kSpacingSmall,
              children: [
                StatusPill(
                  icon: connected
                      ? CupertinoIcons.checkmark_circle_fill
                      : connecting
                      ? CupertinoIcons.arrow_2_circlepath
                      : CupertinoIcons.xmark_circle_fill,
                  label: status,
                  color: statusColor,
                ),
                if (charging)
                  StatusPill(
                    icon: CupertinoIcons.bolt_fill,
                    label: 'Charging',
                    color: colors.activity,
                  ),
              ],
            ),
            if (onReconnect != null) ...[
              const SizedBox(height: kCardInternalSpacing),
              PrimaryHealthButton(
                label: 'Reconnect',
                icon: Icons.bluetooth,
                onPressed: onReconnect,
              ),
            ],
          ],
        ),
      ),
    );
  }

  IconData _batteryIcon(int? percent) {
    if (percent == null) return CupertinoIcons.battery_empty;
    if (percent <= 15) return CupertinoIcons.battery_empty;
    if (percent <= 40) return CupertinoIcons.battery_25;
    if (percent <= 70) return CupertinoIcons.battery_25;
    return CupertinoIcons.battery_full;
  }
}

class _MetricGrid extends StatelessWidget {
  const _MetricGrid({
    required this.steps,
    required this.calories,
    required this.heartRate,
    required this.distanceMeters,
    required this.colors,
  });

  final int? steps;
  final int? calories;
  final int? heartRate;
  final int? distanceMeters;
  final AppColors colors;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        final columns = width >= 560 ? 4 : 2;
        final maxExtent = (width - (columns - 1) * kGridSpacing) / columns;
        return MetricGrid(
          maxCrossAxisExtent: maxExtent,
          children: [
            HealthCard(
              icon: CupertinoIcons.arrow_up_right,
              title: 'Steps',
              value: _formatInt(steps),
              metricColor: colors.activity,
            ),
            HealthCard(
              icon: CupertinoIcons.heart_fill,
              title: 'Heart',
              value: heartRate == null ? '—' : '$heartRate',
              unit: heartRate == null ? null : 'bpm',
              metricColor: colors.heart,
            ),
            HealthCard(
              icon: CupertinoIcons.flame_fill,
              title: 'Energy',
              value: _formatInt(calories),
              unit: calories == null ? null : 'kcal',
              metricColor: colors.nutrition,
            ),
            HealthCard(
              icon: CupertinoIcons.location_fill,
              title: 'Distance',
              value: distanceMeters == null
                  ? '—'
                  : (distanceMeters! / 1000).toStringAsFixed(2),
              unit: distanceMeters == null ? null : 'km',
              metricColor: colors.accent,
            ),
          ],
        );
      },
    );
  }

  static String _formatInt(int? value) {
    if (value == null) return '—';
    return NumberFormat.compact().format(value);
  }
}

class _RecentActivityCard extends StatelessWidget {
  const _RecentActivityCard({required this.sync});
  final HistorySync sync;

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.of(context);
    if (sync.days.isEmpty) {
      return HealthCard(
        icon: CupertinoIcons.chart_bar,
        title: 'Activity',
        caption: sync.syncing
            ? 'Syncing history from your watch…'
            : 'No history on this phone yet. Open History to sync.',
        onTap: () => context.go('/history'),
        trailing: const ChevronIcon(),
      );
    }

    final today = sync.days.last;
    final sleep = today.sleep.fold<Duration>(
      Duration.zero,
      (total, session) => total + session.duration,
    );
    final heartRate = avgBpm(today.hr);
    final recent = _recentWeek(sync.days);
    final hasSleepTrend = recent.any((day) => day.sleep.isNotEmpty);

    return HealthCard(
      icon: CupertinoIcons.sparkles,
      title: 'Today’s snapshot',
      caption: _subtitle(today),
      metricColor: colors.accent,
      trailing: SyncStatusPill(sync: sync),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SizedBox(height: kCardInternalSpacing),
          Row(
            children: [
              Expanded(
                child: _SnapshotMetric(
                  icon: CupertinoIcons.arrow_up_right,
                  label: 'Steps',
                  value: today.steps == null
                      ? '—'
                      : NumberFormat.compact().format(today.steps),
                  tint: colors.activity,
                ),
              ),
              const SizedBox(width: kGridSpacing),
              Expanded(
                child: _SnapshotMetric(
                  icon: CupertinoIcons.heart_fill,
                  label: 'Average heart',
                  value: heartRate == 0 ? '—' : '$heartRate bpm',
                  tint: colors.heart,
                ),
              ),
              const SizedBox(width: kGridSpacing),
              Expanded(
                child: _SnapshotMetric(
                  icon: CupertinoIcons.moon_fill,
                  label: 'Sleep',
                  value: sleep == Duration.zero ? '—' : _formatDuration(sleep),
                  tint: colors.sleep,
                ),
              ),
            ],
          ),
          const SizedBox(height: kSpacingSmall),
          const Divider(),
          const SizedBox(height: kSpacingSmall),
          _DashboardTrendPreview(
            icon: CupertinoIcons.arrow_up_right,
            title: 'Steps this week',
            detail: 'Last 7 days',
            tint: colors.activity,
            child: StepsBarChart(
              days: recent,
              height: 74,
              barColor: colors.activity,
            ),
          ),
          if (hasSleepTrend) ...[
            const SizedBox(height: kCardInternalSpacing),
            _DashboardTrendPreview(
              icon: CupertinoIcons.moon_fill,
              title: 'Sleep this week',
              detail: 'Last 7 nights',
              tint: colors.sleep,
              child: SleepTrendChart(
                days: recent,
                height: 74,
                sleepColor: colors.sleep,
              ),
            ),
          ],
          TextButton.icon(
            onPressed: () => context.go('/history'),
            icon: const Icon(CupertinoIcons.chart_bar_alt_fill),
            label: const Text('Explore trends and daily charts'),
          ),
        ],
      ),
    );
  }

  List<DailyHistory> _recentWeek(List<DailyHistory> days) {
    final byDay = {for (final day in days) day.day: day};
    final end = days.last.day;
    return [
      for (var offset = -6; offset <= 0; offset++)
        byDay[end.addDays(offset)] ?? DailyHistory(day: end.addDays(offset)),
    ];
  }

  String _subtitle(DailyHistory today) {
    final parts = <String>[];
    final avg = avgBpm(today.hr);
    if (avg > 0) parts.add('$avg bpm avg');
    if (today.steps != null) {
      parts.add('${NumberFormat.decimalPattern().format(today.steps)} steps');
    }
    if (today.sleep.isNotEmpty) {
      final total = today.sleep.fold<Duration>(
        Duration.zero,
        (a, s) => a + s.duration,
      );
      parts.add('${(total.inMinutes / 60).toStringAsFixed(1)}h sleep');
    }
    return parts.isEmpty
        ? DateFormat.yMMMd().format(today.day.midnight)
        : parts.join(' · ');
  }
}

class _DashboardTrendPreview extends StatelessWidget {
  const _DashboardTrendPreview({
    required this.icon,
    required this.title,
    required this.detail,
    required this.tint,
    required this.child,
  });

  final IconData icon;
  final String title;
  final String detail;
  final Color tint;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(icon, size: kIconSizeTiny, color: tint),
            const SizedBox(width: kSpacingSmall),
            Expanded(
              child: Text(title, style: AppTextStyles.titleSmall(context)),
            ),
            Text(
              detail,
              style: AppTextStyles.labelMedium(context)?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
        const SizedBox(height: kSpacingTiny),
        child,
      ],
    );
  }
}

class _SnapshotMetric extends StatelessWidget {
  const _SnapshotMetric({
    required this.icon,
    required this.label,
    required this.value,
    required this.tint,
  });

  final IconData icon;
  final String label;
  final String value;
  final Color tint;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(kSpacingSmall),
      decoration: BoxDecoration(
        color: tint.withValues(alpha: kMetricTintOpacity),
        borderRadius: BorderRadius.circular(kChipRadius + kSpacingTiny),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: kIconSizeTiny, color: tint),
          const SizedBox(height: kSpacingSmall),
          Text(
            value,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: AppTextStyles.titleSmall(
              context,
            )?.copyWith(color: Theme.of(context).colorScheme.onSurface),
          ),
          const SizedBox(height: kSpacingMini),
          Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: AppTextStyles.bodySmall(context),
          ),
        ],
      ),
    );
  }
}

String _formatDuration(Duration d) {
  final h = d.inMinutes ~/ 60;
  final m = d.inMinutes.remainder(60);
  if (m == 0) return '${h}h';
  return '${h}h ${m}m';
}

class _QuickActions extends StatelessWidget {
  const _QuickActions({
    required this.ready,
    required this.syncingHistory,
    required this.findDevice,
    required this.syncTime,
    required this.syncHistory,
  });

  final bool ready;
  final bool syncingHistory;
  final VoidCallback findDevice;
  final VoidCallback syncTime;
  final VoidCallback syncHistory;

  @override
  Widget build(BuildContext context) {
    return InsetCard(
      padding: EdgeInsets.zero,
      child: Column(
        children: [
          HealthListTile(
            title: 'Find watch',
            subtitle: 'Ring the watch so you can locate it',
            leadingIcon: CupertinoIcons.waveform,
            onTap: ready ? findDevice : null,
          ),
          HealthListTile(
            title: 'Sync time',
            subtitle: 'Set the watch clock to this phone',
            leadingIcon: CupertinoIcons.clock,
            onTap: ready ? syncTime : null,
          ),
          HealthListTile(
            title: syncingHistory ? 'Syncing history…' : 'Sync history',
            subtitle: 'Pull missing days onto this phone',
            leadingIcon: CupertinoIcons.arrow_2_circlepath,
            onTap: ready && !syncingHistory ? syncHistory : null,
          ),
          HealthListTile(
            title: 'Open history',
            subtitle: 'Charts, sleep, and daily detail',
            leadingIcon: CupertinoIcons.chart_bar,
            trailingChevron: true,
            onTap: () => context.go('/history'),
            showDivider: false,
          ),
        ],
      ),
    );
  }
}

class _AlarmsSummary extends StatelessWidget {
  const _AlarmsSummary({required this.count, required this.next});

  final int count;
  final Alarm next;

  @override
  Widget build(BuildContext context) {
    final time = next.labelTime;
    final colors = AppColors.of(context);
    return InsetCard(
      padding: EdgeInsets.zero,
      child: HealthListTile(
        title: 'Clock alarms',
        subtitle: '$count armed — next at $time',
        leadingIcon: CupertinoIcons.alarm,
        leadingColor: colors.accent,
        value: '$count',
        onTap: () => GoRouter.of(context).push('/alarms'),
        showDivider: false,
      ),
    );
  }
}

class _NowPlayingCard extends StatelessWidget {
  const _NowPlayingCard({required this.music});

  final MusicRsp music;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = AppColors.of(context);
    final tint = music.isPlaying
        ? colors.accent
        : theme.colorScheme.onSurfaceVariant;
    // Wire volume is 0..255; show as percent for humans.
    final volPct = ((music.volume.clamp(0, 255) / 255) * 100).round();
    return HealthCard(
      icon: music.isPlaying
          ? CupertinoIcons.music_note_2
          : CupertinoIcons.pause_circle,
      title: 'Now playing',
      caption: music.track,
      metricColor: tint,
      trailing: StatusPill(
        icon: volPct == 0
            ? CupertinoIcons.volume_off
            : volPct < 40
            ? CupertinoIcons.volume_down
            : CupertinoIcons.volume_up,
        label: '$volPct%',
        color: theme.colorScheme.onSurfaceVariant,
      ),
    );
  }
}
