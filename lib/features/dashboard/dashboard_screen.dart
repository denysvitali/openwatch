import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../core/ble/ble_transport.dart';
import '../../core/protocol/channel_a.dart';
import '../../core/providers/app_providers.dart';
import '../../core/services/history_sync.dart';
import '../../core/ui/ui_constants.dart';
import '../history/widgets/hr_chart.dart';
import '../history/widgets/sleep_trend_chart.dart';
import '../history/widgets/steps_chart.dart';
import '../widgets/health_widgets.dart';
import '../widgets/sync_status_pill.dart';

/// Summary overview: connection state, device info, live metrics, and quick
/// actions. This screen was previously called "Dashboard" and has been
/// refreshed to match the Apple Health-like design system.
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
          IconButton(
            icon: const Icon(CupertinoIcons.xmark_circle),
            tooltip: 'Disconnect',
            onPressed: () async {
              await ref.read(bleTransportProvider).disconnect();
              if (context.mounted) context.go('/scan');
            },
          ),
        ],
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 860),
          child: ListView(
            padding: const EdgeInsets.fromLTRB(
              kCardPadding,
              kSpacingSmall,
              kCardPadding,
              kCardPadding + kSpacingSmall,
            ),
            children: [
              _DeviceHeroCard(
                name: name,
                status: _describe(link),
                connected: link == LinkState.ready,
                batteryPercent: manager.batteryPercent,
                charging: manager.charging,
                firmware: manager.firmwareRevision,
                hardware: manager.hardwareRevision,
              ),
              if (manager.nowPlaying != null &&
                  manager.nowPlaying!.track.isNotEmpty) ...[
                _NowPlayingCard(music: manager.nowPlaying!),
                const SizedBox(height: kSpacingSmall),
              ],
              const HealthSectionHeader(title: 'Metrics'),
              _MetricGrid(
                steps: manager.todaySteps ?? today?.steps,
                calories: manager.todayCalories ?? today?.energyKcal,
                heartRate: heartRate == 0 ? null : heartRate,
                distanceMeters: today?.distanceMeters,
              ),
              const HealthSectionHeader(title: 'Recent Activity'),
              _RecentActivityCard(sync: sync),
              const HealthSectionHeader(title: 'Actions'),
              _QuickActions(
                ready: link == LinkState.ready,
                syncingHistory: sync.syncing,
                findDevice: manager.findDevice,
                syncTime: manager.syncTime,
                syncHistory: sync.syncAll,
              ),
              if (armedAlarms.isNotEmpty) ...[
                const HealthSectionHeader(title: 'Alarms', onShowAll: null),
                _AlarmsSummary(
                  count: armedAlarms.length,
                  next: armedAlarms.first,
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  String _describe(LinkState s) => switch (s) {
    LinkState.ready => 'Connected',
    LinkState.connecting => 'Connecting',
    LinkState.disconnected => 'Disconnected',
    LinkState.discovering => 'Discovering services',
    LinkState.readingDeviceInfo => 'Reading device info',
  };
}

class _DeviceHeroCard extends StatelessWidget {
  const _DeviceHeroCard({
    required this.name,
    required this.status,
    required this.connected,
    required this.batteryPercent,
    required this.charging,
    required this.firmware,
    required this.hardware,
  });

  final String name;
  final String status;
  final bool connected;
  final int? batteryPercent;
  final bool charging;
  final String firmware;
  final String hardware;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final statusColor = connected
        ? theme.colorScheme.secondary
        : theme.colorScheme.onSurfaceVariant;

    return HealthCard(
      title: name,
      caption: status,
      icon: Icons.watch_rounded,
      metricColor: theme.colorScheme.primary,
      trailing: _BatteryBadge(percent: batteryPercent, charging: charging),
      child: Padding(
        padding: const EdgeInsets.only(top: kSpacingSmall),
        child: Wrap(
          spacing: kSpacingSmall,
          runSpacing: kSpacingSmall,
          children: [
            StatusPill(
              icon: connected
                  ? CupertinoIcons.checkmark_circle_fill
                  : CupertinoIcons.xmark_circle_fill,
              label: status,
              color: statusColor,
            ),
            StatusPill(
              icon: CupertinoIcons.square_stack_3d_up,
              label: firmware.isEmpty ? 'Firmware -' : 'Firmware $firmware',
            ),
            StatusPill(
              icon: Icons.memory_rounded,
              label: hardware.isEmpty ? 'Hardware -' : 'Hardware $hardware',
            ),
          ],
        ),
      ),
    );
  }
}

class _BatteryBadge extends StatelessWidget {
  const _BatteryBadge({required this.percent, required this.charging});

  final int? percent;
  final bool charging;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = charging
        ? theme.colorScheme.secondary
        : theme.colorScheme.onSurface;

    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: kSpacingSmall,
        vertical: kSpacingTiny,
      ),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(kSpacingSmall + kSpacingTiny),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            charging
                ? CupertinoIcons.battery_charging
                : CupertinoIcons.battery_100,
            size: kIconSizeSmall,
            color: color,
          ),
          SizedBox(width: kSpacingTiny + kSpacingMini),
          Text(
            percent == null ? '-' : '$percent%',
            style: AppTextStyles.labelMedium(context)?.copyWith(color: color),
          ),
        ],
      ),
    );
  }
}

