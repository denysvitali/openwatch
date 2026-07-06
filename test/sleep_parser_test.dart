import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:openwatch/core/protocol/sleep_parser.dart';
import 'package:openwatch/core/services/app_log.dart';
import 'package:openwatch/features/history/sleep_session_summary.dart';

void main() {
  group('SleepParser — parseNightSleepSegments (0x27 Ch-B)', () {
    final anchor = DateTime(2026, 6, 20);

    test('parses a single block of 3 (stage, durMin) pairs', () {
      // Block: dayOffset=1, u16 BE endMin = 7:30 = 450 = 0x01C2
      // Pairs: (light=1, 30min), (deep=2, 90min), (rem=3, 60min)
      // Total = 180 min ⇒ startMin = 450 - 180 = 270 = 04:30
      final pl = Uint8List.fromList([
        0x01, // dayOffset
        0x01, 0xC2, // endMinOfDay BE
        0x01, 0x1E, // light, 30 min
        0x02, 0x5A, // deep,  90 min
        0x03, 0x3C, // rem,   60 min
      ]);
      final segs = SleepParser.parseNightSleepSegments(pl, anchor: anchor);
      expect(segs, hasLength(3));
      expect(segs[0].stage, SleepStage.light);
      expect(segs[0].duration.inMinutes, 30);
      expect(segs[1].stage, SleepStage.deep);
      expect(segs[1].duration.inMinutes, 90);
      expect(segs[2].stage, SleepStage.rem);
      expect(segs[2].duration.inMinutes, 60);
      // Segments are stamped with sequential start times so the
      // chart on the history screen can plot them as contiguous
      // bars without recomputing deltas.
      expect(segs[0].start, DateTime(2026, 6, 20, 4, 30));
      expect(segs[1].start, DateTime(2026, 6, 20, 5, 0));
      expect(segs[2].start, DateTime(2026, 6, 20, 6, 30));
    });

    test('skips the leading dayOffset byte (PROTOCOL.md §4.4 night)', () {
      // First byte = dayOffset = 0; the rest is the same block as
      // the previous test. The parser unconditionally strips the
      // leading dayOffset byte before reading endMin.
      final pl = Uint8List.fromList([
        0x00, // dayOffset
        0x01, 0xC2, // endMinOfDay BE 450
        0x01, 0x1E, // light 30
        0x02, 0x5A, // deep 90
        0x03, 0x3C, // rem 60
      ]);
      final segs = SleepParser.parseNightSleepSegments(pl, anchor: anchor);
      expect(segs, hasLength(3));
      expect(segs.map((s) => s.stage), [
        SleepStage.light,
        SleepStage.deep,
        SleepStage.rem,
      ]);
    });

    test('treats a (0,0) pair as a chain terminator', () {
      // Two blocks separated by a NUL pair.
      final pl = Uint8List.fromList([
        0x01, // dayOffset
        0x01, 0xC2, // endMin 450 BE
        0x01, 0x1E, // light 30
        0x02, 0x5A, // deep 90
        0x00, 0x00, // terminator
        0x00, 0xF0, // endMin 240 BE = 04:00
        0x03, 0x3C, // rem 60
      ]);
      final segs = SleepParser.parseNightSleepSegments(pl, anchor: anchor);
      expect(segs, hasLength(3));
      // Block #2 is just one REM segment starting at 03:00.
      expect(segs[2].stage, SleepStage.rem);
      expect(segs[2].duration.inMinutes, 60);
      expect(segs[2].start, DateTime(2026, 6, 20, 3, 0));
    });

    test('returns an empty list for an empty payload', () {
      AppLog.instance.clear();
      expect(
        SleepParser.parseNightSleepSegments(Uint8List(0), anchor: anchor),
        isEmpty,
      );
      // Empty payload is "no data", not "corrupted data" — logged at debug.
      expect(
        AppLog.instance.entries.any(
          (e) =>
              e.tag == 'sleep' &&
              e.level == LogLevel.debug &&
              e.message.contains('empty'),
        ),
        isTrue,
      );
    });

    test('returns an empty list for a payload shorter than 4 bytes', () {
      AppLog.instance.clear();
      expect(
        SleepParser.parseNightSleepSegments(
          Uint8List.fromList([0x00, 0x00]),
          anchor: anchor,
        ),
        isEmpty,
      );
      // After stripping dayOffset, remaining length is 1 — too short.
      // Logged at warn so telemetry can detect unexpectedly short
      // firmware payloads (SP-4).
      expect(
        AppLog.instance.entries.any(
          (e) =>
              e.tag == 'sleep' &&
              e.level == LogLevel.warn &&
              e.message.contains('too short'),
        ),
        isTrue,
      );
    });

    test('does not crash on malformed end-minute (> 1439)', () {
      // endMin = 0xFFFF (65535) is garbage; the parser bails out
      // and returns an empty list rather than emitting nonsense.
      final pl = Uint8List.fromList([0xFF, 0xFF, 0x01, 0x1E]);
      expect(SleepParser.parseNightSleepSegments(pl, anchor: anchor), isEmpty);
    });

    test('parses a real-frame-shape payload (dayOffset=1 + BE endMin 52)', () {
      // Regression for the user's reported export anomaly. The
      // exact first 9 bytes of one of the live H59MA frames:
      //   pl[0]    = 0x01 (dayOffset = 1 = "yesterday")
      //   pl[1..2] = 0x00 0x34 (BE endMin = 52 = 00:52 wake)
      //   pl[3..]  = alternating (stage, durMin) pairs
      // Under the OLD parser (LE endMin, heuristic day-offset),
      // pl[0] was misread as the low byte of a LE u16:
      //   firstEnd = 0x01 | (0x00 << 8) = 1 → NOT > 1439, so the
      //   heuristic kept pl[0] and read 0x01 0x34 as endMin = 0x3401
      //   = 13313 → bail out, returning []. The parser effectively
      //   dropped every H59MA night-sleep frame on the floor.
      // The fix: always skip pl[0] as dayOffset, then read
      // pl[1..2] as a u16 BE endMin.
      final pl = Uint8List.fromList([
        0x01, // dayOffset (now ALWAYS skipped)
        0x00, 0x34, // endMin BE = 52 (00:52)
        0x75, 0x05, // awake  5
        0x0E, 0x02, // light  2
        0x02, 0x13, // deep  19
        0x03, 0x10, // rem   16
      ]);
      final segs = SleepParser.parseNightSleepSegments(pl, anchor: anchor);
      expect(segs, hasLength(4));
      expect(segs.first.duration.inMinutes, 5);
      expect(segs.last.duration.inMinutes, 16);
    });

    test('parses live H59MA record-list payload with LE start/end minutes', () {
      // From H59MA_1.00.13_251230 live log:
      //   count=1, dayDelta=0, blockLen=0x28,
      //   startMin=0x001e (00:30), endMin=0x01f2 (08:18),
      //   followed by 18 (stage,duration) pairs totalling 468 minutes.
      final pl = Uint8List.fromList([
        0x01,
        0x00,
        0x28,
        0x1e,
        0x00,
        0xf2,
        0x01,
        0x02,
        0x1b,
        0x03,
        0x16,
        0x02,
        0x1d,
        0x03,
        0x15,
        0x04,
        0x09,
        0x03,
        0x19,
        0x04,
        0x0d,
        0x02,
        0x15,
        0x04,
        0x0d,
        0x02,
        0x31,
        0x04,
        0x13,
        0x03,
        0x37,
        0x04,
        0x11,
        0x03,
        0x3a,
        0x04,
        0x1a,
        0x02,
        0x1a,
        0x04,
        0x0b,
        0x02,
        0x1b,
      ]);
      expect(SleepParser.isH59maNightRecordPayload(pl), isTrue);
      expect(SleepParser.h59maNightRecordDayDeltas(pl), [0]);

      final segs = SleepParser.parseNightSleepSegments(pl, anchor: anchor);
      expect(segs, hasLength(18));
      expect(segs.first.start, DateTime(2026, 6, 20, 0, 30));
      expect(segs.first.stage, SleepStage.deep);
      expect(segs.first.duration.inMinutes, 27);
      expect(segs.last.start, DateTime(2026, 6, 20, 7, 51));
      expect(segs.last.duration.inMinutes, 27);
    });

    test('returns an empty list when BE endMin > 1439 (malformed)', () {
      // After the dayOffset byte is unconditionally stripped, the
      // first two bytes of the remaining payload are read as a
      // u16 BE endMin. `0xFF 0xFF` = 65535 is garbage, so the
      // parser must bail out cleanly and return [].
      final pl = Uint8List.fromList([
        0x02, // dayOffset (stripped)
        0xFF, 0xFF, // BE 65535 → invalid
        0x01, 0x1E,
      ]);
      expect(SleepParser.parseNightSleepSegments(pl, anchor: anchor), isEmpty);
    });

    test('maps H59MA-style score bytes (0x05..0x0f) to SleepStage.deep', () {
      // The H59MA v13 firmware emits stage bytes in the range
      // 0x05..0xff instead of the canonical Oudmon 0x01..0x04
      // (see `firmwares/GHIDRA_DECOMPILATION.md` §2.3). Previously
      // these collapsed every segment to `awake`, painting the
      // sleep chart solid red. The mapping now interprets the byte
      // as a coarse sleep-quality score.
      final pl = Uint8List.fromList([
        0x01, // dayOffset = 1
        0x00, 0x2A, // endMin BE = 42
        0x09, 0x14, // score 9 → deep, 20 min
      ]);
      final segs = SleepParser.parseNightSleepSegments(pl, anchor: anchor);
      expect(segs.single.stage, SleepStage.deep);
      expect(segs.single.duration.inMinutes, 20);
    });

    test('H59MA score range 0x10..0x1f maps to SleepStage.light', () {
      final pl = Uint8List.fromList([
        0x01, // dayOffset
        0x00, 0x2A,
        0x15, 0x05, // score 0x15=21 → light, 5 min
      ]);
      final segs = SleepParser.parseNightSleepSegments(pl, anchor: anchor);
      expect(segs.single.stage, SleepStage.light);
    });

    test('H59MA score range 0x20..0x2f maps to SleepStage.rem', () {
      final pl = Uint8List.fromList([
        0x01, // dayOffset
        0x00, 0x2A,
        0x25, 0x05, // score 0x25=37 → rem, 5 min
      ]);
      final segs = SleepParser.parseNightSleepSegments(pl, anchor: anchor);
      expect(segs.single.stage, SleepStage.rem);
    });

    test('H59MA score 0x30+ falls through to SleepStage.awake', () {
      // The high end of the range is genuinely "lots of movement"
      // and stays awake — only the low/mid ranges got demoted.
      final pl = Uint8List.fromList([
        0x01, // dayOffset
        0x00, 0x2A,
        0x35, 0x05, // score 0x35=53 → awake, 5 min
      ]);
      final segs = SleepParser.parseNightSleepSegments(pl, anchor: anchor);
      expect(segs.single.stage, SleepStage.awake);
    });

    test('0x00 stays mapped to SleepStage.awake (no-data sentinel)', () {
      final pl = Uint8List.fromList([
        0x01, // dayOffset
        0x00, 0x2A,
        0x00, 0x05, // 0x00 → awake, 5 min
      ]);
      final segs = SleepParser.parseNightSleepSegments(pl, anchor: anchor);
      expect(segs.single.stage, SleepStage.awake);
    });

    test('blocks that wrap midnight re-key to bedtime day (regression for '
        '"night sleep stored under wake-up day" complaint)', () {
      // Block: endMin = 83 (01:23) with total duration 302 min
      // ⇒ startMin = -219 → wraps to 1221 (20:21). The 5
      // segments are emitted in time order: the first 3 finish
      // before midnight (bedtime day 2026-06-19) and the last 2
      // land after midnight on the wake-up day (2026-06-20).
      // The OLD parser stamped them all onto the wake-up day with
      // start times on the wake-up day, which is wrong: a 4h50m
      // sleep starting at 20:21 the previous evening belongs to
      // the bedtime day for as long as it stays on that day.
      final pl = Uint8List.fromList([
        0x01, // dayOffset
        0x00, 0x53, // endMinOfDay BE = 83 (01:23)
        0x04, 0x75, // awake 117 min
        0x01, 0x0F, // light 15 min
        0x02, 0x78, // deep 120 min
        0x03, 0x14, // rem  20 min
        0x01, 0x1E, // light 30 min
      ]);
      final segs = SleepParser.parseNightSleepSegments(pl, anchor: anchor);
      expect(segs, hasLength(5));
      final bedtime = DateTime(2026, 6, 19);
      final wakeDay = DateTime(2026, 6, 20);
      // First segment lands at 20:21 on bedtime day — NOT at
      // 20:21 on the wake-up day (which would be 44h after
      // the anchor's local midnight and clearly nonsensical).
      expect(segs.first.start, DateTime(2026, 6, 19, 20, 21));
      // Pre-midnight segments stay on the bedtime day.
      expect(
        DateTime(segs[0].start.year, segs[0].start.month, segs[0].start.day),
        bedtime,
      );
      expect(
        DateTime(segs[1].start.year, segs[1].start.month, segs[1].start.day),
        bedtime,
      );
      expect(
        DateTime(segs[2].start.year, segs[2].start.month, segs[2].start.day),
        bedtime,
      );
      // Post-midnight segments roll over to the wake-up day
      // (the session crossed midnight again naturally).
      expect(
        DateTime(segs[3].start.year, segs[3].start.month, segs[3].start.day),
        wakeDay,
        reason: 'segments after midnight roll over to the wake-up day',
      );
      expect(
        DateTime(segs[4].start.year, segs[4].start.month, segs[4].start.day),
        wakeDay,
      );
    });

    test(
      'non-DST day still computes correctly with dynamic day length (SP-3)',
      () {
        // A normal 24-hour day should still produce the same results
        // as before — the dynamic computation just happens to equal 1440.
        // On hosts without DST (e.g. CI) this is the exercised path.
        final pl = Uint8List.fromList([
          0x01, // dayOffset
          0x00, 0x53, // endMinOfDay BE = 83 (01:23)
          0x04, 0x75, // awake 117 min
          0x01, 0x0F, // light 15 min
          0x02, 0x78, // deep 120 min
          0x03, 0x14, // rem  20 min
          0x01, 0x1E, // light 30 min
        ]);
        final segs = SleepParser.parseNightSleepSegments(pl, anchor: anchor);
        expect(segs.first.start, DateTime(2026, 6, 19, 20, 21));
      },
    );

    test('blocks that do NOT wrap midnight stay on the wake-up day', () {
      // endMin = 480 (08:00), total = 240 min ⇒ startMin = 240
      // (04:00) — no wrap. All segments on the anchor day.
      final pl = Uint8List.fromList([
        0x01, // dayOffset
        0x01, 0xE0, // endMinOfDay BE = 480
        0x01, 0x78, // light 120 min
        0x02, 0x3C, // deep  60 min
        0x03, 0x3C, // rem   60 min
      ]);
      final segs = SleepParser.parseNightSleepSegments(pl, anchor: anchor);
      expect(segs, hasLength(3));
      for (final s in segs) {
        expect(
          DateTime(s.start.year, s.start.month, s.start.day),
          anchor,
          reason: 'non-wrap segments stay on the wake-up day',
        );
      }
      expect(segs.first.start, DateTime(2026, 6, 20, 4, 0));
    });

    test(
      'empty pair block after endMin does not misalign on trailing bytes (SP-1)',
      () {
        // Regression: after reading endMin, if the buffer ends immediately
        // (no pairs), the old code did `continue` with `i` unchanged relative
        // to the outer while check. The next outer iteration would then read
        // a new endMin from what was actually the start of pair data of the
        // NEXT block, causing misalignment. The fix: when pairs is empty and
        // we did NOT hit a zero/zero terminator, break out of the outer loop.
        //
        // Payload: dayOffset=1, endMin=52 (0x00 0x34), then a valid block
        // endMin=120 (0x00 0x78), (light=1, 30min). The first block has no
        // pairs, so the parser should stop and NOT misread 0x00 0x78 as
        // a pair (stage=0, dur=120) which would then misalign the next block.
        final pl = Uint8List.fromList([
          0x01, // dayOffset
          0x00, 0x34, // endMin = 52 — block with NO pairs
          0x00, 0x78, // endMin = 120 — next block
          0x01, 0x1E, // light, 30 min
        ]);
        final segs = SleepParser.parseNightSleepSegments(pl, anchor: anchor);
        // The first block is skipped (empty pairs), and the parser should
        // break cleanly instead of misaligning. The second block should be
        // parsed correctly.
        expect(segs, hasLength(1));
        expect(segs.single.stage, SleepStage.light);
        expect(segs.single.duration.inMinutes, 30);
        expect(segs.single.start, DateTime(2026, 6, 20, 1, 30));
      },
    );

    test('empty pair block with trailing garbage stops parsing (SP-1)', () {
      // After endMin, only 1 byte remains — not enough for a pair.
      // The parser should break out of the outer loop and not try to
      // re-align on the single trailing byte.
      final pl = Uint8List.fromList([
        0x01, // dayOffset
        0x00, 0x34, // endMin = 52
        0x01, // lone trailing byte — not a valid pair
      ]);
      final segs = SleepParser.parseNightSleepSegments(pl, anchor: anchor);
      expect(segs, isEmpty);
    });

    test(
      'empty pair block followed by terminator skips block and continues (SP-1)',
      () {
        // Block 1: endMin=52, no pairs, then zero/zero terminator
        // Block 2: endMin=120, (light=1, 30min)
        final pl = Uint8List.fromList([
          0x01, // dayOffset
          0x00, 0x34, // endMin = 52 — block with NO pairs
          0x00, 0x00, // terminator for block 1
          0x00, 0x78, // endMin = 120 — block 2
          0x01, 0x1E, // light, 30 min
        ]);
        final segs = SleepParser.parseNightSleepSegments(pl, anchor: anchor);
        expect(segs, hasLength(1));
        expect(segs.single.stage, SleepStage.light);
        expect(segs.single.duration.inMinutes, 30);
        expect(segs.single.start, DateTime(2026, 6, 20, 1, 30));
      },
    );

    test('lunch: empty pair block after endMin does not misalign (SP-1)', () {
      // Same bug for lunch/nap parser (no dayOffset prefix).
      final pl = Uint8List.fromList([
        0x00, 0x34, // endMin = 52 — block with NO pairs
        0x00, 0x78, // endMin = 120 — next block
        0x01, 0x1E, // light, 30 min
      ]);
      final segs = SleepParser.parseLunchSleepSegments(pl, anchor: anchor);
      expect(segs, hasLength(1));
      expect(segs.single.stage, SleepStage.light);
      expect(segs.single.duration.inMinutes, 30);
    });

    test('endMin == 0 with empty pairs is a no-data sentinel (SP-5)', () {
      // Firmware may use endMin = 0 with no pairs as a "no sleep record"
      // sentinel (similar to the 0xFF empty-day marker in HR history).
      // The parser must skip it and continue to the next block rather
      // than breaking out of the outer loop.
      final pl = Uint8List.fromList([
        0x01, // dayOffset
        0x00, 0x00, // endMin = 0 — no-data sentinel, no pairs
        0x00, 0x78, // endMin = 120 — next block
        0x01, 0x1E, // light, 30 min
      ]);
      final segs = SleepParser.parseNightSleepSegments(pl, anchor: anchor);
      expect(segs, hasLength(1));
      expect(segs.single.stage, SleepStage.light);
      expect(segs.single.duration.inMinutes, 30);
      expect(segs.single.start, DateTime(2026, 6, 20, 1, 30));
    });

    test(
      'endMin == 0 sentinel with terminator skips block and continues (SP-5)',
      () {
        // The sentinel may be followed by a zero/zero terminator; the
        // parser should still continue to the next block.
        final pl = Uint8List.fromList([
          0x01, // dayOffset
          0x00, 0x00, // endMin = 0 — no-data sentinel
          0x00, 0x00, // terminator
          0x00, 0x78, // endMin = 120 — next block
          0x01, 0x1E, // light, 30 min
        ]);
        final segs = SleepParser.parseNightSleepSegments(pl, anchor: anchor);
        expect(segs, hasLength(1));
        expect(segs.single.stage, SleepStage.light);
        expect(segs.single.duration.inMinutes, 30);
        expect(segs.single.start, DateTime(2026, 6, 20, 1, 30));
      },
    );

    test(
      'lunch: endMin == 0 with empty pairs is a no-data sentinel (SP-5)',
      () {
        // Lunch/nap variant has no dayOffset prefix.
        final pl = Uint8List.fromList([
          0x00, 0x00, // endMin = 0 — no-data sentinel, no pairs
          0x00, 0x78, // endMin = 120 — next block
          0x01, 0x1E, // light, 30 min
        ]);
        final segs = SleepParser.parseLunchSleepSegments(pl, anchor: anchor);
        expect(segs, hasLength(1));
        expect(segs.single.stage, SleepStage.light);
        expect(segs.single.duration.inMinutes, 30);
        expect(segs.single.start, DateTime(2026, 6, 20, 1, 30));
      },
    );

    test('endMin == 0 sentinel at end of payload returns empty (SP-5)', () {
      // When the sentinel is the last thing in the payload, there is no
      // next block to parse — the result is simply empty.
      final pl = Uint8List.fromList([
        0x01, // dayOffset
        0x00,
        0x00, // endMin = 0 — no-data sentinel, no pairs, no trailing bytes
      ]);
      final segs = SleepParser.parseNightSleepSegments(pl, anchor: anchor);
      expect(segs, isEmpty);
    });

    test(
      'lunch: endMin == 0 sentinel at end of payload returns empty (SP-5)',
      () {
        final pl = Uint8List.fromList([
          0x00, 0x00, // endMin = 0 — no-data sentinel, no pairs
        ]);
        final segs = SleepParser.parseLunchSleepSegments(pl, anchor: anchor);
        expect(segs, isEmpty);
      },
    );
    test('stale-buffer echo is skipped but genuine block is kept (SP-2)', () {
      // Legacy chained-block shape: the response contained the previous
      // day's record appended (stale buffer). The concatenated block
      // totals 858 min (14.3 h) and would otherwise be filed as a single
      // sleep session, producing a day with >24 h of sleep when combined
      // with the real previous-day record.
      //
      // Use dayOffset=7 so this old-shape fallback fixture cannot also
      // be interpreted as a valid H59MA count-prefixed record list.
      // With `continue` (not `break`) only the malformed block is
      // skipped; the genuine current block is preserved.
      final pl = Uint8List.fromList([
        0x07, // legacy dayOffset; parser strips it before chained decode
        0x01, 0x18, // endMin BE = 280 (04:40)
        // Genuine current block (12 pairs, 230 min):
        0x2d, 0x01, 0x10, 0x02, 0x02, 0x26, 0x04, 0x0e, 0x03, 0x18, 0x04,
        0x0f, 0x02, 0x1f, 0x03, 0x25, 0x04, 0x0b, 0x03, 0x21, 0x04, 0x11,
        0x02, 0x07,
        // Stale dayOffset=1 record echoed verbatim (endMin=52 + 26 pairs):
        0x00, 0x34, 0x75, 0x05, 0x0e, 0x02, 0x02, 0x13, 0x03, 0x10, 0x04,
        0x0e, 0x02, 0x22, 0x04, 0x0f, 0x02, 0x19, 0x03, 0x1d, 0x02, 0x15,
        0x04, 0x0b, 0x03, 0x1f, 0x02, 0x0a, 0x03, 0x2e, 0x04, 0x02, 0x05,
        0x07, 0x02, 0x15, 0x04, 0x15, 0x02, 0x2a, 0x03, 0x26, 0x04, 0x0e,
        0x03, 0x35, 0x04, 0x0f, 0x03, 0x1e, 0x02, 0x32, 0x02, 0x05,
      ]);
      final segs = SleepParser.parseNightSleepSegments(
        pl,
        anchor: DateTime(2026, 6, 19),
      );
      // The genuine dayOffset=2 block has 12 pairs totalling 230 min.
      expect(segs, hasLength(12));
      // The stale echo (858 min total) is skipped.
    });

    test('legitimate 14.5 h sleep session is accepted (SP-2)', () {
      // A 14 h 30 min session is rare but physiologically possible
      // (e.g. medical condition, very long nap + night combined).
      // The 14 h clamp would reject this; the 20 h clamp accepts it.
      final pl = Uint8List.fromList([
        0x01, // dayOffset
        0x00, 0x5A, // endMin BE = 90 (01:30)
        // 29 pairs of 30 min each = 870 min = 14.5 h
        ...List.generate(29, (_) => [0x01, 0x1E]).expand((x) => x),
      ]);
      final segs = SleepParser.parseNightSleepSegments(pl, anchor: anchor);
      expect(segs, hasLength(29));
      expect(segs.first.start, DateTime(2026, 6, 19, 11, 0));
      expect(segs.last.duration.inMinutes, 30);
    });

    test('stale-buffer echo alone returns empty (SP-2)', () {
      // If the ONLY block in the payload is the stale echo (>20h),
      // the parser returns empty because every block is skipped.
      final pl = Uint8List.fromList([
        0x02, // dayOffset
        0x00, 0x34, // endMin = 52
        // 40 pairs of 30 min each = 1200 min = 20 h — exceeds clamp
        ...List.generate(40, (_) => [0x01, 0x1E]).expand((x) => x),
      ]);
      final segs = SleepParser.parseNightSleepSegments(pl, anchor: anchor);
      expect(segs, isEmpty);
    });
  });

  group('SleepParser — SP-4 empty/null payload tracing', () {
    final anchor = DateTime(2026, 6, 20);

    test(
      'night: 1-byte payload (only dayOffset) logs warn and returns empty',
      () {
        AppLog.instance.clear();
        final pl = Uint8List.fromList([0x01]); // dayOffset only
        expect(
          SleepParser.parseNightSleepSegments(pl, anchor: anchor),
          isEmpty,
        );
        expect(
          AppLog.instance.entries.any(
            (e) =>
                e.tag == 'sleep' &&
                e.level == LogLevel.warn &&
                e.message.contains('too short') &&
                e.message.contains('len=0'),
          ),
          isTrue,
          reason: 'after stripping dayOffset, length is 0',
        );
      },
    );

    test('night: 2-byte payload logs warn and returns empty', () {
      AppLog.instance.clear();
      final pl = Uint8List.fromList([0x01, 0x00]); // dayOffset + 1 byte
      expect(SleepParser.parseNightSleepSegments(pl, anchor: anchor), isEmpty);
      expect(
        AppLog.instance.entries.any(
          (e) =>
              e.tag == 'sleep' &&
              e.level == LogLevel.warn &&
              e.message.contains('too short') &&
              e.message.contains('len=1'),
        ),
        isTrue,
        reason: 'after stripping dayOffset, length is 1',
      );
    });

    test('night: 3-byte payload (dayOffset + endMin only) is valid empty', () {
      AppLog.instance.clear();
      final pl = Uint8List.fromList([0x01, 0x00, 0x34]); // dayOffset + endMin
      expect(SleepParser.parseNightSleepSegments(pl, anchor: anchor), isEmpty);
      // After stripping dayOffset, the remaining 2 bytes are exactly an
      // endMinute header with no pairs. That is a valid "no data" shape,
      // not a warning condition.
      expect(
        AppLog.instance.entries.any(
          (e) => e.tag == 'sleep' && e.level == LogLevel.warn,
        ),
        isFalse,
        reason: 'endMin-only payload is valid but empty',
      );
    });

    test('lunch: 1-byte payload logs warn and returns empty', () {
      AppLog.instance.clear();
      final pl = Uint8List.fromList([0x01]); // lone byte, not enough for endMin
      expect(SleepParser.parseLunchSleepSegments(pl, anchor: anchor), isEmpty);
      expect(
        AppLog.instance.entries.any(
          (e) =>
              e.tag == 'sleep' &&
              e.level == LogLevel.warn &&
              e.message.contains('too short') &&
              e.message.contains('len=1'),
        ),
        isTrue,
      );
    });

    test('lunch: 2-byte payload (only endMin) logs warn and returns empty', () {
      AppLog.instance.clear();
      final pl = Uint8List.fromList([0x00, 0x34]); // endMin only, no pairs
      expect(SleepParser.parseLunchSleepSegments(pl, anchor: anchor), isEmpty);
      // endMin is read, then inner loop sees no pairs. The outer loop
      // continues but i == 2, so outer while (2+2 <= 2) is false and
      // exits cleanly. No warn here — the block is valid but empty.
      expect(
        AppLog.instance.entries.any(
          (e) => e.tag == 'sleep' && e.level == LogLevel.warn,
        ),
        isFalse,
        reason: 'a valid endMin with no pairs is not a warn condition',
      );
    });

    test(
      'night: 4-byte payload (dayOffset + endMin + no pairs) is valid empty',
      () {
        AppLog.instance.clear();
        final pl = Uint8List.fromList([
          0x01,
          0x00,
          0x34,
        ]); // dayOffset + endMin BE
        expect(
          SleepParser.parseNightSleepSegments(pl, anchor: anchor),
          isEmpty,
        );
        // Same as lunch 2-byte: endMin is read, inner loop has no pairs,
        // outer loop exits. No warn.
        expect(
          AppLog.instance.entries.any(
            (e) => e.tag == 'sleep' && e.level == LogLevel.warn,
          ),
          isFalse,
        );
      },
    );

    test('well-formed payload does not log warn', () {
      AppLog.instance.clear();
      final pl = Uint8List.fromList([
        0x01, // dayOffset
        0x00, 0x34, // endMin BE = 52
        0x01, 0x1E, // light, 30 min
      ]);
      expect(
        SleepParser.parseNightSleepSegments(pl, anchor: anchor),
        hasLength(1),
      );
      expect(
        AppLog.instance.entries.any(
          (e) => e.tag == 'sleep' && e.level == LogLevel.warn,
        ),
        isFalse,
      );
    });
  });

  group('SleepParser — parseLunchSleepSegments (0x3e Ch-B)', () {
    final anchor = DateTime(2026, 6, 20);

    test('parses a single nap block identically to the night shape', () {
      // Older lunch/nap payload has NO dayOffset prefix (only older 0x27
      // does, see PROTOCOL.md §4.4). It is just `u16 BE endMin + pairs`.
      final pl = Uint8List.fromList([
        0x03, 0x0C, // endMin BE 780 (13:00)
        0x01, 0x3C, // light 60 min
      ]);
      final segs = SleepParser.parseLunchSleepSegments(pl, anchor: anchor);
      expect(segs.single.stage, SleepStage.light);
      expect(segs.single.duration.inMinutes, 60);
      expect(segs.single.start, DateTime(2026, 6, 20, 12, 0));
    });

    test('lunch (0x3e) payload has NO dayOffset prefix (regression)', () {
      // Pre-fix, the night parser's heuristic accidentally
      // applied to lunch too. The older lunch wire format is just
      // `(endMin, pairs...)` from byte 0 — no leading dayOffset.
      // If a leading byte were eaten as dayOffset here, we'd
      // read 0x42 0x03 as endMin = 0x4203 = 16899 > 1439 and
      // bail out, returning [].
      final pl = Uint8List.fromList([
        0x03, 0x0C, // endMin BE 780 (13:00) — byte 0 IS endMin high
        0x01, 0x3C, // light 60 min
      ]);
      final segs = SleepParser.parseLunchSleepSegments(pl, anchor: anchor);
      expect(segs, hasLength(1));
      expect(segs.single.start, DateTime(2026, 6, 20, 12, 0));
    });

    test('parses H59MA count-prefixed nap record list with day deltas', () {
      final pl = Uint8List.fromList([
        0x01, // record count
        0x01, // dayDelta: yesterday
        0x06, // blockLen: start/end u16LE + one pair
        0xD0, 0x02, // startMin LE 720 (12:00)
        0x0C, 0x03, // endMin LE 780 (13:00)
        0x01, 0x3C, // light 60 min
      ]);

      final segs = SleepParser.parseLunchSleepSegments(pl, anchor: anchor);
      expect(segs, hasLength(1));
      expect(segs.single.stage, SleepStage.light);
      expect(segs.single.duration.inMinutes, 60);
      expect(segs.single.start, DateTime(2026, 6, 19, 12, 0));
    });

    // -------------------------------------------------------------------------
    // Scoring coverage matrix — see REVIEW §3 of
    // `docs/sleep_scoring_review.md`. The firmware does NOT publish a
    // scoring heuristic (§8.13: "exact stage-value meaning still needs live
    // validation"), so these tests verify the *only* contract we have: the
    // host's [_toStage] mapping + the `_SleepPair`-duration parser. If the
    // firmware later exposes `0x11 sleep summary`'s 100 B header score, the
    // host will read it from `ChannelBParser` directly and these tests will
    // gain an explicit score-field assertion.
    // -------------------------------------------------------------------------

    test('all-awake payload emits segments that would score 0', () {
      // Contract: a session of N minutes of pure `awake` stages has no deep
      // and no rem contribution. A canonical `100 - 5*awakeMin` heuristic
      // (the only formula hinted at by the §2.3 record-list comment "per-
      // record score bytes") would yield `0` for any non-empty awake-only
      // session. The parser should produce N segments all mapped to awake.
      final pl = Uint8List.fromList([
        0x01, // dayOffset
        0x00, 0x78, // endMin BE 120 (02:00 wake)
        0x04, 0x3C, // awake 60
        0x04, 0x3C, // awake 60
      ]);
      final segs = SleepParser.parseNightSleepSegments(pl, anchor: anchor);
      expect(segs, hasLength(2));
      expect(segs.every((s) => s.stage == SleepStage.awake), isTrue);
      expect(segs.fold<int>(0, (acc, s) => acc + s.duration.inMinutes), 120);
      // Mapping invariant: awake=0x04 in canonical Oudmon, score=0x35 in
      // H59MA range. Both stage bytes round-trip through the parser into
      // SleepStage.awake segments (verified above by the .every check on
      // a payload that emits exactly these two bytes — 0x04 and 0x04).
    });

    test('all-deep payload emits segments that would score 100', () {
      // Contract: a session of pure `deep` stages would saturate any
      // "deep% × constant" scoring formula (e.g. `(deep/total) * 100` →
      // 100; `100 - 5*awake + ...` → 100 because awake=0). The parser
      // should map every pair to SleepStage.deep regardless of whether the
      // firmware used canonical 0x02 or H59MA score range 0x05..0x0f.
      final pl = Uint8List.fromList([
        0x01, // dayOffset
        0x01, 0x2C, // endMin BE 300 (05:00)
        0x02, 0xB4, // deep 180
        0x09, 0x1E, // score 0x09 → deep, 30 min
      ]);
      final segs = SleepParser.parseNightSleepSegments(pl, anchor: anchor);
      expect(segs, hasLength(2));
      expect(segs.every((s) => s.stage == SleepStage.deep), isTrue);
      // The two pairs above are 0x02 (canonical Oudmon deep) and 0x09
      // (H59MA score range 0x05..0x0f). Both emit SleepStage.deep — the
      // .every check on the parsed segs is the contract.
    });

    test('mixed-stage payload keeps every stage distinct', () {
      // Contract: the parser preserves stage boundaries. A 4-stage night
      // is rendered as 4 colored bars, not collapsed into a single "asleep"
      // bar (the regression that prompted the 0x05..0xff score-range fix).
      //
      // Stage bytes are picked in the H59MA score range (0x06/0x10/0x20/
      // 0x30) so the parser's stale-echo detector does not mistake a
      // pair byte for a block header. See the SP-2 note in
      // `sleep_parser.dart` line ~300 — `candidateEndMin = (stage << 8) |
      // dur` is the heuristic that misfires when stage bytes ≤ 0x04.
      final pl = Uint8List.fromList([
        0x01, // dayOffset
        0x01, 0x68, // endMin BE 360 (06:00)
        0x06, 0x3C, // deep  60 (H59MA score=0x06 → deep)
        0x10, 0x3C, // light 60 (H59MA score=0x10 → light)
        0x20, 0x3C, // rem   60 (H59MA score=0x20 → rem)
        0x30, 0x3C, // awake 60 (H59MA score=0x30 → awake)
      ]);
      final segs = SleepParser.parseNightSleepSegments(pl, anchor: anchor);
      expect(segs, hasLength(4));
      expect(
        segs.map((s) => s.stage),
        equals([
          SleepStage.deep,
          SleepStage.light,
          SleepStage.rem,
          SleepStage.awake,
        ]),
      );
      expect(segs.fold<int>(0, (acc, s) => acc + s.duration.inMinutes), 240);
    });

    test('nap boundary: 14:00 start is parsed identically to 02:00 start '
        '(no firmware-side time-of-day gating)', () {
      // Contract: the parser does NOT distinguish nap from night based on
      // start time. The firmware §2.3 record reader routes to
      // `sleep_read_nap_record` (cmd 0x3e) or `sleep_read_summary_record`
      // (cmd 0x27) explicitly — the parser is wired to the right path by
      // the *opcode*, not by the wake-up minute-of-day. A 14:00 wake is a
      // valid endMin (840 < 1440), so both opcodes yield the same
      // segment shape.
      const noon = 14 * 60; // 840
      final nap = Uint8List.fromList([
        (noon >> 8) & 0xFF, noon & 0xFF, // endMin BE = 840 (14:00)
        0x01, 0x3C, // light 60
      ]);
      const twoAM = 2 * 60; // 120
      final night = Uint8List.fromList([
        0x01, // dayOffset
        (twoAM >> 8) & 0xFF, twoAM & 0xFF, // endMin BE = 120 (02:00)
        0x01, 0x3C, // light 60
      ]);
      final napSegs = SleepParser.parseLunchSleepSegments(nap, anchor: anchor);
      final nightSegs = SleepParser.parseNightSleepSegments(
        night,
        anchor: anchor,
      );
      // Both should produce 1 light segment of 60 min — same shape.
      expect(napSegs, hasLength(1));
      expect(nightSegs, hasLength(1));
      expect(napSegs.single.stage, SleepStage.light);
      expect(nightSegs.single.stage, SleepStage.light);
      expect(napSegs.single.duration, nightSegs.single.duration);
      // The two anchors differ in start timestamp: nap starts at 13:00 the
      // same day, night starts at 01:00 the same day (no wrap).
      expect(napSegs.single.start, DateTime(2026, 6, 20, 13));
      expect(nightSegs.single.start, DateTime(2026, 6, 20, 1));
    });

    test(
      'gap in stream (signal loss) is exposed as two sessions, not merged',
      () {
        // Contract: the parser does not synthesize fill-in segments across
        // a gap — the segment list just ends. The §3 host code
        // (`SleepSessionSummary.fromSegments`) is the layer that splits
        // sessions across >90 min gaps.
        //
        // We exercise the parser's contract: a payload with two blocks
        // separated by a `(0,0)` terminator (the §2.0 wire-format marker
        // for "previous block complete") is emitted as two distinct
        // segment *groups* in the same list. The gap is implicit (the
        // blocks just describe two non-overlapping windows) — the host
        // session-summary layer is what notices the time gap.
        //
        //   Block 1: endMin = 120 (02:00), light 30
        //   Block 2: endMin = 540 (09:00), deep 60
        final pl = Uint8List.fromList([
          0x01, // dayOffset
          0x00, 0x78, // endMin BE 120 (02:00)
          0x01, 0x1E, // light 30
          0x00, 0x00, // terminator
          0x02, 0x1C, // endMin BE 540 (09:00)
          0x06, 0x3C, // deep 60 (H59MA score byte — see SP-2)
        ]);
        final segs = SleepParser.parseNightSleepSegments(pl, anchor: anchor);
        expect(segs, hasLength(2));
        expect(segs[0].stage, SleepStage.light);
        expect(segs[0].duration.inMinutes, 30);
        expect(segs[1].stage, SleepStage.deep);
        expect(segs[1].duration.inMinutes, 60);
        // The session summary layer should split this into two sessions
        // because the block-1 wake (02:30) → block-2 start (08:00) gap
        // is 5.5 h = 330 min, well past the 90-minute default threshold.
        final sessions = SleepSessionSummary.fromSegments(segs);
        expect(sessions, hasLength(2));
      },
    );

    test('truncated last record (odd trailing byte) does not crash', () {
      // Contract: the parser handles a payload whose last pair has only
      // one byte — i.e. the BLE link lost the second byte of a (stage,
      // durMin) pair. The chain walker must bail out cleanly and emit
      // every well-formed segment before the truncation.
      final pl = Uint8List.fromList([
        0x01, // dayOffset
        0x00, 0x78, // endMin BE 120 (02:00)
        0x01, 0x1E, // light 30
        0x02, 0x3C, // deep 60
        0x03, // truncated: missing durMin byte
      ]);
      AppLog.instance.clear();
      final segs = SleepParser.parseNightSleepSegments(pl, anchor: anchor);
      // Both complete pairs survive; the lone trailing byte is ignored.
      expect(segs, hasLength(2));
      expect(segs[0].stage, SleepStage.light);
      expect(segs[0].duration.inMinutes, 30);
      expect(segs[1].stage, SleepStage.deep);
      expect(segs[1].duration.inMinutes, 60);
      // The SP-1 warn must NOT fire for a well-formed block — only the
      // unparseable trailing byte is silently dropped.
      expect(
        AppLog.instance.entries.any(
          (e) => e.tag == 'sleep' && e.level == LogLevel.warn,
        ),
        isFalse,
        reason: 'truncated trailing byte is not a warn-level corruption',
      );
    });

    test('REM detection — 0x03 maps to rem regardless of time-of-day', () {
      // Contract: the parser does NOT gate REM on a time-of-day window.
      // The firmware §2.3 record writer does not document such a window,
      // and the only time the host sees is the wake-up minute-of-day
      // (start time is derived). A nap ending at 14:30 with a 0x03 pair
      // is just as much REM as a night ending at 06:00 with a 0x03 pair.
      for (final endMin in [120, 360, 540, 840]) {
        final pl = Uint8List.fromList([
          (endMin >> 8) & 0xFF,
          endMin & 0xFF,
          0x03,
          0x1E, // rem 30
        ]);
        final segs = SleepParser.parseLunchSleepSegments(pl, anchor: anchor);
        expect(
          segs.single.stage,
          SleepStage.rem,
          reason: 'endMin=$endMin should still classify 0x03 as rem',
        );
        expect(segs.single.duration.inMinutes, 30);
      }
      // The loop above already verifies that 0x03 round-trips through
      // parseLunchSleepSegments into SleepStage.rem at four different
      // wake-up minutes (02:00, 06:00, 09:00, 14:00) — that is the
      // public host contract. The internal SleepParser.stageFor()
      // helper returns the raw `typeByte & 0xFF` (not a stage) and is
      // not exercised here.
    });

    test('returns an empty list for an empty payload', () {
      AppLog.instance.clear();
      expect(
        SleepParser.parseLunchSleepSegments(Uint8List(0), anchor: anchor),
        isEmpty,
      );
      // Empty lunch payload is "no data" — logged at warn because
      // _parseChained sees length 0 < 4 (SP-4).
      expect(
        AppLog.instance.entries.any(
          (e) =>
              e.tag == 'sleep' &&
              e.level == LogLevel.warn &&
              e.message.contains('too short'),
        ),
        isTrue,
      );
    });
  });
}
