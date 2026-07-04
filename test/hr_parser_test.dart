import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:openwatch/core/protocol/channel_a.dart';
import 'package:openwatch/core/protocol/codec.dart';
import 'package:openwatch/core/protocol/hr_parser.dart';
import 'package:openwatch/core/protocol/opcodes.dart';
import 'package:openwatch/core/services/history_sync.dart';

import 'support/fake_ble_transport.dart';

void main() {
  group('isPlausibleBpm', () {
    test('accepts the inclusive 30..240 range', () {
      expect(HrParser.isPlausibleBpm(30), isTrue);
      expect(HrParser.isPlausibleBpm(60), isTrue);
      expect(HrParser.isPlausibleBpm(120), isTrue);
      expect(HrParser.isPlausibleBpm(240), isTrue);
    });

    test('rejects values below 30 and above 240', () {
      expect(HrParser.isPlausibleBpm(0), isFalse);
      expect(HrParser.isPlausibleBpm(29), isFalse);
      expect(HrParser.isPlausibleBpm(241), isFalse);
      expect(HrParser.isPlausibleBpm(255), isFalse);
    });

    test('handles high-bit bytes (0x80..0xFF) via mask', () {
      // The mask in the parser is defensive — it covers any code path that
      // hands a signed int (or a List<int> with negative entries) to the
      // parser. On the Dart VM, Uint8List reads are already unsigned, but
      // we still want the parser to behave correctly on bytes where the
      // high bit is set (legitimate bpm 128..240).
      final pl = Uint8List.fromList([0xC8]); // bpm 200
      expect(HrParser.parseRealtime(pl), 200);
      expect(HrParser.parseRealtime(Uint8List.fromList([0xF0])), 240);
    });
  });

  group('parseRealtime (0x1e)', () {
    test('returns the bpm when pl[0] is plausible', () {
      expect(HrParser.parseRealtime(Uint8List.fromList([72])), 72);
      expect(HrParser.parseRealtime(Uint8List.fromList([0x4D])), 77);
    });

    test('returns null for empty payload', () {
      expect(HrParser.parseRealtime(Uint8List(0)), isNull);
    });

    test('returns null for sensor warm-up bytes (0x00, 0xFF)', () {
      expect(HrParser.parseRealtime(Uint8List.fromList([0x00])), isNull);
      expect(HrParser.parseRealtime(Uint8List.fromList([0xFF])), isNull);
    });

    test(
      'ignores bytes beyond pl[0] (PROTOCOL.md §4.3 — only pl[0] is bpm)',
      () {
        // Trailing bytes are loadData on some firmware; must not influence bpm.
        expect(
          HrParser.parseRealtime(Uint8List.fromList([80, 0x00, 0x00, 0x00])),
          80,
        );
      },
    );
  });

  group('parseStartMeasureReply (0x69)', () {
    test('returns the bpm when errCode == 0 and value is plausible', () {
      final r = HrParser.parseStartMeasureReply(
        Uint8List.fromList([0x01, 0x00, 88]),
      );
      expect(r?.type, 0x01);
      expect(r?.err, 0x00);
      expect(r?.bpm, 88);
    });

    test('returns bpm null when errCode != 0 (session failed)', () {
      final r = HrParser.parseStartMeasureReply(
        Uint8List.fromList([0x01, 0x05, 88]),
      );
      expect(r?.err, 0x05);
      expect(r?.bpm, isNull);
    });

    test('returns bpm null for in-progress bytes (0, 1)', () {
      // Per smali StartHeartRateRsp.acceptData, value of 0/1 means
      // "session in progress, no reading yet".
      for (final v in [0, 1]) {
        final r = HrParser.parseStartMeasureReply(
          Uint8List.fromList([0x01, 0x00, v]),
        );
        expect(r?.bpm, isNull, reason: 'in-progress byte $v must not surface');
      }
    });

    test('returns null for a too-short payload', () {
      expect(
        HrParser.parseStartMeasureReply(Uint8List.fromList([0x01, 0x00])),
        isNull,
      );
      expect(HrParser.parseStartMeasureReply(Uint8List(0)), isNull);
    });

    test('extracts sbp/dbp when present (len >= 5)', () {
      // Per PROTOCOL.md §4.3: `[0]=type, [1]=err, [2]=value,
      // if len≥5 [3]=sbp [4]=dbp`.
      final r = HrParser.parseStartMeasureReply(
        Uint8List.fromList([0x02, 0x00, 78, 120, 80]),
      );
      expect(r?.type, 0x02);
      expect(r?.bpm, 78);
      expect(r?.systolic, 120);
      expect(r?.diastolic, 80);
    });
  });

  group('parseDeviceNotify (0x73 / 0x78)', () {
    test('finds HR at pl[1] when pl[0] is a non-HR dataType', () {
      expect(HrParser.parseDeviceNotify(Uint8List.fromList([0x05, 90])), 90);
    });

    test('finds HR at pl[2] on the alternate layout', () {
      expect(
        HrParser.parseDeviceNotify(Uint8List.fromList([0x05, 0x00, 95])),
        95,
      );
    });

    test('returns null when no byte in [1, 2] is plausible', () {
      expect(
        HrParser.parseDeviceNotify(Uint8List.fromList([0x05, 0x00, 0x00])),
        isNull,
      );
      expect(
        HrParser.parseDeviceNotify(Uint8List.fromList([0x05, 0xFF])),
        isNull,
      );
    });

    test('finds HR at pl[3] on the wider v14 layout (regression: HR bpm '
        'offset was missed on earlier firmware variants)', () {
      expect(
        HrParser.parseDeviceNotify(Uint8List.fromList([0x05, 0x00, 0x00, 102])),
        102,
      );
    });

    test('finds HR at pl[4] when two byte dataType + two byte padding '
        'precede the bpm', () {
      expect(
        HrParser.parseDeviceNotify(
          Uint8List.fromList([0x05, 0x00, 0x00, 0x00, 88]),
        ),
        88,
      );
    });

    test('returns null for payloads shorter than 2 bytes', () {
      expect(HrParser.parseDeviceNotify(Uint8List(0)), isNull);
      expect(HrParser.parseDeviceNotify(Uint8List.fromList([0x05])), isNull);
    });

    test('returns null when every probed offset is non-plausible', () {
      // 5-byte payload where offsets 1..4 are all zero — no HR.
      expect(
        HrParser.parseDeviceNotify(Uint8List.fromList([0x05, 0, 0, 0, 0])),
        isNull,
      );
    });

    test('dataType gate is enforced by the caller, not by this parser '
        '(footgun: ECG/PPG frames with a plausible bpm byte would be '
        'mis-classified without WatchManager._hrNotifyDataTypes gating)', () {
      // This test documents the contract between the parser and
      // WatchManager: parseDeviceNotify intentionally probes pl[1..4]
      // for any plausible bpm and does NOT filter on the dataType at
      // pl[0]. A non-HR dataType (e.g. an unconfirmed ECG id like
      // 0x09) that happens to carry a byte in 30..240 at pl[1] would
      // therefore return that byte as a bpm.
      //
      // The fix is in WatchManager: it gates the call on
      // `_hrNotifyDataTypes.contains(dataType)` (HR-class ids
      // observed on H59MA: 0x05, 0x06, 0x12) so a mis-classified frame
      // updates _observedUnknownNotifyTypes instead of
      // lastHeartRate. The parser itself stays permissive so a
      // future OEM dataType doesn't silently break HR.
      final pl = Uint8List.fromList([0x09, 80]); // hypothetical ECG id
      expect(
        HrParser.parseDeviceNotify(pl),
        80,
        reason: 'parser is intentionally permissive — caller must gate',
      );
    });
  });

  // ---------------------------------------------------------------------------
  // Cross-cutting HR / HRV / stress fragment tests.
  //
  // These exercise the parsers against the *actual* wire shapes documented
  // in PROTOCOL.md §4.3 / §4.6 and GHIDRA_DECOMPILATION.md §3.12-§3.13,
  // §3.20-§3.21 (HR history, real-time HR, stress history, HRV history).
  // The goal is to lock down the post-6edc267 normalised fragment
  // layout and prove that the parsers survive every documented payload
  // shape without losing data.
  // ---------------------------------------------------------------------------

  group('cross-cutting live HR shapes', () {
    test('0x1e real-time push: pl[0] is a single unsigned bpm byte', () {
      // GHIDRA §3.13 documents 0x1e as a 3-sub-opcode *controller* on
      // H59MA v14 (fire-and-forget; no bpm in the response). The legacy
      // APK-derived assumption was `pl[0] == bpm`. HrParser preserves
      // that path defensively for older firmware variants — verify the
      // shape here so future refactors cannot accidentally widen the
      // accepted byte range.
      for (final v in const [30, 60, 120, 240]) {
        expect(HrParser.parseRealtime(Uint8List.fromList([v])), v);
      }
    });

    test('0x1e with trailing bytes: only pl[0] is consulted (per '
        'PROTOCOL.md §4.3 — `pl[0]` is the bpm)', () {
      // Some firmwares append the request subData echo (sub-byte + param)
      // after the bpm. Parser must ignore those trailing bytes.
      expect(
        HrParser.parseRealtime(Uint8List.fromList([72, 0x01, 0x00, 0x00])),
        72,
      );
      expect(
        HrParser.parseRealtime(Uint8List.fromList([0x50, 0x03, 0xFF])),
        80,
      );
    });

    test('0x69 StartHeartRateRsp with type=6 (realtimeHeartRate) returns '
        'a plausible bpm in [bpm]', () {
      // type=6 is the "realtime" sub-mode — the [3] sbp/[4] dbp slots
      // are not present so the parser returns null for those.
      final r = HrParser.parseStartMeasureReply(
        Uint8List.fromList([0x06, 0x00, 88]),
      );
      expect(r?.type, 0x06);
      expect(r?.err, 0x00);
      expect(r?.bpm, 88);
      expect(r?.systolic, isNull);
      expect(r?.diastolic, isNull);
    });

    test('0x73 / 0x78 deviceNotify: HR-class dataType gates the parser', () {
      // The parser is intentionally permissive (returns the first
      // plausible bpm byte at offsets 1..4); the WatchManager-level
      // dataType gate is what keeps non-HR frames from poisoning
      // lastHeartRate. Lock both sides of the contract here.
      final hrType = 0x05; // first known HR-class dataType id
      // HR-class frame: dataType=0x05, bpm=99 at pl[1].
      expect(HrParser.parseDeviceNotify(Uint8List.fromList([hrType, 99])), 99);
      // A non-HR dataType that happens to carry a bpm byte at pl[1]
      // would still parse to that bpm — the gate must be enforced at
      // the call site, not in the parser. Verify the contract is
      // exactly as documented in watch_manager.dart.
      expect(
        HrParser.parseDeviceNotify(Uint8List.fromList([0x09, 99])),
        99,
        reason:
            'parser probes pl[1..4] regardless of dataType — '
            'caller must gate on _hrNotifyDataTypes',
      );
    });
  });

  group('cross-cutting HR history (0x15) multi-pkt reassembly', () {
    /// Helper: start syncAll, wait until `_currentSyncDay` is set
    /// for day 0, then inject the chunks so the per-day drain picks
    /// them up with `day = day0`. The wait time (~50ms) is enough to
    /// cover syncAll's loadFromStore + span-startup overhead and
    /// reach the HR day loop. The chunks must arrive within the
    /// per-day drain window (drainDuration=50ms) — keep the wait
    /// under 50ms to stay safely inside it.
    ///
    /// For cross-day tests, pass a [staged] callback that injects
    /// day-0 frames synchronously and day-1 frames after a ~120ms
    /// wait — that lands after day-0's drain + postCommandDelay so
    /// `_currentSyncDay` has been bumped to day-1 before the second
    /// batch arrives. This matches the day-attribution contract from
    /// history_sync.dart:619-635.
    Future<
      ({
        HistorySync sync,
        ChannelADispatcher d,
        FakeBleTransport t,
        Future<void> syncFuture,
      })
    >
    startSyncWithChunks({
      required int daysBack,
      required DateTime now,
      required void Function(FakeBleTransport t) inject,
      Future<void> Function(FakeBleTransport t)? staged,
    }) async {
      final t = FakeBleTransport();
      final d = ChannelADispatcher(t);
      d.bind();
      final sync = HistorySync(
        t,
        (_) {},
        dispatcher: d,
        drainDuration: const Duration(milliseconds: 50),
        postCommandDelay: const Duration(milliseconds: 50),
        fragmentQuietWindow: const Duration(milliseconds: 60),
        clock: () => now,
      );
      final syncFuture = sync.syncAll(daysBack: daysBack);
      // 50ms wait lands inside the per-day drain window after
      // syncAll has set `_currentSyncDay = day0`. This matches the
      // timing pattern used by `readHeartRate 0x15 multi-pkt
      // reassembly yields HrSamples` in history_sync_test.dart.
      await Future<void>.delayed(const Duration(milliseconds: 50));
      if (staged != null) {
        await staged(t);
      } else {
        inject(t);
      }
      return (sync: sync, d: d, t: t, syncFuture: syncFuture);
    }

    test(
      'pl[0]==0x18 header is recognised, chunk series captures the day '
      'and clears on the trailing 0xff frame (HS-8 + empty-day commit)',
      () async {
        final now = DateTime(2026, 6, 24, 12);
        final env = await startSyncWithChunks(
          daysBack: 1,
          now: now,
          inject: (t) {
            // Phase 1 — header (GHIDRA §3.12: dword 0x5180015 →
            // 0x15/0x18/0x80/0x05).
            t.inA.add(
              Codec.buildChannelA(OpA.readHeartRate, [0x18, 0x80, 0x05]),
            );
            // Phase 2 — single chunk carrying the 4-byte day-start LE
            // echo (pre-v14 smali convention) + 9 BPM samples.
            t.inA.add(
              Codec.buildChannelA(
                OpA.readHeartRate,
                Uint8List.fromList([
                  0x01, // seq=1 → flushes immediately
                  0x00, 0xF6, 0x34, 0x6A, // day-start LE
                  72, 80, 0xFF, 90, 95, 0x00, 110, 120, 130,
                ]),
              ),
            );
            // Phase 3 — empty-day marker (no record at this index).
            t.inA.add(Codec.buildChannelA(OpA.readHeartRate, [0xFF]));
          },
        );
        await env.syncFuture;

        // 7 plausible samples survived the sentinel filter (0xFF and
        // 0x00 are dropped by the keep-range gate).
        expect(
          env.sync.hr.map((s) => s.bpm).toList(),
          containsAll([72, 80, 90, 95, 110, 120, 130]),
        );
        // Anchored at day.midnight for each 5-min slot.
        for (final s in env.sync.hr) {
          expect(s.timestamp.hour, 0);
          expect(s.timestamp.minute % 5, 0);
        }

        env.sync.dispose();
        env.d.dispose();
      },
    );

    test('truncated record (only chunk 1, no trailing chunks) still '
        'flushes after the quiet window', () async {
      // A physical disconnect mid-stream would leave the chunk map
      // populated but incomplete. The reassembler must close the
      // record on the quiet-window timeout so the user sees the
      // partial day rather than nothing.
      final now = DateTime(2026, 6, 24, 12);
      final env = await startSyncWithChunks(
        daysBack: 1,
        now: now,
        inject: (t) {
          // Legacy header (`pl[0] == 0x18`) sets
          // `_hrExpectedChunks = null`, so the seq-based path fires
          // on receipt of any chunk. This decouples the test from
          // the H59MAX `pl[1]` chunkCount contract — we just want
          // to verify the seq-based flush path.
          t.inA.add(Codec.buildChannelA(OpA.readHeartRate, [0x18, 0x80, 0x05]));
          // Only the seq=1 chunk arrives — seq=2 never comes.
          t.inA.add(
            Codec.buildChannelA(
              OpA.readHeartRate,
              Uint8List.fromList([
                0x01,
                0x00,
                0xF6,
                0x34,
                0x6A,
                60,
                62,
                64,
                66,
              ]),
            ),
          );
        },
      );
      await env.syncFuture;

      expect(
        env.sync.hr.map((s) => s.bpm).toList(),
        containsAll([60, 62, 64, 66]),
      );

      env.sync.dispose();
      env.d.dispose();
    });

    test('two consecutive packets (today + yesterday) stitch without '
        'cross-day pollution', () async {
      // Regression for the HS-8 header-day-capture fix: chunks for
      // yesterday must NOT bleed into today's record and vice versa.
      // The day-attribution lifecycle in history_sync.dart sets
      // `_currentSyncDay` RIGHT BEFORE sendA and clears it RIGHT AFTER
      // the postCommandDelay (~100ms later). To exercise the contract
      // we stage the injection: day-0 frames synchronously, day-1
      // frames after a 120ms wait so `_currentSyncDay` has been
      // advanced to day-1 by the time the second batch arrives.
      final now = DateTime(2026, 6, 24, 12);
      final env = await startSyncWithChunks(
        daysBack: 2,
        now: now,
        inject: (_) {},
        staged: (t) async {
          // Day 0 (today): H59MAX header says 2 data chunks follow.
          t.inA.add(Codec.buildChannelA(OpA.readHeartRate, [0x00, 0x03, 0x05]));
          t.inA.add(
            Codec.buildChannelA(
              OpA.readHeartRate,
              Uint8List.fromList([
                0x01,
                0x00, 0xF6, 0x34, 0x6A, // 2026-06-19 day-start
                70, 75, 78, 80, 82, 84, 86, 88, 90,
              ]),
            ),
          );
          t.inA.add(
            Codec.buildChannelA(
              OpA.readHeartRate,
              Uint8List.fromList([
                0x02, // 13 pure BPM bytes
                95, 100, 105, 110, 115, 120, 125, 130, 135, 140,
                142, 144, 146,
              ]),
            ),
          );
          // Wait for day-0's drain (50ms) + postCommandDelay (50ms)
          // to elapse so `_currentSyncDay` is bumped to day-1 before
          // the second batch arrives.
          await Future<void>.delayed(const Duration(milliseconds: 120));
          // Day 1 (yesterday): H59MAX header says 2 data chunks follow.
          t.inA.add(Codec.buildChannelA(OpA.readHeartRate, [0x00, 0x03, 0x05]));
          t.inA.add(
            Codec.buildChannelA(
              OpA.readHeartRate,
              Uint8List.fromList([
                0x01,
                0x00, 0xEE, 0x34, 0x6A, // 2026-06-18 day-start
                80, 85, 90, 95, 100, 105, 110, 115, 120,
              ]),
            ),
          );
          t.inA.add(
            Codec.buildChannelA(
              OpA.readHeartRate,
              Uint8List.fromList([
                0x02,
                122,
                124,
                126,
                128,
                130,
                132,
                134,
                136,
                138,
                140,
                142,
                144,
                146,
              ]),
            ),
          );
        },
      );
      await env.syncFuture;

      final byDay = <int, List<int>>{};
      for (final s in env.sync.hr) {
        byDay.putIfAbsent(s.timestamp.day, () => []).add(s.bpm);
      }
      expect(
        byDay[24],
        containsAll([
          70,
          75,
          78,
          80,
          82,
          84,
          86,
          88,
          90,
          95,
          100,
          105,
          110,
          115,
          120,
          125,
          130,
          135,
          140,
          142,
          144,
          146,
        ]),
      );
      expect(
        byDay[23],
        containsAll([
          80,
          85,
          90,
          95,
          100,
          105,
          110,
          115,
          120,
          122,
          124,
          126,
          128,
          130,
          132,
          134,
          136,
          138,
          140,
          142,
          144,
          146,
        ]),
      );

      env.sync.dispose();
      env.d.dispose();
    });

    test('RR-interval stream — same 0x15 path packs multiple beat-to-beat '
        'samples per chunk (GHIDRA §3.12 producer output)', () async {
      // The GHIDRA §3.12 producer emits 73 × u32 (HR value /
      // RR-interval / motion flag). Our consumer collapses the
      // multi-field record down to 5-min BPM slots, treating EVERY
      // byte (post the 4-byte day-start echo) as a 5-min slot. This
      // means values that the firmware intended as RR-intervals or
      // motion flags can be misinterpreted as BPM if they fall in
      // [30..240]. This test pins the *current* behaviour so a future
      // migration to RR-aware parsing has a known baseline to compare
      // against.
      final now = DateTime(2026, 6, 24, 12);
      final env = await startSyncWithChunks(
        daysBack: 1,
        now: now,
        inject: (t) {
          t.inA.add(Codec.buildChannelA(OpA.readHeartRate, [0x00, 0x03, 0x05]));
          // First 4 bytes = day-start echo, then 9 "packed" bytes that
          // combine HR/RR/motion. Every byte in [30..240] survives the
          // keep-range filter — including bytes the firmware intended
          // as RR-intervals or motion flags.
          t.inA.add(
            Codec.buildChannelA(
              OpA.readHeartRate,
              Uint8List.fromList([
                0x01,
                0x00, 0xF6, 0x34, 0x6A, // day-start LE
                // 9 "packed" bytes — alternating bpm/RR. The 0x4F-0x53
                // bytes (79..83) are all in the plausible BPM range.
                72, 0x50,
                75, 0x4F,
                78, 0x52,
                80, 0x51,
                82, 0x53,
              ]),
            ),
          );
          // Chunk 2 — 13 packed bytes (no timestamp echo).
          t.inA.add(
            Codec.buildChannelA(
              OpA.readHeartRate,
              Uint8List.fromList([
                0x02,
                84,
                0x55,
                86,
                0x57,
                88,
                0x59,
                90,
                0x5B,
                92,
                0x5D,
                94,
                0x5F,
                96,
              ]),
            ),
          );
        },
      );
      await env.syncFuture;

      // Current behaviour: every byte in [30..240] survives the
      // keep-range filter, including the RR-interval bytes (0x4F-0x5F
      // = 79-95) which happen to be in the plausible BPM range. This
      // is the baseline a future RR-aware parser must improve on.
      final bpms = env.sync.hr.map((s) => s.bpm).toList();
      // The "real" bpm bytes survive.
      expect(
        bpms,
        containsAll([72, 75, 78, 80, 82, 84, 86, 88, 90, 92, 94, 96]),
      );
      // The RR-interval bytes that happen to be in [30..240] ALSO
      // surface — this is the bug a future RR-aware parser would fix.
      expect(
        bpms,
        contains(0x4F),
        reason: 'current parser treats every byte as a bpm slot',
      );
      expect(bpms.length, 22);

      env.sync.dispose();
      env.d.dispose();
    });
  });

  group('cross-cutting stress/HRV (0x37/0x39) fragment normalisation '
      '(post-6edc267)', () {
    /// Helper that emits the (header + 4 chunks) shape from
    /// GHIDRA §3.20/§3.21 and waits past the reassembler's quiet
    /// window. Returns the assembled records.
    Future<List<T>> captureRecords<T>({
      required FakeBleTransport t,
      required ChannelADispatcher d,
      required HistorySync sync,
      required int opcode,
      required List<int> Function() buildRecords,
      required Stream<T> Function() stream,
      required Duration quietWindow,
      int extraPadding = 0,
    }) async {
      final records = <T>[];
      final sub = stream().listen(records.add);
      // Header: pl[2] == 0x1E discriminator, pl[0] = slotId = 0.
      t.inA.add(Codec.buildChannelA(opcode, [0x00, 0x05, 0x1e]));
      // Chunks: seq + up-to-13 record bytes (4 chunks = 49 record bytes
      // for a single half-hour record). The dispatcher's
      // _stripOptionalSeriesSeq strips the seq byte when the chunk is
      // exactly 14 bytes and the leading byte is in 1..4.
      final record = buildRecords();
      var seq = 1;
      for (var off = 0; off < record.length; off += 13) {
        final end = (off + 13 < record.length) ? off + 13 : record.length;
        final chunkBody = <int>[seq++, ...record.sublist(off, end)];
        // Pad the last chunk up to 14 bytes so the dispatcher's
        // series-byte strip path activates. Any padding here becomes
        // part of the record bytes the reassembler sees.
        if (chunkBody.length < 14) {
          chunkBody.addAll(List.filled(14 - chunkBody.length, 0x00));
        }
        // On the very last chunk, optionally add a few trailing bytes
        // to simulate the firmware padding past the 48th sample.
        if (off + 13 >= record.length && extraPadding > 0) {
          chunkBody.addAll(List.filled(extraPadding, 0x00));
          // Trim back to 14 so the strip path stays in scope.
          while (chunkBody.length > 14) {
            chunkBody.removeLast();
          }
        }
        t.inA.add(Codec.buildChannelA(opcode, chunkBody));
      }
      await Future<void>.delayed(
        quietWindow + const Duration(milliseconds: 50),
      );
      await sub.cancel();
      return records;
    }

    test('0x39 HRV history 49-byte record assembles to slotId + 48 '
        'half-hour samples (GHIDRA §3.21)', () async {
      final t = FakeBleTransport();
      final d = ChannelADispatcher(t);
      d.bind();
      final sync = HistorySync(
        t,
        (_) {},
        dispatcher: d,
        drainDuration: const Duration(milliseconds: 30),
        postCommandDelay: Duration.zero,
        fragmentQuietWindow: const Duration(milliseconds: 80),
      );

      final samples = List<int>.generate(48, (i) => 0x40 + i);
      final records = await captureRecords<HrvRecord>(
        t: t,
        d: d,
        sync: sync,
        opcode: OpA.hrv,
        buildRecords: () => [0x00, ...samples],
        stream: () => sync.hrvRecords,
        quietWindow: const Duration(milliseconds: 80),
      );

      expect(records, hasLength(1));
      final r = records.first;
      // post-6edc267 normalisation: total payload is exactly 49 bytes
      // (slotId echo + 48 samples); the split is [0..4) / [4..49).
      expect(r.slotId, 0x00);
      expect(r.header.length, 4);
      expect(r.body.length, 45);
      // The 48 samples split as 3 in header, 45 in body.
      expect(r.header.sublist(1), samples.sublist(0, 3));
      expect(r.body, samples.sublist(3));

      sync.dispose();
      d.dispose();
    });

    test('0x37 stress (pressure) record uses the same normalised shape — '
        'GHIDRA §3.20 confirms `slotId + 48 half-hour samples`', () async {
      final t = FakeBleTransport();
      final d = ChannelADispatcher(t);
      d.bind();
      final sync = HistorySync(
        t,
        (_) {},
        dispatcher: d,
        drainDuration: const Duration(milliseconds: 30),
        postCommandDelay: Duration.zero,
        fragmentQuietWindow: const Duration(milliseconds: 80),
      );

      final samples = List<int>.generate(48, (i) => 0x50 + i);
      final records = await captureRecords<PressureRecord>(
        t: t,
        d: d,
        sync: sync,
        opcode: OpA.pressure,
        buildRecords: () => [0x00, ...samples],
        stream: () => sync.pressureRecords,
        quietWindow: const Duration(milliseconds: 80),
      );

      expect(records, hasLength(1));
      final r = records.first;
      expect(r.slotId, 0x00);
      expect(r.header.length, 4);
      expect(r.body.length, 45);
      expect(r.header.sublist(1), samples.sublist(0, 3));
      expect(r.body, samples.sublist(3));

      sync.dispose();
      d.dispose();
    });

    test(
      '0x37/0x39 over-sized payload (>49 bytes) is clamped to the '
      '49-byte fixed record shape — no tail bytes leak into the body',
      () async {
        // Some firmwares pad the trailing chunk with zeros or send an
        // extra byte; the post-6edc267 normaliser clips anything past
        // 49 bytes so the body stays a clean 45-byte slice.
        final t = FakeBleTransport();
        final d = ChannelADispatcher(t);
        d.bind();
        final sync = HistorySync(
          t,
          (_) {},
          dispatcher: d,
          drainDuration: const Duration(milliseconds: 30),
          postCommandDelay: Duration.zero,
          fragmentQuietWindow: const Duration(milliseconds: 80),
        );

        // Simulate the firmware shipping a record where the last
        // chunk contains 3 trailing zero bytes past the 48th sample.
        // The reassembler sees `seq + 14 bytes`, the stripper trims
        // the seq byte, and `_buildPressureRecord` clips the result
        // to the first 49 bytes.
        final samples = List<int>.generate(48, (i) => 0x60 + i);
        final oversized = [...samples, 0x00, 0x00, 0x00];
        final records = await captureRecords<PressureRecord>(
          t: t,
          d: d,
          sync: sync,
          opcode: OpA.pressure,
          buildRecords: () => [0x00, ...oversized],
          stream: () => sync.pressureRecords,
          quietWindow: const Duration(milliseconds: 80),
          extraPadding: 3,
        );

        expect(records, hasLength(1));
        final r = records.first;
        // Header[0] = slotId echo (0); body must still be 45 bytes —
        // the normaliser clips the 3 padding zeros, not the body.
        expect(r.header[0], 0x00);
        expect(r.body.length, 45);
        // No sentinel bytes (0x00 / 0xFF) sneak into the body tail —
        // the body's last element must be the 48th sample.
        expect(r.body.last, 0x60 + 47);

        sync.dispose();
        d.dispose();
      },
    );

    test('0x37/0x39 with a single chunk of 13 bytes still produces a '
        'record (truncated body, no crash)', () async {
      // Defensive: a watch that only ships the first chunk (e.g. the
      // user aborted, or the firmware returned a partial record) must
      // still surface a typed record rather than throwing.
      final t = FakeBleTransport();
      final d = ChannelADispatcher(t);
      d.bind();
      final sync = HistorySync(
        t,
        (_) {},
        dispatcher: d,
        drainDuration: const Duration(milliseconds: 30),
        postCommandDelay: Duration.zero,
        fragmentQuietWindow: const Duration(milliseconds: 80),
      );

      // Subscribe BEFORE injecting so the reassembler is wired.
      final records = <HrvRecord>[];
      final sub = sync.hrvRecords.listen(records.add);

      // Header.
      t.inA.add(Codec.buildChannelA(OpA.hrv, [0x00, 0x05, 0x1e]));
      // Single 14-byte chunk: seq=1 + 13 record bytes (slotId + 12
      // samples). The stripper trims the seq, the reassembler keeps
      // the 13 record bytes verbatim (no 49-byte clipping needed).
      t.inA.add(
        Codec.buildChannelA(
          OpA.hrv,
          Uint8List.fromList([
            0x01,
            0x00,
            60,
            62,
            64,
            66,
            0,
            0,
            0,
            0,
            0,
            0,
            0,
            0,
          ]),
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 200));
      await sub.cancel();

      expect(records, hasLength(1));
      final r = records.first;
      expect(r.slotId, 0x00);
      // 13 record bytes < 49 → not clipped; split is still 4 / 9.
      expect(r.header.length + r.body.length, 13);
      expect(r.header, [0x00, 60, 62, 64]);

      sync.dispose();
      d.dispose();
    });
  });
}
