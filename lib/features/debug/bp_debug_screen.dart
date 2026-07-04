import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../core/providers/app_providers.dart';
import '../../core/services/bp_raw_store.dart';
import '../../core/services/history_store.dart' show DateOnly;

/// Debug-only screen that dumps the raw 13-byte BP records the watch
/// emitted, byte-by-byte, so a future live-capture session can map the
/// 13 slots in `PROTOCOL.md §8.5` to actual fields.
///
/// Each persisted day is a card showing:
///   * the day + slot-duration header
///   * one row per set bit in the header's 48-bit presence bitmap,
///     indexed by slot id with the derived timestamp
///   * the 13 raw bytes as space-separated hex (`ab cd ef ...`) and
///     decimal (`[171, 205, 239, ...]`)
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
          padding: const EdgeInsets.symmetric(vertical: 8),
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
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: FutureBuilder<RawBpDay>(
          future: loader(),
          builder: (context, snapshot) {
            if (snapshot.connectionState != ConnectionState.done) {
              return const SizedBox(
                height: 48,
                child: Center(child: CircularProgressIndicator()),
              );
            }
            final raw = snapshot.data;
            if (raw == null || raw.isEmpty) {
              return const Text('No raw bytes for this day');
            }
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(day.iso, style: Theme.of(context).textTheme.titleMedium),
                Text(
                  '${raw.slots.length} slot(s) · ${raw.slotMinutes} min each',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                const SizedBox(height: 8),
                for (final slot in raw.slots)
                  _SlotRow(slot: slot, slotMinutes: raw.slotMinutes),
              ],
            );
          },
        ),
      ),
    );
  }
}

class _SlotRow extends StatelessWidget {
  const _SlotRow({required this.slot, required this.slotMinutes});

  final RawBpSlot slot;
  final int slotMinutes;

  @override
  Widget build(BuildContext context) {
    final hex = _formatHex(slot.bytes);
    final dec = _formatDec(slot.bytes);
    final time = DateFormat.Hms().format(slot.timestamp);
    final timePlusOffset = slotMinutes == 0
        ? time
        : '$time (+${slot.slotIndex * slotMinutes}m)';
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  '#${slot.slotIndex.toString().padLeft(2, '0')}  '
                  '$timePlusOffset',
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
              ),
              IconButton(
                visualDensity: VisualDensity.compact,
                icon: const Icon(Icons.copy, size: 18),
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
            ],
          ),
          SelectableText(
            hex,
            style: const TextStyle(
              fontFamily: 'monospace',
              fontFamilyFallback: ['Menlo', 'Consolas'],
            ),
          ),
          SelectableText(
            dec,
            style: const TextStyle(
              fontFamily: 'monospace',
              fontFamilyFallback: ['Menlo', 'Consolas'],
              fontSize: 12,
            ),
          ),
          const Divider(),
        ],
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.bloodtype_outlined, size: 48),
            const SizedBox(height: 12),
            Text(
              'No BP raw bytes on disk yet',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            const Text(
              'Sync history from the watch to populate the sidecar.\n'
              'Once at least one BP day is fetched, the 13 raw bytes '
              'per slot will appear here for byte-level inspection.',
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 12),
            const Text(
              'This screen exists because the 13-byte per-slot BP '
              'record layout is on PROTOCOL.md §8.5 as '
              '"needs live capture" — a future BLE capture session '
              'can use the dumps here to map the bytes to fields.',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 12),
            ),
          ],
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
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Text('Failed to open BP raw store: $message'),
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
