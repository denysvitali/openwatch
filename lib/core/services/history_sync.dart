import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';

import '../ble/ble_transport.dart';
import '../protocol/channel_a.dart';
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
  HistorySync(this.transport, this.onTotals, {ChannelADispatcher? dispatcher})
    : _dispatcher = dispatcher {
    _inbound = transport.inboundA.listen(_collectRx);
  }
  final BleTransport transport;
  final ChannelADispatcher? _dispatcher;
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
    _hrChunks.clear();
    notifyListeners();
    AppLog.instance.info('history', 'Sync start (last $daysBack days)');

    try {
      // Distribution bitmask
      _dispatcher?.markDistributionQuery();
      await transport.sendA(Commands.queryDataDistribution());
      await Future<void>.delayed(const Duration(milliseconds: 800));

      // HR history for each day the device reports as having data.
      // If the distribution query errored (e.g. the watch doesn't
      // expose HR at all), _availableDays stays empty and we fall
      // back to polling today only so the user still gets feedback.
      final now = DateTime.now();
      final wantsDays = _availableDays.isEmpty
          ? {0}
          : _availableDays.where((d) => d < daysBack).toSet();
      for (final d in wantsDays) {
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
        // 4-byte BE bitmask: bit d = day d has data (PROTOCOL.md §4.6).
        // The high 4 bytes of the 14-byte payload are reserved; the
        // watch normally only fills the first 4.
        if (pl.length >= 4) {
          final v = Codec.readU32be(pl, 0);
          for (var d = 0; d < 32; d++) {
            if ((v & (1 << d)) != 0) _availableDays.add(d);
          }
        }
      case OpA.readHeartRate:
        // 0x15 multi-pkt reassembly per FUN_0082cf48 (GHIDRA §3.12).
        //   * pl[0] == 0x18 → header — fire _hrHeader
        //   * pl[0] == 0xFF → error (no data at this index)
        //   * pl[0] ∈ 1..23 → chunk with seq byte, 13 payload bytes
        //     follow (samples at 5-min intervals)
        if (pl.isEmpty) return;
        final tag = pl[0];
        if (tag == 0x18) {
          _hrChunks.clear();
        } else if (tag == 0xff) {
          _hrChunks.clear();
        } else if (tag >= 1 && tag <= 23) {
          if (pl.length >= 1 + 13) {
            _hrChunks.add(Uint8List.fromList(pl.sublist(1, 1 + 13)));
            if (_hrChunks.length >= tag) {
              _flushHrChunks();
            }
          }
        }
    }
  }

  final List<Uint8List> _hrChunks = [];

  void _flushHrChunks() {
    // Stitch the 13-byte chunks into a flat record, then walk 5-min
    // BPM slots. 288 slots * 1 byte (BPM) = 288 bytes; the first
    // 4 bytes of the assembled record are the day timestamp (LE
    // u32) and the rest is the 5-min sample series. 0xFF = no
    // sample.
    final buf = BytesBuilder();
    for (final c in _hrChunks) {
      buf.add(c);
    }
    final rec = buf.toBytes();
    if (rec.length < 5) {
      _hrChunks.clear();
      return;
    }
    final dayStart = DateTime.fromMillisecondsSinceEpoch(
      Codec.readU32le(rec, 0) * 1000,
    );
    for (var i = 4; i < rec.length; i++) {
      final bpm = rec[i];
      if (bpm == 0xff || bpm == 0x00) continue;
      if (bpm < 30 || bpm > 240) continue;
      _hr.add(HrSample(dayStart.add(Duration(minutes: (i - 4) * 5)), bpm));
    }
    _hrChunks.clear();
  }

  @override
  void dispose() {
    _inbound?.cancel();
    super.dispose();
  }
}