class _MetricGrid extends StatelessWidget {
  const _MetricGrid({
    required this.steps,
    required this.calories,
    required this.heartRate,
    required this.distanceMeters,
  });

  final int? steps;
  final int? calories;
  final int? heartRate;
  final int? distanceMeters;

  @override
  Widget build(BuildContext context) {
    return MetricGrid(
      children: [
        HealthCard(
          icon: CupertinoIcons.arrow_up_right,
          title: 'Steps',
          value: _formatInt(steps),
        ),
        HealthCard(
          icon: CupertinoIcons.heart_fill,
          title: 'Heart',
          value: heartRate == null ? '-' : '$heartRate',
          unit: heartRate == null ? null : 'bpm',
        ),
        HealthCard(
          icon: CupertinoIcons.flame_fill,
          title: 'Energy',
          value: _formatInt(calories),
          unit: calories == null ? null : 'kcal',
        ),
        HealthCard(
          icon: CupertinoIcons.location_fill,
          title: 'Distance',
          value: distanceMeters == null
              ? '-'
              : (distanceMeters! / 1000).toStringAsFixed(2),
          unit: distanceMeters == null ? null : 'km',
        ),
      ],
    );
  }

  static String _formatInt(int? value) {
    if (value == null) return '-';
    return NumberFormat.compact().format(value);
  }
}

/// Surfaces the most-recent locally-stored activity without forcing the
/// user to navigate to `/history`.
class _RecentActivityCard extends StatelessWidget {
  const _RecentActivityCard({required this.sync});
  final HistorySync sync;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (sync.days.isEmpty) {
      return HealthCard(
        icon: CupertinoIcons.chart_bar,
        title: 'Activity',
        caption: sync.syncing
            ? 'Syncing history from your watch...'
            : 'No history stored on this phone yet. Tap to open History.',
        onTap: () => context.push('/history'),
        trailing: Icon(
          CupertinoIcons.chevron_forward,
          color: theme.colorScheme.onSurfaceVariant,
        ),
      );
    }

    final recent = _recentWeek(sync.days);
    final sleepSummary = SleepTrendSummary.fromDays(recent);
    final today = sync.days.last;

