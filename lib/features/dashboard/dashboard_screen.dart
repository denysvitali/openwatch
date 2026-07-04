import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../core/ble/ble_transport.dart';
import '../../core/protocol/channel_a.dart';
import '../../core/providers/app_providers.dart';
import '../../core/services/history_sync.dart';
import '../history/widgets/hr_chart.dart';
import '../history/widgets/sleep_trend_chart.dart';
import '../history/widgets/steps_chart.dart';
import '../widgets/inset_card.dart';
import '../widgets/sync_status_pill.dart';

/// Device overview: connection state, firmware, battery, steps + quick actions.
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
        title: const Text('Device'),
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
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
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
                const SizedBox(height: 12),
              ],
              _MetricGrid(
                steps: manager.todaySteps ?? today?.steps,
                calories: manager.todayCalories ?? today?.energyKcal,
                heartRate: heartRate == 0 ? null : heartRate,
                distanceMeters: today?.distanceMeters,
              ),
              const SizedBox(height: 12),
              _RecentActivityCard(sync: sync),
              const SizedBox(height: 12),
              _QuickActions(
                ready: link == LinkState.ready,
                syncingHistory: sync.syncing,
                findDevice: manager.findDevice,
                syncTime: manager.syncTime,
                syncHistory: sync.syncAll,
              ),
              const SizedBox(height: 12),
              if (armedAlarms.isNotEmpty)
                _AlarmsSummary(
                  count: armedAlarms.length,
                  next: armedAlarms.first,
                ),
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

    return InsetCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 64,
                height: 64,
                decoration: BoxDecoration(
                  color: theme.colorScheme.primary.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Icon(
                  Icons.watch_rounded,
                  color: theme.colorScheme.primary,
                  size: 34,
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(name, style: theme.textTheme.headlineSmall),
                    const SizedBox(height: 4),
                    Row(
                      children: [
                        Container(
                          width: 8,
                          height: 8,
                          decoration: BoxDecoration(
                            color: statusColor,
                            shape: BoxShape.circle,
                          ),
                        ),
                        const SizedBox(width: 6),
                        Text(
                          status,
                          style: theme.textTheme.bodyMedium?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              _BatteryBadge(percent: batteryPercent, charging: charging),
            ],
          ),
          const SizedBox(height: 18),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              _InfoPill(
                icon: CupertinoIcons.square_stack_3d_up,
                label: firmware.isEmpty ? 'Firmware -' : 'Firmware $firmware',
              ),
              _InfoPill(
                icon: Icons.memory_rounded,
                label: hardware.isEmpty ? 'Hardware -' : 'Hardware $hardware',
              ),
            ],
          ),
        ],
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
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            charging
                ? CupertinoIcons.battery_charging
                : CupertinoIcons.battery_100,
            size: 18,
            color: color,
          ),
          const SizedBox(width: 6),
          Text(
            percent == null ? '-' : '$percent%',
            style: theme.textTheme.labelLarge?.copyWith(color: color),
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
    return GridView.count(
      crossAxisCount: 2,
      crossAxisSpacing: 12,
      mainAxisSpacing: 12,
      childAspectRatio: 1.52,
      physics: const NeverScrollableScrollPhysics(),
      shrinkWrap: true,
      children: [
        _MetricTile(
          icon: CupertinoIcons.arrow_up_right,
          label: 'Steps',
          value: _formatInt(steps),
          tint: Theme.of(context).colorScheme.primary,
        ),
        _MetricTile(
          icon: CupertinoIcons.heart_fill,
          label: 'Heart',
          value: heartRate == null ? '-' : '$heartRate',
          unit: heartRate == null ? null : 'bpm',
          tint: const Color(0xFFFF3B30),
        ),
        _MetricTile(
          icon: CupertinoIcons.flame_fill,
          label: 'Energy',
          value: _formatInt(calories),
          unit: calories == null ? null : 'kcal',
          tint: const Color(0xFFFF9500),
        ),
        _MetricTile(
          icon: CupertinoIcons.location_fill,
          label: 'Distance',
          value: distanceMeters == null
              ? '-'
              : (distanceMeters! / 1000).toStringAsFixed(2),
          unit: distanceMeters == null ? null : 'km',
          tint: const Color(0xFF34C759),
        ),
      ],
    );
  }

  static String _formatInt(int? value) {
    if (value == null) return '-';
    return NumberFormat.compact().format(value);
  }
}

