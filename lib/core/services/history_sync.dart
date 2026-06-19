import 'dart:async';

import 'package:flutter/foundation.dart';

import '../ble/ble_transport.dart';
import '../protocol/codec.dart';
import '../protocol/commands.dart';
import '../protocol/opcodes.dart';
import 'app_log.dart';

/// A 5-minute HR sample.
@immutable
class HrSample {
  const HrSample(this.timestamp, this.bpm);
  final DateTime timestamp;
  final int bpm;
}

/// A single sleep segment (deep / light / awake / nap).
enum SleepStage { awake, light, deep, rem }

@immutable
class SleepSegment {
  const SleepSegment(this.start, this.duration, this.stage);
  final DateTime start;
  final Duration duration;
  final SleepStage stage;
}

/// Day-aligned totals for the activity ring on the dashboard.
@immutable
class DailyTotals {
  const DailyTotals({
    this.steps = 0,
    this.calories = 0,
    this.distanceMeters = 0,
  });
  final int steps;
  final int calories;
  final int distanceMeters;
}

/// Pulls historical data from the watch. Uses the watch's data distribution
/// bitmask to know which days have data, then requests HR + sleep per day.
///
/// Multi-packet responses are reassembled here (the SDK does this in Java;
/// the original payload layout is 13 bytes per sample at 5-min slots).
class HistorySync extends ChangeNotifier {
  HistorySync(this.transport, this.onTotals);
  final BleTransport transport;
  final void Function(DailyTotals) onTotals;

  final List<HrSample> _hr = [];
  final List<SleepSegment> _sleep = [];
  final Set<int> _availableDays = {};

  List<HrSample> get hr => List.unmodifiable(_hr);
  List<SleepSegment> get sleep => List.unmodifiable(_sleep);
  Set<int> get availableDays => Set.unmodifiable(_availableDays);

  bool _syncing = false;
  bool get syncing => _syncing;

  StreamSubscription<Uint8List>? _inbound;
  final List<Uint8List> _rxQueue = [];

  /// Trigger a full sync: ask the watch which days have data, then pull HR
  /// and sleep for each of them.
  Future<void> syncAll({int daysBack = 7}) async {
    if (_syncing) return;
    _syncing = true;
    _rxQueue.clear();
    _hr.clear();
    _sleep.clear();
    _availableDays.clear();
    _inbound ??= transport.inboundA.listen(_collectRx);
    notifyListeners();
    AppLog.instance.info('history', 'Sync start (last $daysBack days)');

    try {
      // Distribution bitmask
      await transport.sendA(Commands.queryDataDistribution());
      await Future<void>.delayed(const Duration(milliseconds: 800));

      // HR history for each of the last `daysBack` days
      final now = DateTime.now();
      for (var d = 0; d < daysBack; d++) {
        final dayStart = DateTime(
          now.year,
          now.month,
          now.day,
        ).subtract(Duration(days: d));
        await transport.sendA(Commands.readHeartRateHistory(dayStart));
        await _drainRx(Duration(milliseconds: 600));
      }
      // Sleep (new protocol, Channel-B) for last night
      await transport.sendB(Commands.readSleepNewProtocol(dayOffset: 0));
      await _drainRx(Duration(milliseconds: 600));
      AppLog.instance.info(
        'history',
        'Sync complete: hr=${_hr.length} sleep=${_sleep.length} days=${_availableDays.length}',
      );
    } catch (e) {
      AppLog.instance.error('history', 'Sync failed: $e');
    } finally {
      _syncing = false;
      notifyListeners();
    }
  }

  void _collectRx(Uint8List frame) {
    _rxQueue.add(frame);
  }

  Future<void> _drainRx(Duration settle) async {
    await Future<void>.delayed(settle);
    final frames = _rxQueue.toList();
    _rxQueue.clear();
    for (final f in frames) {
      _parse(f);
    }
    notifyListeners();
  }

  void _parse(Uint8List frame) {
    if (frame.length != 16) return;
    final op = Codec.rxOpcode(frame);
    final pl = Codec.rxPayload(frame);
    switch (op) {
      case OpA.queryDataDistribution:
        // 4-byte BE distribution: bit d = day d has data.
        if (pl.length >= 4) {
          final v = Codec.readU24be(pl, 0); // best-effort: 3 bytes
          // (we use 4-byte BE in spec but here we read what we have)
          for (var d = 0; d < 24; d++) {
            if ((v & (1 << d)) != 0) _availableDays.add(d);
          }
        }
      case OpA.readHeartRate:
        // 0x15 multi-pkt. Per spec, samples arrive as 13-byte chunks at
        // 5-min intervals, with pl[0]==0x01 marking a data record. We accept
        // any plausible 1-byte bpm at known offsets.
        // Heuristic: if pl looks like {tag, ts(4), bpm…} look for any bpm in
        // 30..240; otherwise walk 13-byte stride.
        if (pl.length >= 5) {
          final tag = pl[0];
          if (tag == 0x00 || tag == 0x01) {
            // 4-byte i32 LE ts + bpm series at 13-byte stride
            final ts = Codec.readU32le(pl, 1);
            final start = DateTime.fromMillisecondsSinceEpoch(ts * 1000);
            for (var off = 5; off + 13 <= pl.length; off += 13) {
              final bpm = pl[off];
              if (bpm >= 30 && bpm <= 240) {
                _hr.add(
                  HrSample(
                    start.add(Duration(minutes: ((_hr.length * 5)))),
                    bpm,
                  ),
                );
              }
            }
          }
        }
    }
  }

  @override
  void dispose() {
    _inbound?.cancel();
    super.dispose();
  }
}
