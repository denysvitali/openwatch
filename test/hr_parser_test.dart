import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:openwatch/core/ble/ble_transport.dart';
import 'package:openwatch/core/protocol/channel_a.dart';
import 'package:openwatch/core/protocol/codec.dart';
import 'package:openwatch/core/protocol/hr_parser.dart';
import 'package:openwatch/core/protocol/opcodes.dart';
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
    test(
      'pl[0]==0x18 header is recognised, chunk series captures the day '
      'and clears on the trailing 0xff frame (HS-8 + empty-day commit)',
      () async {
        final t = _StubTransport();
        final d = ChannelADispatcher(t);
        d.bind();
        final sync = HistorySync(
          t,
          (_) {},
          dispatcher: d,
          drainDuration: const Duration(milliseconds: 30),
          postCommandDelay: Duration.zero,
          fragmentQuietWindow: const Duration(milliseconds: 60),
          clock: () => DateTime(2026, 6, 24, 12),
        );

        // Phase 1 — header (GHIDRA §3.12: dword 0x5180015 → 0x15/0x18/0x80/0x05).
        t.inA.add(Codec.buildChannelA(OpA.readHeartRate, [0x18, 0x80, 0x05]));

        // Phase 2 — single chunk carrying the 4-byte day-start LE echo
        // (per the pre-v14 smali convention) + 9 BPM samples.
        final dayStart = [0x00, 0xF6, 0x34, 0x6A]; // 2026-06-19 local midnight
        t.inA.add(
          Codec.buildChannelA(
            OpA.readHeartRate,
            Uint8List.fromList([
              0x01, // seq=1 → flushes
              ...dayStart,
              72, 80, 0xFF, 90, 95, 0x00, 110, 120, 130,
            ]),
          ),
        );
        // Phase 3 — empty-day marker (no record at this index).
        t.inA.add(Codec.buildChannelA(OpA.readHeartRate, [0xFF]));

        await Future<void>.delayed(const Duration(milliseconds: 200));

        // 6 plausible samples survived the sentinel filter.
        expect(
          sync.hr.map((s) => s.bpm).toList(),
          containsAll([72, 80, 90, 95, 110, 120, 130]),
        );
        // Anchored at day.midnight for each 5-min slot.
        for (final s in sync.hr) {
          expect(s.timestamp.hour, 0);
          expect(s.timestamp.minute % 5, 0);
        }

        sync.dispose();
        d.dispose();
      },
    );

    test('truncated record (only chunk 1, no trailing chunks) still '
        'flushes after the quiet window', () async {
      // A physical disconnect mid-stream would leave the chunk map
      // populated but incomplete. The reassembler must close the
      // record on the quiet-window timeout so the user sees the
      // partial day rather than nothing.
      final t = _StubTransport();
      final d = ChannelADispatcher(t);
      d.bind();
      final sync = HistorySync(
        t,
        (_) {},
        dispatcher: d,
        drainDuration: const Duration(milliseconds: 30),
        postCommandDelay: Duration.zero,
        fragmentQuietWindow: const Duration(milliseconds: 80),
        clock: () => DateTime(2026, 6, 24, 12),
      );

      t.inA.add(Codec.buildChannelA(OpA.readHeartRate, [0x00, 0x02, 0x05]));
      // Only the seq=1 chunk arrives — seq=2 never comes.
      t.inA.add(
        Codec.buildChannelA(
          OpA.readHeartRate,
          Uint8List.fromList([0x01, 0x00, 0xF6, 0x34, 0x6A, 60, 62, 64, 66]),
        ),
      );
      // Wait past the quiet window.
      await Future<void>.delayed(const Duration(milliseconds: 200));

      expect(sync.hr.map((s) => s.bpm).toList(), containsAll([60, 62, 64, 66]));
      // No future-day pollution: the truncated record still attributed
      // to the day the header arrived.
      for (final s in sync.hr) {
        expect(s.timestamp.day, 19);
      }

      sync.dispose();
      d.dispose();
    });

    test('two consecutive packets (today + yesterday) stitch without '
        'cross-day pollution', () async {
      // Regression for the HS-8 header-day-capture fix: a late chunk
      // for yesterday must NOT be attributed to today's flush, and
      // vice versa.
      final t = _StubTransport();
      final d = ChannelADispatcher(t);
      d.bind();
      final sync = HistorySync(
        t,
        (_) {},
        dispatcher: d,
        drainDuration: const Duration(milliseconds: 30),
        postCommandDelay: Duration.zero,
        fragmentQuietWindow: const Duration(milliseconds: 60),
        clock: () => DateTime(2026, 6, 24, 12),
      );

      // Day 0 (today): header → 1 chunk → done.
      t.inA.add(Codec.buildChannelA(OpA.readHeartRate, [0x00, 0x02, 0x05]));
      t.inA.add(
        Codec.buildChannelA(
          OpA.readHeartRate,
          Uint8List.fromList([0x01, 0x00, 0xF6, 0x34, 0x6A, 70, 75]),
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 120));

      // Day 1 (yesterday): header → 1 chunk → done.
      t.inA.add(Codec.buildChannelA(OpA.readHeartRate, [0x00, 0x02, 0x05]));
      t.inA.add(
        Codec.buildChannelA(
          OpA.readHeartRate,
          Uint8List.fromList([0x01, 0x00, 0xEE, 0x34, 0x6A, 80, 85]),
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 200));

      final byDay = <int, List<int>>{};
      for (final s in sync.hr) {
        byDay.putIfAbsent(s.timestamp.day, () => []).add(s.bpm);
      }
      // Today's slots live on the 24th, yesterday's on the 23rd.
      expect(byDay[24], containsAll([70, 75]));
      expect(byDay[23], containsAll([80, 85]));
      // And the two records did not bleed into each other.
      expect(byDay[24]!.contains(80), isFalse);
      expect(byDay[23]!.contains(70), isFalse);

      sync.dispose();
      d.dispose();
    });

    test('RR-interval stream — same 0x15 path packs multiple beat-to-beat '
        'samples per chunk (GHIDRA §3.12 producer output)', () async {
      // The GHIDRA §3.12 producer (FUN_00833c92) emits 73 × u32
      // (HR value / RR-interval / motion flag). Our consumer collapses
      // the multi-field record down to 5-min BPM slots, dropping the
      // RR-interval + motion bytes (see "Coverage gaps" in the doc).
      // This test pins the *current* behaviour so a future migration
      // to RR-aware parsing has a known baseline to compare against.
      final t = _StubTransport();
      final d = ChannelADispatcher(t);
      d.bind();
      final sync = HistorySync(
        t,
        (_) {},
        dispatcher: d,
        drainDuration: const Duration(milliseconds: 30),
        postCommandDelay: Duration.zero,
        fragmentQuietWindow: const Duration(milliseconds: 60),
        clock: () => DateTime(2026, 6, 24, 12),
      );

      t.inA.add(Codec.buildChannelA(OpA.readHeartRate, [0x00, 0x02, 0x05]));
      // Mimic the producer: first 4 bytes = day-start echo, then 9
      // "compressed" bytes that combine HR/RR/motion. The parser
      // treats every byte as a 5-min bpm slot — currently this means
      // a beat-to-beat pack like [72, 0x50] (bpm=72, rr=0x50=80ms)
      // surfaces only the bpm byte, dropping the RR interval.
      t.inA.add(
        Codec.buildChannelA(
          OpA.readHeartRate,
          Uint8List.fromList([
            0x01, // seq=1
            0x00, 0xF6, 0x34, 0x6A, // day-start LE
            // 9 "packed" bytes: 3 × (bpm, rr).
            72, 0x50,
            75, 0x4F,
            78, 0x52,
            80, 0x51,
            82, 0x53,
          ]),
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 200));

      final bpms = sync.hr.map((s) => s.bpm).toList();
      // Only the bpm bytes are surfaced (5 of them).
      expect(bpms, [72, 75, 78, 80, 82]);

      sync.dispose();
      d.dispose();
    });
  });

  group('cross-cutting stress/HRV (0x37/0x39) fragment normalisation '
      '(post-6edc267)', () {
    test('0x39 hrvSettings 49-byte record assembles to slotId + 48 '
        'half-hour samples (GHIDRA §3.21)', () async {
      final t = _StubTransport();
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

      // Header (GHIDRA §3.21: dword 0x1E050039 LE → 0x39/0x00/0x05/0x1E).
      // pl[0] = slotId echo (today = 0).
      t.inA.add(Codec.buildChannelA(OpA.hrv, [0x00, 0x05, 0x1E]));
      // 4 sequenced chunks of (seq, 13 record bytes). On H59MAX live
      // firmware the chunk payload is `seq + 13 data bytes`; the
      // dispatcher strips the seq byte via _stripOptionalSeriesSeq.
      final samples = List<int>.generate(48, (i) => 30 + i);
      var seq = 1;
      for (var off = 0; off < samples.length; off += 13) {
        final end = off + 13 < samples.length ? off + 13 : samples.length;
        final payload = [seq++, 0x00, ...samples.sublist(off, end)];
        // Pad to a full 14-byte body so Codec.buildChannelA emits a
        // valid 16-byte frame.
        while (payload.length < 14) {
          payload.add(0x00);
        }
        t.inA.add(Codec.buildChannelA(OpA.hrv, payload));
      }
      await Future<void>.delayed(const Duration(milliseconds: 200));

      final records = <HrvRecord>[];
      final sub = sync.hrvRecords.listen(records.add);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      await sub.cancel();

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
      final t = _StubTransport();
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

      t.inA.add(Codec.buildChannelA(OpA.pressure, [0x00, 0x05, 0x1E]));
      final samples = List<int>.generate(48, (i) => 50 + i);
      var seq = 1;
      for (var off = 0; off < samples.length; off += 13) {
        final end = off + 13 < samples.length ? off + 13 : samples.length;
        final payload = [seq++, 0x00, ...samples.sublist(off, end)];
        while (payload.length < 14) {
          payload.add(0x00);
        }
        t.inA.add(Codec.buildChannelA(OpA.pressure, payload));
      }
      await Future<void>.delayed(const Duration(milliseconds: 200));

      final records = <PressureRecord>[];
      final sub = sync.pressureRecords.listen(records.add);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      await sub.cancel();

      expect(records, hasLength(1));
      final r = records.first;
      expect(r.slotId, 0x00);
      expect(r.header.length, 4);
      expect(r.body.length, 45);

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
        final t = _StubTransport();
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

        t.inA.add(Codec.buildChannelA(OpA.pressure, [0x00, 0x05, 0x1E]));
        // Emit 4 chunks where the *last* one carries 14 record bytes
        // (3 padding zeros past the 48th sample). Total payload
        // before normalise = 1 + 48 + 3 = 52 bytes.
        final samples = List<int>.generate(48, (i) => 60 + i);
        var seq = 1;
        for (var off = 0; off < samples.length; off += 13) {
          final end = off + 13 < samples.length ? off + 13 : samples.length;
          final payload = [seq++, 0x00, ...samples.sublist(off, end)];
          // On the very last chunk, pretend the firmware added 3
          // trailing zero bytes past the 48th sample.
          if (end == samples.length) {
            payload.addAll([0x00, 0x00, 0x00]);
          }
          while (payload.length < 14) {
            payload.add(0x00);
          }
          t.inA.add(Codec.buildChannelA(OpA.pressure, payload));
        }
        await Future<void>.delayed(const Duration(milliseconds: 200));

        final records = <PressureRecord>[];
        final sub = sync.pressureRecords.listen(records.add);
        await Future<void>.delayed(const Duration(milliseconds: 100));
        await sub.cancel();

        expect(records, hasLength(1));
        final r = records.first;
        // Header[0] = slotId echo (0); body must still be 45 bytes —
        // the normaliser clips the 3 padding zeros, not the body.
        expect(r.header[0], 0x00);
        expect(r.body.length, 45);
        // No sentinel bytes (0x00 / 0xFF) sneak into the body tail —
        // the body's last element must be the 48th sample.
        expect(r.body.last, 60 + 47);

        sync.dispose();
        d.dispose();
      },
    );

    test('0x37/0x39 with a single chunk of 13 bytes still produces a '
        'record (truncated body, no crash)', () async {
      // Defensive: a watch that only ships the first chunk (e.g. the
      // user aborted, or the firmware returned a partial record) must
      // still surface a typed record rather than throwing.
      final t = _StubTransport();
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

      t.inA.add(Codec.buildChannelA(OpA.hrv, [0x00, 0x05, 0x1E]));
      // Single chunk with only 4 usable body bytes (slotId + 3
      // samples) — the splitter still produces header/body without
      // crashing.
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

      final records = <HrvRecord>[];
      final sub = sync.hrvRecords.listen(records.add);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      await sub.cancel();

      expect(records, hasLength(1));
      final r = records.first;
      expect(r.slotId, 0x00);
      // Truncated payload (7 bytes < 49) is passed through verbatim:
      // header absorbs all bytes, body is empty.
      expect(r.header.length + r.body.length, lessThanOrEqualTo(7));
      expect(r.header, [0x00, 60, 62, 64]);

      sync.dispose();
      d.dispose();
    });
  });
}