    return HealthCard(
      icon: CupertinoIcons.chart_bar_alt_fill,
      title: 'Activity',
      caption: _subtitle(today),
      metricColor: theme.colorScheme.primary,
      trailing: SyncStatusPill(sync: sync),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SizedBox(height: kCardInternalSpacing),
          if (today.hr.isNotEmpty) ...[
            MiniHrSpark(samples: today.hr, height: 48),
            const SizedBox(height: kSpacingSmall),
          ],
          if (sleepSummary.hasData) ...[
            _SleepTrendHeader(summary: sleepSummary),
            const SizedBox(height: kSpacingSmall),
            SleepTrendChart(days: recent, height: 80),
            const SizedBox(height: kSpacingSmall),
          ],
          StepsBarChart(days: recent),
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

class _SleepTrendHeader extends StatelessWidget {
  const _SleepTrendHeader({required this.summary});

  final SleepTrendSummary summary;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final trend = summary.trendMinutes;
    final trendText = trend == null
        ? 'Daily sleep time'
        : '${trend >= 0 ? '+' : '-'}${_formatTrendMinutes(trend.abs())} vs prior';
    return Row(
      children: [
        Container(
          width: kIconCircleSizeSmall,
          height: kIconCircleSizeSmall,
          decoration: BoxDecoration(
            color: theme.colorScheme.primary.withValues(alpha: kMetricTintOpacity),
            shape: BoxShape.circle,
          ),
          alignment: Alignment.center,
          child: Icon(
            CupertinoIcons.moon_fill,
            size: kIconSizeSmall,
            color: theme.colorScheme.primary,
          ),
        ),
        const SizedBox(width: kGridSpacing),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Sleep trend',
                style: AppTextStyles.titleSmall(context)
                    ?.copyWith(fontWeight: FontWeight.w600),
              ),
              Text(trendText, style: AppTextStyles.labelMedium(context)),
            ],
          ),
        ),
        Text(
          'Week avg ${_formatDuration(summary.average)}',
          style: AppTextStyles.labelSmall(context)?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
      ],
    );
  }

  static String _formatDuration(Duration d) {
    final h = d.inMinutes ~/ 60;
    final m = d.inMinutes.remainder(60);
    if (m == 0) return '${h}h';
    return '${h}h ${m}m';
  }

  static String _formatTrendMinutes(int minutes) {
    if (minutes < 60) return '${minutes}m';
    final h = minutes ~/ 60;
    final m = minutes.remainder(60);
    if (m == 0) return '${h}h';
    return '${h}h ${m}m';
  }
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
    return LayoutBuilder(
      builder: (context, constraints) {
        final wide = constraints.maxWidth >= 560;
        return GridView.count(
          crossAxisCount: wide ? 4 : 2,
          crossAxisSpacing: kGridSpacing,
          mainAxisSpacing: kGridSpacing,
          childAspectRatio: wide ? 2.55 : 3.2,
          physics: const NeverScrollableScrollPhysics(),
          shrinkWrap: true,
          children: [
            PrimaryHealthButton(
              label: 'Find',
              icon: CupertinoIcons.waveform,
              onPressed: ready ? findDevice : null,
            ),
            PrimaryHealthButton(
              label: 'Time',
              icon: CupertinoIcons.clock,
              onPressed: ready ? syncTime : null,
            ),
            PrimaryHealthButton(
              label: syncingHistory ? 'Syncing' : 'Sync',
              icon: syncingHistory ? null : CupertinoIcons.arrow_2_circlepath,
              onPressed: ready && !syncingHistory ? syncHistory : null,
            ),
            PrimaryHealthButton(
              label: 'History',
              icon: CupertinoIcons.chart_bar,
              onPressed: () => context.push('/history'),
            ),
          ],
        );
      },
    );
  }
}

/// Compact row showing how many clock alarms the user has set and the
/// earliest one. Tapping the row opens the alarms editor.
class _AlarmsSummary extends StatelessWidget {
  const _AlarmsSummary({required this.count, required this.next});

  final int count;
  final Alarm next;

  @override
  Widget build(BuildContext context) {
    final time = next.labelTime;
    final theme = Theme.of(context);
    return HealthListTile(
      title: 'Clock alarms',
      subtitle: '$count armed — next at $time',
      leadingIcon: Icons.alarm,
      leadingColor: theme.colorScheme.primary,
      value: '$count',
      onTap: () => GoRouter.of(context).push('/alarms'),
    );
  }
}

/// Surfaces the watch's now-playing push (`0x1d`) without taking over
/// the screen — a compact card that sits between the hero card and the
/// metric grid.
///
/// Only rendered when [WatchManager.nowPlaying] is non-null AND
/// carries a non-empty track name. The `MusicRsp` decoder emits an
/// empty `track` when the wire bytes don't include one, so hiding
/// the card on `track.isEmpty` keeps a malformed push from showing
/// as a blank row.
class _NowPlayingCard extends StatelessWidget {
  const _NowPlayingCard({required this.music});

  final MusicRsp music;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tint = music.isPlaying
        ? theme.colorScheme.primary
        : theme.colorScheme.onSurfaceVariant;
    return HealthCard(
      icon: music.isPlaying
          ? CupertinoIcons.music_note_2
          : CupertinoIcons.pause_circle,
      title: 'Now playing',
      caption: music.track,
      metricColor: tint,
      trailing: _VolumeChip(volume: music.volume),
    );
  }
}

class _VolumeChip extends StatelessWidget {
  const _VolumeChip({required this.volume});
  final int volume;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final icon = volume == 0
        ? CupertinoIcons.volume_off
        : volume < 64
        ? CupertinoIcons.volume_down
        : CupertinoIcons.volume_up;
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: kSpacingSmall,
        vertical: kSpacingTiny,
      ),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(kPillRadius),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: kIconSizeTiny, color: theme.colorScheme.onSurfaceVariant),
          const SizedBox(width: kSpacingTiny),
          Text('$volume', style: AppTextStyles.labelMedium(context)),
        ],
      ),
    );
  }
}
