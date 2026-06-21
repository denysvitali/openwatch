import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:openwatch/core/ble/ble_transport.dart';
import 'package:openwatch/core/protocol/channel_a.dart';
import 'package:openwatch/core/protocol/channel_b.dart';
import 'package:openwatch/core/protocol/codec.dart';
import 'package:openwatch/core/protocol/opcodes.dart';
import 'package:openwatch/core/services/history_store.dart';
import 'package:openwatch/core/services/history_sync.dart';

class _StubTransport implements BleTransport {
  final inA = StreamController<Uint8List>.broadcast();
  final inB = StreamController<Uint8List>.broadcast();
  final sent = <Uint8List>[];
  final sentB = <Uint8List>[];

  @override
  Stream<Uint8List> get inboundA => inA.stream;

  @override
  Stream<Uint8List> get inboundB => inB.stream;

  @override
  Future<void> sendA(Uint8List frame) async {
    sent.add(frame);
  }

  @override
  Future<void> sendB(Uint8List framed) async {
    sentB.add(framed);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

Uint8List _channelAErrorFrame(int op, List<int> payload) {
  final f = Codec.buildChannelA(op, payload);
  f[0] = f[0] | 0x80;
  var sum = 0;
  for (var i = 0; i < 15; i++) {
    sum = (sum + f[i]) & 0xFF;
  }
  f[15] = sum;
  return f;
}

HistorySync _testSync(
  _StubTransport t,
  ChannelADispatcher d, {
  ChannelBParser? bParser,
}) => HistorySync(
  t,
  (_) {},
  dispatcher: d,
  bParser: bParser,
  drainDuration: const Duration(milliseconds: 50),
  postCommandDelay: Duration.zero,
  fragmentQuietWindow: const Duration(milliseconds: 50),
);

void main() {
  group('HistorySync', () {
    test('syncAll never sends 0x46 (it is a watch→phone notify-only opcode '
        'per PROTOCOL.md §4.6 — no host→watch request exists)', () async {
      final t = _StubTransport();
      final d = ChannelADispatcher(t);
      d.bind();
      final sync = _testSync(t, d);
      final future = sync.syncAll(daysBack: 1);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      // No 0x46 frame should ever appear on the wire — the previous
      // implementation sent a bare 0x46 and the firmware replied with
      // `0xC6 ERR 0xee`, forcing the `_distributionFailed` fallback.
      expect(
        t.sent.where((f) => f.isNotEmpty && f[0] == OpA.queryDataDistribution),
        isEmpty,
        reason: '0x46 is watch→phone notify-only; phone must never send it',
      );
      await future;
      sync.dispose();
      d.dispose();
    });

    test(
      'syncAll blindly polls the last N days without needing 0x46',
      () async {
        final t = _StubTransport();
        final d = ChannelADispatcher(t);
        d.bind();
        final sync = _testSync(t, d);
        final future = sync.syncAll(daysBack: 2);
        await Future<void>.delayed(const Duration(milliseconds: 20));
        await future;

        // Per-day HR reads fire for both day 0 (today) and day 1.
        expect(
          t.sent.where((f) => f.isNotEmpty && f[0] == OpA.readHeartRate),
          hasLength(2),
        );
        // Activity summary fires on Channel-B (clamped to dayOffset ≤ 2).
        expect(t.sentB.map(Codec.rxChannelBCmd), contains(OpB.activitySummary));
        final today = DateOnly.today();
        expect(sync.fetchedDays, containsAll([today, today.addDays(-1)]));
        sync.dispose();
        d.dispose();
      },
    );

    test(
      'unsolicited 0x46 push from the watch does NOT throw or break sync',
      () async {
        final t = _StubTransport();
        final d = ChannelADispatcher(t);
        d.bind();
        final sync = _testSync(t, d);
        final future = sync.syncAll(daysBack: 1);
        await Future<void>.delayed(const Duration(milliseconds: 20));
        // Some firmware builds push 0x46 unsolicited — the decoder
        // must NOT throw and the sync must complete cleanly.
        t.inA.add(
          Codec.buildChannelA(OpA.queryDataDistribution, [
            0x00,
            0x00,
            0x00,
            0x01,
          ]),
        );
        await future; // must complete without throwing
        expect(sync.lastSyncError, isNull);
        sync.dispose();
        d.dispose();
      },
    );

    test('readHeartRate 0x15 multi-pkt reassembly yields HrSamples', () async {
      final t = _StubTransport();
      final d = ChannelADispatcher(t);
      d.bind();
      final sync = _testSync(t, d);
      final syncFuture = sync.syncAll();
      // syncAll no longer sends 0x46 — it blind-polls day 0 directly.
      // Wait long enough for the per-day 0x15 poll + drain
      // (0x15 send at T+0 + 50ms drain at T+50).
      await Future<void>.delayed(const Duration(milliseconds: 150));
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
      await Future<void>.delayed(const Duration(milliseconds: 150));
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
        final sync = _testSync(t, d);
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
        // syncAll no longer sends 0x46 — it blind-polls day 0 directly.
        await Future<void>.delayed(const Duration(milliseconds: 20));
        await Future<void>.delayed(const Duration(milliseconds: 150));
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
        await Future<void>.delayed(const Duration(milliseconds: 1200));
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
        final sync = _testSync(t, d);
        final syncFuture = sync.syncAll();
        // syncAll no longer sends 0x46 — it blind-polls day 0 directly.
        // Wait for the per-day poll window.
        await Future<void>.delayed(const Duration(milliseconds: 150));
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
        await Future<void>.delayed(const Duration(milliseconds: 150));
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
        final f = _channelAErrorFrame(OpA.queryDataDistribution, [
          0xee,
          0x00,
          0x00,
          0x00,
        ]);
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
        final sync = _testSync(t, d);

        final producerHeader = [0xAA, 0xBB, 0xCC, 0xDD];
        final body = List<int>.generate(45, (i) => 0x10 + i);
        final all = [...producerHeader, ...body];
        // Pad the 49-byte payload up to 56 = 4 frames × 14 bytes so
        // the test assertions don't depend on trailing-zero behaviour.
        final padded = [...all, ...List<int>.filled(56 - all.length, 0xEE)];
        const chunkSize = 14;

        // Start listening first so no chunk is lost, then await the
        // single assembled record instead of polling a fixed delay.
        // This removes the timing flakiness that failed on slower CI
        // runners when the 250 ms quiet window hadn't quite fired.
        final expectation = expectLater(
          sync.pressureRecords,
          emits(
            isA<PressureRecord>()
                .having((r) => r.slotId, 'slotId', 0x00)
                .having((r) => r.header, 'header', producerHeader)
                .having((r) => r.body, 'body', [
                  ...body,
                  0xEE,
                  0xEE,
                  0xEE,
                  0xEE,
                  0xEE,
                  0xEE,
                  0xEE,
                ]),
          ),
        );

        // Header: pl[2] == 0x1E discriminator, pl[0] = slotId = 0
        t.inA.add(
          Codec.buildChannelA(OpA.pressureSetting, [
            0x00, // slotId
            0x05, // padding for header literal
            0x1e, // discriminator
          ]),
        );
        for (var i = 0; i < 4; i++) {
          t.inA.add(
            Codec.buildChannelA(
              OpA.pressureSetting,
              padded.sublist(i * chunkSize, (i + 1) * chunkSize),
            ),
          );
        }

        await expectation;
        sync.dispose();
        d.dispose();
      },
    );

    test('hrvSetting 0x39 header + 4 chunks assembles into one '
        'HrvRecord (regression for §3.21 two-phase wire format)', () async {
      final t = _StubTransport();
      final d = ChannelADispatcher(t);
      d.bind();
      final sync = _testSync(t, d);

      final producerHeader = [0x11, 0x22, 0x33, 0x44];
      final body = List<int>.generate(45, (i) => 0x40 + i);
      final all = [...producerHeader, ...body];
      final padded = [...all, ...List<int>.filled(56 - all.length, 0xEE)];
      const chunkSize = 14;

      final expectation = expectLater(
        sync.hrvRecords,
        emits(
          isA<HrvRecord>()
              .having((r) => r.slotId, 'slotId', 0x00)
              .having((r) => r.header, 'header', producerHeader)
              .having((r) => r.body, 'body', [
                ...body,
                0xEE,
                0xEE,
                0xEE,
                0xEE,
                0xEE,
                0xEE,
                0xEE,
              ]),
        ),
      );

      // Header: pl[2] == 0x1E discriminator, pl[0] = slotId = 0
      t.inA.add(Codec.buildChannelA(OpA.hrv, [0x00, 0x05, 0x1e]));
      for (var i = 0; i < 4; i++) {
        t.inA.add(
          Codec.buildChannelA(
            OpA.hrv,
            padded.sublist(i * chunkSize, (i + 1) * chunkSize),
          ),
        );
      }

      await expectation;
      sync.dispose();
      d.dispose();
    });

    test('pressureSetting 0x37 two back-to-back records emit two '
        'PressureRecords (regression for reassembler over multiple '
        'phases)', () async {
      final t = _StubTransport();
      final d = ChannelADispatcher(t);
      d.bind();
      final sync = _testSync(t, d);
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
      await Future<void>.delayed(const Duration(milliseconds: 250));
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
      await Future<void>.delayed(const Duration(milliseconds: 250));
      expect(records, hasLength(2));
      expect(records[0].slotId, 0x00);
      expect(records[1].slotId, 0x01);
      await sub.cancel();
      sync.dispose();
      d.dispose();
    });

    // ------------------------------------------------------------------
    // HS-5: ChannelBParser null → skip sleep/activity commands.
    // ------------------------------------------------------------------

    test(
      'syncAll skips sleep commands when ChannelBParser is null (HS-5)',
      () async {
        final t = _StubTransport();
        final d = ChannelADispatcher(t);
        d.bind();
        final sync = _testSync(t, d, bParser: null);
        final future = sync.syncAll(daysBack: 1);
        await Future<void>.delayed(const Duration(milliseconds: 20));
        await future;

        // No sleep or lunch commands should be sent on Channel B.
        expect(
          t.sentB.where(
            (f) => f.isNotEmpty && Codec.rxChannelBCmd(f) == OpB.sleepNew,
          ),
          isEmpty,
          reason: '0x27 sleepNew must not be sent when bParser is null',
        );
        expect(
          t.sentB.where(
            (f) => f.isNotEmpty && Codec.rxChannelBCmd(f) == OpB.sleepLunchNew,
          ),
          isEmpty,
          reason: '0x3e sleepLunchNew must not be sent when bParser is null',
        );

        // HR sync should still proceed normally.
        expect(
          t.sent.where((f) => f.isNotEmpty && f[0] == OpA.readHeartRate),
          isNotEmpty,
        );

        sync.dispose();
        d.dispose();
      },
    );

    test(
      'syncAll sends sleep commands when ChannelBParser is provided (HS-5)',
      () async {
        final t = _StubTransport();
        final d = ChannelADispatcher(t);
        final bParser = ChannelBParser(t);
        d.bind();
        final sync = _testSync(t, d, bParser: bParser);
        final future = sync.syncAll(daysBack: 1);
        await Future<void>.delayed(const Duration(milliseconds: 20));
        await future;

        // Sleep commands should be sent on Channel B.
        expect(
          t.sentB.where(
            (f) => f.isNotEmpty && Codec.rxChannelBCmd(f) == OpB.sleepNew,
          ),
          isNotEmpty,
          reason: '0x27 sleepNew must be sent when bParser is provided',
        );
        expect(
          t.sentB.where(
            (f) => f.isNotEmpty && Codec.rxChannelBCmd(f) == OpB.sleepLunchNew,
          ),
          isNotEmpty,
          reason: '0x3e sleepLunchNew must be sent when bParser is provided',
        );

        sync.dispose();
        d.dispose();
      },
    );

    // ------------------------------------------------------------------
    // HS-6: Step/calorie totals must not fallback to previous day on 0.
    // ------------------------------------------------------------------

    test(
      'activity summary 0x2a with all-zero body preserves nulls, '
      'not previous-day totals (HS-6)',
      () async {
        final t = _StubTransport();
        final d = ChannelADispatcher(t);
        final bParser = ChannelBParser(t);
        d.bind();
        final sync = _testSync(t, d, bParser: bParser);

        // Pre-seed yesterday with non-zero totals via a fake store so
        // _days is hydrated before syncAll runs.
        final yesterday = DateOnly.today().addDays(-1);
        final fakeStore = _FakeHistoryStore(seed: {
          yesterday: DailyHistory(
            day: yesterday,
            steps: 12345,
            energyKcal: 678,
            distanceMeters: 9876,
          ),
        });
        await sync.bindStore(fakeStore);

        final future = sync.syncAll(daysBack: 1);
        await Future<void>.delayed(const Duration(milliseconds: 20));

        // Build a Channel-B 0x2a payload with one entry:
        //   dayOffset = 0 (today)
        //   48-byte body all zeros → genuine "no activity yet today"
        final body = List<int>.filled(48, 0x00);
        final payload = Uint8List.fromList([0x00, ...body]);
        t.inB.add(Codec.buildChannelB(OpB.activitySummary, payload));

        await future;

        final today = DateOnly.today();
        final todayHistory = sync.dayOf(today);
        expect(todayHistory, isNotNull);
        // The all-zero body must produce null totals, NOT fallback to
        // yesterday's 12345/678/9876 values.
        expect(todayHistory!.steps, isNull, reason: 'steps must be null for all-zero body');
        expect(todayHistory.energyKcal, isNull, reason: 'calories must be null for all-zero body');
        expect(todayHistory.distanceMeters, isNull, reason: 'distance must be null for all-zero body');

        // Yesterday must remain untouched.
        final yestHistory = sync.dayOf(yesterday);
        expect(yestHistory!.steps, 12345);
        expect(yestHistory.energyKcal, 678);
        expect(yestHistory.distanceMeters, 9876);

        sync.dispose();
        d.dispose();
      },
    );

    test(
      'activity summary 0x2a with zero steps but non-zero calories '
      'keeps steps=0 (HS-6)',
      () async {
        final t = _StubTransport();
        final d = ChannelADispatcher(t);
        final bParser = ChannelBParser(t);
        d.bind();
        final sync = _testSync(t, d, bParser: bParser);
        final future = sync.syncAll(daysBack: 0);
        await Future<void>.delayed(const Duration(milliseconds: 20));

        // Build a Channel-B 0x2a payload:
        //   dayOffset = 0 (today)
        //   body: steps = 0 (u24 BE @ 0), calories = 1500 (u24 BE @ 6),
        //         distance = 2000 (u24 BE @ 9)
        final body = List<int>.filled(48, 0x00);
        body[0] = 0x00;
        body[1] = 0x00;
        body[2] = 0x00; // steps = 0
        body[6] = 0x00;
        body[7] = 0x05;
        body[8] = 0xDC; // calories = 1500 (0x05DC)
        body[9] = 0x00;
        body[10] = 0x07;
        body[11] = 0xD0; // distance = 2000 (0x07D0)
        final payload = Uint8List.fromList([0x00, ...body]);
        t.inB.add(Codec.buildChannelB(OpB.activitySummary, payload));

        await future;

        final today = DateOnly.today();
        final todayHistory = sync.dayOf(today);
        expect(todayHistory, isNotNull);
        // steps = 0 is genuine zero activity, not "no data".
        expect(todayHistory!.steps, 0, reason: 'steps must be 0, not null');
        expect(todayHistory.energyKcal, 1500);
        expect(todayHistory.distanceMeters, 2000);

        sync.dispose();
        d.dispose();
      },
    );

    test(
      'activity summary 0x2a absurd-clamped values become null '
      'instead of 0 (HS-6)',
      () async {
        final t = _StubTransport();
        final d = ChannelADispatcher(t);
        final bParser = ChannelBParser(t);
        d.bind();
        final sync = _testSync(t, d, bParser: bParser);
        final future = sync.syncAll(daysBack: 0);
        await Future<void>.delayed(const Duration(milliseconds: 20));

        // Build a Channel-B 0x2a payload with absurd values that exceed
        // the sanity clamps in _activityTotalsFromBody.
        final body = List<int>.filled(48, 0x00);
        // steps = 999_999 (> 200_000 clamp)
        body[0] = 0x0F;
        body[1] = 0x42;
        body[2] = 0x3F;
        // calories = 99_999 (> 20_000 clamp)
        body[6] = 0x01;
        body[7] = 0x86;
        body[8] = 0x9F;
        // distance = 999_999 (> 200_000 clamp)
        body[9] = 0x0F;
        body[10] = 0x42;
        body[11] = 0x3F;
        final payload = Uint8List.fromList([0x00, ...body]);
        t.inB.add(Codec.buildChannelB(OpB.activitySummary, payload));

        await future;

        final today = DateOnly.today();
        final todayHistory = sync.dayOf(today);
        expect(todayHistory, isNotNull);
        // Clamped values must be null so the UI can show "no data"
        // and _upsertTotals won't fall back to stale previous-day values.
        expect(todayHistory!.steps, isNull, reason: 'absurd steps must clamp to null');
        expect(todayHistory.energyKcal, isNull, reason: 'absurd calories must clamp to null');
        expect(todayHistory.distanceMeters, isNull, reason: 'absurd distance must clamp to null');

        sync.dispose();
        d.dispose();
      },
    );
  });
}

/// A minimal fake store that satisfies bindStore without touching disk.
class _FakeHistoryStore implements HistoryStore {
  _FakeHistoryStore({Map<DateOnly, DailyHistory>? seed}) : _seed = seed ?? {};

  final Map<DateOnly, DailyHistory> _seed;
  DateTime? _lastSyncedAt;
  DateOnly? _lastSyncDay;

  @override
  Future<void> writeDay(DailyHistory history, {DateTime? lastUpdated}) async {
    _seed[history.day] = history;
  }

  @override
  Future<DailyHistory> readDay(DateOnly day) async =>
      _seed[day] ?? DailyHistory(day: day);

  @override
  Future<List<DateOnly>> persistedDays() async => _seed.keys.toList();

  @override
  DateTime? get lastSyncedAt => _lastSyncedAt;

  @override
  Future<List<DailyHistory>> readRange(DateOnly from, DateOnly to) async {
    final days = from.daysTo(to);
    final out = <DailyHistory>[];
    for (var i = 0; i <= days; i++) {
      out.add(await readDay(from.addDays(i)));
    }
    return out;
  }

  @override
  DateOnly? get lastSyncedDay => _lastSyncDay;

  Future<void> setLastSyncDay(DateOnly day) async {
    _lastSyncDay = day;
  }

  @override
  Future<DailyHistory> mergeHr(DateOnly day, Iterable<HrSample> hrSamples) async {
    final current = _seed[day] ?? DailyHistory(day: day);
    final byTs = <int, HrSample>{
      for (final h in current.hr) h.timestamp.millisecondsSinceEpoch: h,
    };
    for (final h in hrSamples) {
      byTs[h.timestamp.millisecondsSinceEpoch] = h;
    }
    final merged = byTs.values.toList()
      ..sort((a, b) => a.timestamp.compareTo(b.timestamp));
    final updated = DailyHistory(
      day: day,
      hr: merged,
      sleep: current.sleep,
      steps: current.steps,
      energyKcal: current.energyKcal,
      distanceMeters: current.distanceMeters,
      lastUpdated: DateTime.now(),
    );
    _seed[day] = updated;
    return updated;
  }

  @override
  Future<DailyHistory> mergeSleep(
    DateOnly day,
    Iterable<SleepSegment> segments,
  ) async {
    final current = _seed[day] ?? DailyHistory(day: day);
    final byStart = <int, SleepSegment>{
      for (final s in current.sleep) s.start.millisecondsSinceEpoch: s,
    };
    for (final s in segments) {
      byStart[s.start.millisecondsSinceEpoch] = s;
    }
    final merged = byStart.values.toList()
      ..sort((a, b) => a.start.compareTo(b.start));
    final updated = DailyHistory(
      day: day,
      hr: current.hr,
      sleep: merged,
      steps: current.steps,
      energyKcal: current.energyKcal,
      distanceMeters: current.distanceMeters,
      lastUpdated: DateTime.now(),
    );
    _seed[day] = updated;
    return updated;
  }

  @override
  Future<DailyHistory> recordTotals(
    DateOnly day, {
    required int steps,
    required int energyKcal,
    required int distanceMeters,
  }) async {
    final current = _seed[day] ?? DailyHistory(day: day);
    final updated = DailyHistory(
      day: day,
      hr: current.hr,
      sleep: current.sleep,
      steps: steps,
      energyKcal: energyKcal,
      distanceMeters: distanceMeters,
      lastUpdated: DateTime.now(),
    );
    _seed[day] = updated;
    return updated;
  }

  @override
  Future<void> markSynced(DateTime at) async {
    _lastSyncedAt = at;
  }

  @override
  Future<void> clearAll() async {
    _seed.clear();
    _lastSyncedAt = null;
    _lastSyncDay = null;
  }

  @override
  Future<Map<String, dynamic>> exportAll() async => {
    'schemaVersion': 1,
    'exportedAt': DateTime.now().toUtc().toIso8601String(),
    'watermarks': {
      'lastSyncedAt': _lastSyncedAt?.toUtc().toIso8601String(),
      'lastSyncDay': _lastSyncDay?.iso,
    },
    'days': [
      for (final e in _seed.entries)
        {'date': e.key.iso, 'data': e.value.toJson()},
    ],
  };
}
