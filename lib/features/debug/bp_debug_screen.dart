import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../core/providers/app_providers.dart';
import '../../core/services/bp_raw_store.dart';
import '../../core/services/history_store.dart' show DateOnly;
import '../../core/ui/ui_constants.dart';
import '../widgets/health_widgets.dart';
import '../widgets/inset_card.dart';

/// Debug-only screen that dumps the compact raw BP bytes the watch emitted so
/// future capture work can correlate them with known readings.
///
/// Each persisted day is a card showing:
///   * the day + slot-duration header
///   * one row per set bit in the header's 48-bit presence bitmap,
///     indexed by slot id with the derived timestamp
///   * the raw compact byte as hex (`ab`) and decimal (`[171]`)
///   * a copy button so a tester can paste a single row into a chat
///     without screenshotting
///
/// Wired from `Settings → Diagnostics → BP raw bytes` and intended
/// for use only by contributors running a live BLE capture.
class BpDebugScreen extends ConsumerWidget {
  const BpDebugScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final storeAsync = ref.watch(bpRawStoreProvider);
    return Scaffold(
      appBar: AppBar(
        title: const Text('BP raw bytes'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: 'Refresh',
            onPressed: () {
              // The FutureProvider caches by default; invalidate so
              // a re-tap of the tile pulls the latest on-disk state.
              ref.invalidate(bpRawStoreProvider);
            },
          ),
        ],
      ),
      body: storeAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, st) => _ErrorView(message: e.toString()),
        data: (store) => _DayList(store: store),
      ),
    );
  }
}

class _DayList extends StatelessWidget {
  const _DayList({required this.store});

  final BpRawStore store;

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<List<DateOnly>>(
      future: store.persistedDays(),
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return const Center(child: CircularProgressIndicator());
        }
        final days = snapshot.data ?? const <DateOnly>[];
        if (days.isEmpty) {
          return const _EmptyState();
        }
        return ListView.builder(
          padding: const EdgeInsets.fromLTRB(
            kScreenPaddingH,
            kScreenPaddingTop,
            kScreenPaddingH,
            kScreenPaddingBottom,
          ),
          itemCount: days.length,
          itemBuilder: (context, i) =>
              _DayCard(day: days[i], loader: () => store.readDay(days[i])),
        );
      },
    );
  }
}

class _DayCard extends StatelessWidget {
  const _DayCard({required this.day, required this.loader});

  final DateOnly day;
  final Future<RawBpDay> Function() loader;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: kGridSpacing),
      child: HealthCard(
        icon: Icons.bloodtype_outlined,
        metricColor: theme.colorScheme.error,
        title: day.iso,
        child: FutureBuilder<RawBpDay>(
          future: loader(),
          builder: (context, snapshot) {
            if (snapshot.connectionState != ConnectionState.done) {
              return const Padding(
                padding: EdgeInsets.only(top: kGridSpacing),
                child: SizedBox(
                  height: 48,
                  child: Center(child: CircularProgressIndicator()),
                ),
              );
            }
            final raw = snapshot.data;
            if (raw == null || raw.isEmpty) {
              return const Padding(
                padding: EdgeInsets.only(top: kGridSpacing),
                child: Text('No raw bytes for this day'),
              );
            }
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.only(bottom: kSpacingSmall),
                  child: StatusPill(
                    icon: Icons.access_time,
                    label:
                        '${raw.slots.length} slots · ${raw.slotMinutes} min each',
                    color: theme.colorScheme.error,
                  ),
                ),
                InsetCard(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      for (var i = 0; i < raw.slots.length; i++)
                        _SlotRow(
                          slot: raw.slots[i],
                          slotMinutes: raw.slotMinutes,
                          showDivider: i < raw.slots.length - 1,
                          leadingColor: theme.colorScheme.error,
                        ),
                    ],
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

class _SlotRow extends StatelessWidget {
  const _SlotRow({
    required this.slot,
    required this.slotMinutes,
    required this.showDivider,
    required this.leadingColor,
  });

  final RawBpSlot slot;
  final int slotMinutes;
  final bool showDivider;
  final Color leadingColor;

  @override
  Widget build(BuildContext context) {
    final hex = _formatHex(slot.bytes);
    final dec = _formatDec(slot.bytes);
    final time = DateFormat.Hms().format(slot.timestamp);
    final timePlusOffset = slotMinutes == 0
        ? time
        : '$time (+${slot.slotIndex * slotMinutes}m)';
    return HealthListTile(
      leadingIcon: Icons.access_time_filled,
      leadingColor: leadingColor,
      title: '#${slot.slotIndex.toString().padLeft(2, '0')}  $timePlusOffset',
      subtitle: '$hex\n$dec',
      showDivider: showDivider,
      trailing: IconButton(
        icon: const Icon(Icons.copy),
        tooltip: 'Copy row',
        onPressed: () async {
          final payload =
              'slot=${slot.slotIndex} '
              't=${slot.timestamp.toIso8601String()} '
              'hex=$hex dec=$dec';
          await Clipboard.setData(ClipboardData(text: payload));
          if (context.mounted) {
            ScaffoldMessenger.of(
              context,
            ).showSnackBar(const SnackBar(content: Text('Row copied')));
          }
        },
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState();

  @override
  Widget build(BuildContext context) {
    return const Center(
      child: Padding(
        padding: EdgeInsets.all(kEmptyStatePadding),
        child: HealthCard(
          icon: Icons.bloodtype_outlined,
          title: 'No BP raw bytes on disk yet',
          caption:
              'Sync history from the watch to populate the sidecar. '
              'Once at least one BP day is fetched, the raw byte per present '
              'slot will appear here for inspection.',
        ),
      ),
    );
  }
}

class _ErrorView extends StatelessWidget {
  const _ErrorView({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: HealthCard(
          icon: Icons.error_outline,
          metricColor: Theme.of(context).colorScheme.error,
          title: 'Failed to open BP raw store',
          caption: message,
        ),
      ),
    );
  }
}

String _formatHex(List<int> bytes) {
  final sb = StringBuffer('hex:');
  for (final b in bytes) {
    sb.write(' ${b.toRadixString(16).padLeft(2, '0')}');
  }
  return sb.toString();
}

String _formatDec(List<int> bytes) {
  final sb = StringBuffer('dec:[');
  for (var i = 0; i < bytes.length; i++) {
    if (i > 0) sb.write(', ');
    sb.write(bytes[i].toString());
  }
  sb.write(']');
  return sb.toString();
}