class _MetricTile extends StatelessWidget {
  const _MetricTile({
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
    return InsetCard(
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Row(
            children: [
              Icon(icon, color: tint, size: 18),
              const SizedBox(width: 6),
              Text(
                label,
                style: theme.textTheme.labelLarge?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
          FittedBox(
            alignment: Alignment.centerLeft,
            fit: BoxFit.scaleDown,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(
                  value,
                  style: theme.textTheme.headlineSmall?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
                if (unit != null) ...[
                  const SizedBox(width: 4),
                  Padding(
                    padding: const EdgeInsets.only(bottom: 4),
                    child: Text(
                      unit!,
                      style: theme.textTheme.labelLarge?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
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
      return InsetCard(
        child: Row(
          children: [
            Icon(CupertinoIcons.chart_bar, color: theme.colorScheme.primary),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                sync.syncing
                    ? 'Syncing history'
                    : 'No history stored on this phone yet',
                style: theme.textTheme.bodyMedium,
              ),
            ),
            TextButton(
              onPressed: () => context.push('/history'),
              child: const Text('History'),
            ),
          ],
        ),
      );
    }

    final recent = _recentWeek(sync.days);
    final sleepSummary = SleepTrendSummary.fromDays(recent);
    final today = sync.days.last;

    return InsetCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text('Activity', style: theme.textTheme.titleLarge),
              ),
              SyncStatusPill(sync: sync),
            ],
          ),
          const SizedBox(height: 2),
          Text(
            _subtitle(today),
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 16),
          if (today.hr.isNotEmpty) ...[
            MiniHrSpark(samples: today.hr, height: 58),
            const SizedBox(height: 14),
          ],
          if (sleepSummary.hasData) ...[
            _SleepTrendHeader(summary: sleepSummary),
            const SizedBox(height: 8),
            SleepTrendChart(days: recent, height: 104),
            const SizedBox(height: 14),
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
        Icon(
          CupertinoIcons.moon_fill,
          size: 17,
          color: const Color(0xFF5856D6),
        ),
        const SizedBox(width: 6),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Sleep trend', style: theme.textTheme.titleSmall),
              Text(
                trendText,
                style: theme.textTheme.labelSmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
        Text(
          'Week avg ${_formatDuration(summary.average)}',
          style: theme.textTheme.labelMedium?.copyWith(
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
          crossAxisSpacing: 10,
          mainAxisSpacing: 10,
          childAspectRatio: wide ? 2.55 : 3.2,
          physics: const NeverScrollableScrollPhysics(),
          shrinkWrap: true,
          children: [
            FilledButton.tonalIcon(
              onPressed: ready ? findDevice : null,
              icon: const Icon(CupertinoIcons.waveform),
              label: const Text('Find'),
            ),
            FilledButton.tonalIcon(
              onPressed: ready ? syncTime : null,
              icon: const Icon(CupertinoIcons.clock),
              label: const Text('Time'),
            ),
            FilledButton.tonalIcon(
              onPressed: ready && !syncingHistory ? syncHistory : null,
              icon: syncingHistory
                  ? const SizedBox.square(
                      dimension: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(CupertinoIcons.arrow_2_circlepath),
              label: Text(syncingHistory ? 'Syncing' : 'Sync'),
            ),
            FilledButton.tonalIcon(
              onPressed: () => context.push('/history'),
              icon: const Icon(CupertinoIcons.chart_bar),
              label: const Text('History'),
            ),
          ],
        );
      },
    );
  }
}

/// Compact inset card showing how many clock alarms the user has set
/// and the earliest one. Tapping the card opens the alarms editor.
class _AlarmsSummary extends StatelessWidget {
  const _AlarmsSummary({required this.count, required this.next});

  final int count;
  final Alarm next;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final time = next.labelTime;
    return InkWell(
      onTap: () => GoRouter.of(context).push('/alarms'),
      borderRadius: BorderRadius.circular(12),
      child: InsetCard(
        child: Row(
          children: [
            Icon(Icons.alarm, color: theme.colorScheme.primary),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Clock alarms', style: theme.textTheme.titleSmall),
                  const SizedBox(height: 2),
                  Text(
                    '$count armed — next at $time',
                    style: theme.textTheme.bodySmall,
                  ),
                ],
              ),
            ),
            const Icon(CupertinoIcons.chevron_right),
          ],
        ),
      ),
    );
  }
}

class _InfoPill extends StatelessWidget {
  const _InfoPill({required this.icon, required this.label});

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 15, color: theme.colorScheme.onSurfaceVariant),
          const SizedBox(width: 6),
          Text(label, style: theme.textTheme.labelMedium),
        ],
      ),
    );
  }
}

/// Surfaces the watch's now-playing push (`0x1d`) without taking over
/// the screen — a compact inset that sits between the hero card and
/// the metric grid.
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
    return InsetCard(
      child: Row(
        children: [
          // Album-art placeholder. H59MA firmware does not expose a
          // thumbnail on the 0x1d wire frame (PROTOCOL.md §3.1) so
          // the card is intentionally art-less; a future live capture
          // with embedded artwork would slot in here.
          Container(
            width: 48,
            height: 48,
            decoration: BoxDecoration(
              color: tint.withValues(alpha: 0.14),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Icon(
              music.isPlaying
                  ? CupertinoIcons.music_note_2
                  : CupertinoIcons.pause_circle,
              color: tint,
              size: 26,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  'Now playing',
                  style: theme.textTheme.labelMedium?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  music.track,
                  style: theme.textTheme.titleMedium,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
          // Volume as a single glyph chip — keeps the card compact
          // and avoids a second progress bar that would compete with
          // the metric grid below.
          _VolumeChip(volume: music.volume),
        ],
      ),
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
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 16, color: theme.colorScheme.onSurfaceVariant),
          const SizedBox(width: 4),
          Text('$volume', style: theme.textTheme.labelMedium),
        ],
      ),
    );
  }
}
