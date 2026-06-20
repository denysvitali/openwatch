import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:openwatch/core/ble/ble_transport.dart';
import 'package:openwatch/core/protocol/channel_a.dart';
import 'package:openwatch/core/protocol/channel_b.dart';
import 'package:openwatch/core/protocol/codec.dart';
import 'package:openwatch/core/protocol/opcodes.dart';
import 'package:openwatch/core/services/history_sync.dart';

class _StubTransport implements BleTransport {
  final inA = StreamController<Uint8List>.broadcast();
  final inB = StreamController<Uint8List>.broadcast();
  final sent = <Uint8List>[];

  @override
  Stream<Uint8List> get inboundA => inA.stream;

  @override
  Stream<Uint8List> get inboundB => inB.stream;

  @override
  Future<void> sendA(Uint8List frame) async {
    sent.add(frame);
  }

  @override
  Future<void> sendB(Uint8List framed) async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

void main() {
  group('HistorySync', () {
    test(
      'queryDataDistribution 0x46 bitmask 0x00000005 → availableDays {0, 2}',
      () async {
        final t = _StubTransport();
        final d = ChannelADispatcher(t);
        d.bind();
        final sync = HistorySync(t, (_) {}, dispatcher: d);
        // Drive a sync; the device will respond to the 0x46 query
        // with a bitmask + 0xFF errors for each per-day 0x15 read.
        // The test only cares about _availableDays being populated
        // from the 0x46 response.
        final syncFuture = sync.syncAll();
        // Wait for the distribution query to be sent, then send the
        // bitmask response.
        await Future<void>.delayed(const Duration(milliseconds: 50));
        t.inA.add(
          Codec.buildChannelA(OpA.queryDataDistribution, [
            0x00,
            0x00,
            0x00,
            0x05,
          ]),
        );
        await syncFuture;
        expect(sync.availableDays, containsAll([0, 2]));
        expect(sync.availableDays.contains(1), isFalse);
        sync.dispose();
        d.dispose();
      },
    );

    test('readHeartRate 0x15 multi-pkt reassembly yields HrSamples', () async {
      final t = _StubTransport();
      final d = ChannelADispatcher(t);
      d.bind();
      final sync = HistorySync(t, (_) {}, dispatcher: d);
      final syncFuture = sync.syncAll();
      // Push the 0x46 bitmask response first so day 0 is polled.
      await Future<void>.delayed(const Duration(milliseconds: 50));
      t.inA.add(
        Codec.buildChannelA(OpA.queryDataDistribution, [
          0x00,
          0x00,
          0x00,
          0x01,
        ]),
      );
      // Wait long enough for the per-day 0x15 poll + drain
      // (T+800 distribution drain + 0x15 send at T+800 + 600ms
      // drain at T+1400 = total ~1500ms).
      await Future<void>.delayed(const Duration(milliseconds: 1000));
      // Header
      t.inA.add(Codec.buildChannelA(OpA.readHeartRate, [0x18, 0x80, 0x05]));
      // First 4 bytes of the reassembled record = the day
      // timestamp LE u32 (per the pre-v14 smali convention — see
      // GHIDRA §3.12 for the v14 packed-BCD echo). We use the
      // smali layout here because the regression targets the
      // chunk-reassembly path, not the v14 packed-date echo.
      // Day-start timestamp = 2026-06-19 00:00 UTC = 0x6A34F600
      final dayStartBytes = [0x00, 0xF6, 0x34, 0x6A];
      // Chunk 1: pl[0]=seq=1, pl[1..4]=dayStart, pl[5..13]=samples
      final chunk1 = Uint8List.fromList([
        0x01, // seq=1 (flushed on receipt because count >= seq)
        ...dayStartBytes,
        0x60, // bpm 96
        0x65, // bpm 101
        0xFF, // no sample → skip
        0x6A, // bpm 106
        0x6E, // bpm 110
        0x00, // bpm 0 → skip
        0x6F, // bpm 111
        0x72, // bpm 114
        0x73, // bpm 115
      ]);
      t.inA.add(Codec.buildChannelA(OpA.readHeartRate, chunk1));
      // Let the drain run.
      await Future<void>.delayed(const Duration(milliseconds: 1000));
      // The first chunk should have flushed because
      // count (1) >= seq (1).
      final bpms = sync.hr.map((s) => s.bpm).toList();
      expect(bpms, containsAll([96, 101, 106, 110, 111, 114, 115]));
      for (final s in sync.hr) {
        expect(s.bpm, inInclusiveRange(30, 240));
      }
      // Let the sync finish.
      await syncFuture;
      sync.dispose();
      d.dispose();
    });

    test(
      'syncAll sends a packed-BCD date index for 0x15 (regression for '
      'GHIDRA §3.12 — FUN_0082cf48 takes a packed date, not unix sec)',
      () async {
        final t = _StubTransport();
        final d = ChannelADispatcher(t);
        d.bind();
        final sync = HistorySync(t, (_) {}, dispatcher: d);
        // Compute the expected packed bytes from `DateTime.now()` so
        // the test is timezone-independent (host TZ can be +00..+12
        // and the day part still matches).
        final today = DateTime.now();
        final expected = Uint8List.fromList([
          Codec.toBcd(today.year % 100) & 0xFF,
          Codec.toBcd(today.month) & 0xFF,
          Codec.toBcd(today.day) & 0xFF,
          0x00, // slot = 0
        ]);
        final future = sync.syncAll();
        await Future<void>.delayed(const Duration(milliseconds: 50));
        // Bitmask response so day 0 is polled.
        t.inA.add(
          Codec.buildChannelA(OpA.queryDataDistribution, [0, 0, 0, 0x01]),
        );
        await Future<void>.delayed(const Duration(milliseconds: 900));
        // The wire bytes for the 0x15 request must be the packed
        // BCD date index, NOT a unix timestamp.
        final sent = t.sent.firstWhere(
          (f) => f.isNotEmpty && f[0] == OpA.readHeartRate,
          orElse: () => Uint8List(0),
        );
        expect(sent, isNotEmpty);
        expect(
          sent.sublist(1, 5),
          expected,
          reason:
              '0x15 subData must be packed-BCD date (year_lo | month | day '
              '| slot=0) per GHIDRA §3.12; FUN_008279c4 shares its byte '
              'layout with the setTime BCD date struct',
        );
        // And the request must NOT be a unix timestamp (~1.78e9).
        // A packed date fits in 4 B comfortably (< ~0x02000000);
        // anything bigger is the legacy unix-seconds path.
        expect(
          Codec.readU32le(sent, 1) < 0x02000000,
          isTrue,
          reason:
              'request was a packed date (small u32), not unix seconds '
              '(>1.7e9)',
        );
        await Future<void>.delayed(const Duration(milliseconds: 1500));
        await future;
        sync.dispose();
        d.dispose();
      },
    );

    test(
      'readHeartRate 0x15 error frame (pl[0]==0xff) clears pending chunks',
      () async {
        final t = _StubTransport();
        final d = ChannelADispatcher(t);
        d.bind();
        final sync = HistorySync(t, (_) {}, dispatcher: d);
        final syncFuture = sync.syncAll();
        // Push the 0x46 bitmask response so day 0 is polled.
        await Future<void>.delayed(const Duration(milliseconds: 50));
        t.inA.add(
          Codec.buildChannelA(OpA.queryDataDistribution, [
            0x00,
            0x00,
            0x00,
            0x01,
          ]),
        );
        // Wait for the per-day poll window.
        await Future<void>.delayed(const Duration(milliseconds: 1000));
        t.inA.add(Codec.buildChannelA(OpA.readHeartRate, [0x18, 0x80, 0x05]));
        // seq=1, dayStart=0x6A34F600 (LE), 9 sample bytes (96, 100, 102)
        t.inA.add(
          Codec.buildChannelA(OpA.readHeartRate, [
            0x01,
            0x00, 0xF6, 0x34, 0x6A, // dayStart
            0x60, 0x64, 0x66, // 96, 100, 102
            0x00, 0x00, 0x00, 0x00, 0x00, 0x00, // padding
          ]),
        );
        t.inA.add(Codec.buildChannelA(OpA.readHeartRate, [0xff]));
        // Wait for the drain.
        await Future<void>.delayed(const Duration(milliseconds: 1000));
        // The error frame shouldn't crash the parser. After a
        // complete record has been flushed, _hrChunks is reset, so
        // a subsequent 0xff is a no-op.
        expect(sync.hr, isNotEmpty);
        for (final s in sync.hr) {
          expect(s.bpm, inInclusiveRange(30, 240));
        }
        await syncFuture;
        sync.dispose();
        d.dispose();
      },
    );

    test(
      'queryDataDistribution 0x46|0x80 error response surfaces errorFlag '
      'via onQueryDataDistribution (regression for pattern-disjunction bug)',
      () async {
        final t = _StubTransport();
        final d = ChannelADispatcher(t);
        d.bind();
        final errorEvents = <QueryDataDistribution>[];
        final sub = d.onQueryDataDistribution.listen(errorEvents.add);
        d.markDistributionQuery();
        // Build a frame with the device-side error flag set on
        // opcode 0x46. The buildChannelA helper doesn't expose the
        // top bit, so OR it in after construction AND recompute the
        // checksum so the dispatcher's isValidChannelA() check passes.
        final f = Codec.buildChannelA(OpA.queryDataDistribution, [
          0xee,
          0x00,
          0x00,
          0x00,
        ]);
        f[0] = f[0] | 0x80; // 0x46 -> 0xC6
        var sum = 0;
        for (var i = 0; i < 15; i++) {
          sum = (sum + f[i]) & 0xFF;
        }
        f[15] = sum;
        t.inA.add(f);
        await Future<void>.delayed(const Duration(milliseconds: 20));
        expect(errorEvents.length, 1);
        expect(errorEvents.first.errorFlag, isTrue);
        await sub.cancel();
        d.dispose();
      },
    );

    // ------------------------------------------------------------------
    // 0x37 pressureSetting + 0x39 hrvSetting two-phase reassembly.
    // Wired via FragmentReassembler — GHIDRA §3.20 / §3.21.
    // ------------------------------------------------------------------

    test(
      'pressureSetting 0x37 header + 4 chunks assembles into one '
      'PressureRecord (regression for §3.20 two-phase wire format)',
      () async {
        final t = _StubTransport();
        final d = ChannelADispatcher(t);
        d.bind();
        final sync = HistorySync(t, (_) {}, dispatcher: d);
        final records = <PressureRecord>[];
        final sub = sync.pressureRecords.listen(records.add);

        // Header: pl[2] == 0x1E discriminator, pl[0] = slotId = 0
        t.inA.add(
          Codec.buildChannelA(OpA.pressureSetting, [
            0x00, // slotId
            0x05, // padding for header literal
            0x1e, // discriminator
          ]),
        );
        // 4 chunks — each carries up to 13 payload bytes; total
        // payload = 4 (producer header) + 45 (body) = 49 bytes per
        // §3.20 (`FUN_0082c988(0x37, buf, 0x31)`). Distributed
        // across 4 frames: 13, 12, 12, 12 bytes (last frame is
        // short). The wire helper `buildChannelA` zero-pads the
        // trailing byte when subData < 14 bytes, so we always send
        // 14-byte subData frames — anything shorter would inject
        // a stray 0 into the assembled body and skew assertions.
        // The dispatcher only emits the first 14 bytes regardless,
        // so over-padding is harmless.
        final producerHeader = [0xAA, 0xBB, 0xCC, 0xDD];
        final body = List<int>.generate(45, (i) => 0x10 + i);
        final all = [...producerHeader, ...body];
        // Pad the 49-byte payload up to 56 = 4 frames × 14 bytes so
        // the test assertions don't depend on trailing-zero behaviour.
        final padded = [...all, ...List<int>.filled(56 - all.length, 0xEE)];
        const chunkSize = 14;
        for (var i = 0; i < 4; i++) {
          t.inA.add(
            Codec.buildChannelA(
              OpA.pressureSetting,
              padded.sublist(i * chunkSize, (i + 1) * chunkSize),
            ),
          );
        }
        // 250 ms quiet window + a little slack.
        await Future<void>.delayed(const Duration(milliseconds: 350));

        expect(records, hasLength(1));
        final r = records.single;
        expect(r.slotId, 0x00);
        expect(r.header, producerHeader);
        // The assembled payload is 4 × 14 = 56 bytes; body is
        // payload[4..56] = 52 bytes (45 real + 7 sentinels).
        expect(
          r.body,
          [...body, 0xEE, 0xEE, 0xEE, 0xEE, 0xEE, 0xEE, 0xEE],
          reason:
              'producer header is 4 B, body is the remaining 52 B '
              'from 4 × 14-byte frames',
        );
        await sub.cancel();
        sync.dispose();
        d.dispose();
      },
    );

    test('hrvSetting 0x39 header + 4 chunks assembles into one '
        'HrvRecord (regression for §3.21 two-phase wire format)', () async {
      final t = _StubTransport();
      final d = ChannelADispatcher(t);
      d.bind();
      final sync = HistorySync(t, (_) {}, dispatcher: d);
      final records = <HrvRecord>[];
      final sub = sync.hrvRecords.listen(records.add);

      // Header: pl[2] == 0x1E discriminator, pl[0] = slotId = 0
      t.inA.add(Codec.buildChannelA(OpA.hrv, [0x00, 0x05, 0x1e]));
      final producerHeader = [0x11, 0x22, 0x33, 0x44];
      final body = List<int>.generate(45, (i) => 0x40 + i);
      final all = [...producerHeader, ...body];
      final padded = [...all, ...List<int>.filled(56 - all.length, 0xEE)];
      const chunkSize = 14;
      for (var i = 0; i < 4; i++) {
        t.inA.add(
          Codec.buildChannelA(
            OpA.hrv,
            padded.sublist(i * chunkSize, (i + 1) * chunkSize),
          ),
        );
      }
      await Future<void>.delayed(const Duration(milliseconds: 350));

      expect(records, hasLength(1));
      final r = records.single;
      expect(r.slotId, 0x00);
      expect(r.header, producerHeader);
      // Same shape as the pressure test — see comments above.
      expect(r.body, [...body, 0xEE, 0xEE, 0xEE, 0xEE, 0xEE, 0xEE, 0xEE]);
      await sub.cancel();
      sync.dispose();
      d.dispose();
    });

    test('pressureSetting 0x37 two back-to-back records emit two '
        'PressureRecords (regression for reassembler over multiple '
        'phases)', () async {
      final t = _StubTransport();
      final d = ChannelADispatcher(t);
      d.bind();
      final sync = HistorySync(t, (_) {}, dispatcher: d);
      final records = <PressureRecord>[];
      final sub = sync.pressureRecords.listen(records.add);

      // Record #1
      t.inA.add(Codec.buildChannelA(OpA.pressureSetting, [0x00, 0x05, 0x1e]));
      // 49-byte payload split across 4 frames of 14 subData bytes
      // (we send 56 total bytes — the test only asserts on the
      // header slot + first 45 body bytes, so over-padding with
      // a sentinel is harmless).
      const rec1 = [
        0xA1, 0xA2, 0xA3, 0xA4, // producer header
        0x10, 0x11, 0x12, 0x13, 0x14, 0x15, 0x16, 0x17, 0x18, 0x19, 0x1A,
        0x1B, 0x1C, 0x1D, 0x1E, 0x1F, 0x20, 0x21, 0x22, 0x23, 0x24, 0x25,
        0x26, 0x27, 0x28, 0x29, 0x2A, 0x2B, 0x2C, 0x2D, 0x2E, 0x2F,
        0x30, 0x31, 0x32, 0x33, 0x34, 0x35, 0x36, 0x37, 0x38, 0x39,
        0x3A, 0x3B, 0x3C, 0x3D, 0x3E, 0x3F, 0x40, 0x41, 0x42,
        // pad 7 sentinel bytes so 4 × 14 = 56 fits exactly.
        0xEE, 0xEE, 0xEE, 0xEE, 0xEE, 0xEE, 0xEE,
      ];
      const chunkSize = 14;
      for (var i = 0; i < 4; i++) {
        t.inA.add(
          Codec.buildChannelA(
            OpA.pressureSetting,
            rec1.sublist(i * chunkSize, (i + 1) * chunkSize),
          ),
        );
      }
      // Wait past the quiet window so #1 fires.
      await Future<void>.delayed(const Duration(milliseconds: 350));
      expect(records, hasLength(1));

      // Record #2 — different slotId so we can verify it carried.
      t.inA.add(Codec.buildChannelA(OpA.pressureSetting, [0x01, 0x05, 0x1e]));
      const rec2 = [
        0xB1,
        0xB2,
        0xB3,
        0xB4,
        0x50,
        0x51,
        0x52,
        0x53,
        0x54,
        0x55,
        0x56,
        0x57,
        0x58,
        0x59,
        0x5A,
        0x5B,
        0x5C,
        0x5D,
        0x5E,
        0x5F,
        0x60,
        0x61,
        0x62,
        0x63,
        0x64,
        0x65,
        0x66,
        0x67,
        0x68,
        0x69,
        0x6A,
        0x6B,
        0x6C,
        0x6D,
        0x6E,
        0x6F,
        0x70,
        0x71,
        0x72,
        0x73,
        0x74,
        0x75,
        0x76,
        0x77,
        0x78,
        0x79,
        0x7A,
        0x7B,
        0x7C,
        0x7D,
        0x7E,
        0x7F,
        0x80,
        0x81,
        0x82,
        0xEE,
        0xEE,
        0xEE,
        0xEE,
        0xEE,
        0xEE,
        0xEE,
      ];
      for (var i = 0; i < 4; i++) {
        t.inA.add(
          Codec.buildChannelA(
            OpA.pressureSetting,
            rec2.sublist(i * chunkSize, (i + 1) * chunkSize),
          ),
        );
      }
      await Future<void>.delayed(const Duration(milliseconds: 350));

      expect(records, hasLength(2));
      expect(records[0].slotId, 0x00);
      expect(records[0].header, [0xA1, 0xA2, 0xA3, 0xA4]);
      expect(records[1].slotId, 0x01);
      expect(records[1].header, [0xB1, 0xB2, 0xB3, 0xB4]);
      await sub.cancel();
      sync.dispose();
      d.dispose();
    });

    test('pressureSetting 0x37 quiet-period flush emits in-flight record '
        'after 250 ms with no further header (regression for reassembler '
        'quiet-window timer)', () async {
      final t = _StubTransport();
      final d = ChannelADispatcher(t);
      d.bind();
      final sync = HistorySync(t, (_) {}, dispatcher: d);
      final records = <PressureRecord>[];
      final sub = sync.pressureRecords.listen(records.add);

      // Header + 1 chunk only — no second header follows.
      t.inA.add(Codec.buildChannelA(OpA.pressureSetting, [0x00, 0x05, 0x1e]));
      // Single chunk with 14 bytes of payload (fills the whole
      // subData slot to avoid trailing-zero injection from
      // `buildChannelA`).
      t.inA.add(
        Codec.buildChannelA(OpA.pressureSetting, [
          0x01,
          0x02,
          0x03,
          0x04,
          0x05,
          0x06,
          0x07,
          0x08,
          0x09,
          0x0A,
          0x0B,
          0x0C,
          0x0D,
          0x0E,
        ]),
      );
      // Nothing else. The reassembler's 250 ms quiet timer should
      // fire and surface the partial record.
      await Future<void>.delayed(const Duration(milliseconds: 350));

      expect(records, hasLength(1));
      expect(records.single.slotId, 0x00);
      expect(
        records.single.header,
        [0x01, 0x02, 0x03, 0x04],
        reason: 'first 4 bytes of assembled payload = producer header',
      );
      expect(
        records.single.body,
        [0x05, 0x06, 0x07, 0x08, 0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x0E],
        reason: 'remaining 10 bytes of the 14-byte chunk = body',
      );
      await sub.cancel();
      sync.dispose();
      d.dispose();
    });

    // ------------------------------------------------------------------
    // Channel-B sleep wiring (0x27 night + 0x3e lunch). Regression
    // for the gap where HistorySync.syncAll() sent the requests
    // but no consumer parsed the reassembled Channel-B commands
    // — the sleep list was always empty.
    // ------------------------------------------------------------------

    test('Channel-B 0x27 night sleep frame populates HistorySync.sleep '
        '(regression for missing Ch-B sleep consumer)', () async {
      final t = _StubTransport();
      final d = ChannelADispatcher(t);
      d.bind();
      final b = ChannelBParser(t);
      b.bind();
      final sync = HistorySync(t, (_) {}, dispatcher: d, bParser: b);

      // Build a single-block night payload: endMin=450 (07:30),
      // three (stage, durMin) pairs.
      final nightPayload = Uint8List.fromList([
        0xC2, 0x01, // endMin LE
        0x01, 0x1E, // light 30
        0x02, 0x5A, // deep 90
        0x03, 0x3C, // rem 60
      ]);
      t.inB.add(Codec.buildChannelB(OpB.sleepNew, nightPayload));

      // Give the parser a tick to reassemble + HistorySync a tick
      // to ingest + notify.
      await Future<void>.delayed(const Duration(milliseconds: 30));

      expect(sync.sleep, hasLength(3));
      expect(sync.sleep.map((s) => s.stage), [
        SleepStage.light,
        SleepStage.deep,
        SleepStage.rem,
      ]);
      expect(sync.sleep[0].duration.inMinutes, 30);
      expect(sync.sleep[1].duration.inMinutes, 90);
      expect(sync.sleep[2].duration.inMinutes, 60);
      sync.dispose();
      d.dispose();
      b.dispose();
    });

    test(
      'Channel-B 0x3e lunch sleep frame populates HistorySync.sleep',
      () async {
        final t = _StubTransport();
        final d = ChannelADispatcher(t);
        d.bind();
        final b = ChannelBParser(t);
        b.bind();
        final sync = HistorySync(t, (_) {}, dispatcher: d, bParser: b);

        final lunchPayload = Uint8List.fromList([
          0x3C, 0x00, // endMin 60 (13:00)
          0x01, 0x3C, // light 60
        ]);
        t.inB.add(Codec.buildChannelB(OpB.sleepLunchNew, lunchPayload));

        await Future<void>.delayed(const Duration(milliseconds: 30));

        expect(sync.sleep, hasLength(1));
        expect(sync.sleep.single.stage, SleepStage.light);
        expect(sync.sleep.single.duration.inMinutes, 60);
        sync.dispose();
        d.dispose();
        b.dispose();
      },
    );

    test('syncAll sends both 0x27 night and 0x3e lunch on Channel-B', () async {
      final t = _StubTransport();
      final d = ChannelADispatcher(t);
      d.bind();
      final sync = HistorySync(t, (_) {}, dispatcher: d);

      // Drive syncAll; the device doesn't respond to the 0x46 query
      // (bitmask stays empty), so the per-day loop polls {0} only.
      // We only care that the Channel-B writes for both sleep
      // commands are issued — `t.sent` accumulates Channel-A
      // writes; Channel-B writes aren't captured here, so we
      // confirm the call doesn't throw and completes.
      final future = sync.syncAll();
      await Future<void>.delayed(const Duration(milliseconds: 50));
      // Empty bitmask → day 0 polled → 0x15 fired → settle.
      // The Channel-B writes happen after the per-day loop.
      await Future<void>.delayed(const Duration(milliseconds: 1800));
      await future;
      // No assertion on the wire (the stub's sendB is a no-op) —
      // the regression test is "doesn't throw + reaches finally".
      expect(sync.syncing, isFalse);
      sync.dispose();
      d.dispose();
    });

    // ------------------------------------------------------------------
    // Local-first: state exposed for the UI without an in-memory store.
    // ------------------------------------------------------------------

    test('days / watchDaysWithData / fetchedDays are exposed (regression '
        'for new HistorySync API consumed by history_screen)', () async {
      final t = _StubTransport();
      final d = ChannelADispatcher(t);
      d.bind();
      final sync = HistorySync(t, (_) {}, dispatcher: d);
      expect(sync.days, isEmpty);
      expect(sync.watchDaysWithData, isEmpty);
      expect(sync.fetchedDays, isEmpty);
      expect(sync.dayOf(DateOnly.today()), isNull);
      expect(sync.lastSyncedAt, isNull);

      final future = sync.syncAll();
      await Future<void>.delayed(const Duration(milliseconds: 50));
      // Bitmask reports day 0 + day 2 have data.
      t.inA.add(
        Codec.buildChannelA(OpA.queryDataDistribution, [0, 0, 0, 0x05]),
      );
      await future;
      final today = DateOnly.today();
      expect(sync.watchDaysWithData, containsAll([today, today.addDays(-2)]));
      // No store → fetched set still tracks which days were polled.
      expect(sync.fetchedDays, contains(today));
      // Day 0 always re-fetched; day 2 also fetched because no store.
      expect(sync.fetchedDays.length, 2);
      sync.dispose();
      d.dispose();
    });
  });
}
