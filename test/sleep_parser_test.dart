import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:openwatch/core/protocol/sleep_parser.dart';

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
      expect(
        SleepParser.parseNightSleepSegments(Uint8List(0), anchor: anchor),
        isEmpty,
      );
    });

    test('returns an empty list for a payload shorter than 4 bytes', () {
      expect(
        SleepParser.parseNightSleepSegments(
          Uint8List.fromList([0x00, 0x00]),
          anchor: anchor,
        ),
        isEmpty,
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

    test('empty pair block after endMin does not misalign on trailing bytes (SP-1)', () {
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
    });

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

    test('empty pair block followed by terminator skips block and continues (SP-1)', () {
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
    });

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
      // Live H59MA v13 capture: the response for dayOffset=2 contained
      // the previous dayOffset=1 record appended (stale buffer). The
      // concatenated block totals 858 min (14.3 h) and would otherwise
      // be filed as a single sleep session, producing a day with >24 h
      // of sleep when combined with the real dayOffset=1 record.
      final pl = Uint8List.fromList([
        0x02, // dayOffset = 2
        0x01, 0x18, // endMin BE = 280 (04:40)
        // Genuine dayOffset=2 block (12 pairs, 230 min):
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
      expect(segs, isEmpty);
    });
  });

  group('SleepParser — parseLunchSleepSegments (0x3e Ch-B)', () {
    final anchor = DateTime(2026, 6, 20);

    test('parses a single nap block identically to the night shape', () {
      // Lunch/nap payload has NO dayOffset prefix (only 0x27 does,
      // see PROTOCOL.md §4.4). It is just `u16 BE endMin + pairs`.
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
      // applied to lunch too. The lunch wire format is just
      // `(endMin, pairs…)` from byte 0 — no leading dayOffset.
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

    test('returns an empty list for an empty payload', () {
      expect(
        SleepParser.parseLunchSleepSegments(Uint8List(0), anchor: anchor),
        isEmpty,
      );
    });
  });
}
