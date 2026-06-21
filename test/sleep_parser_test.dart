import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:openwatch/core/protocol/sleep_parser.dart';

void main() {
  group('SleepParser — parseNightSleepSegments (0x27 Ch-B)', () {
    final anchor = DateTime(2026, 6, 20);

    test('parses a single block of 3 (stage, durMin) pairs', () {
      // Block: u16 LE endMin = 7:30 = 450 = 0x01C2
      // Pairs: (light=1, 30min), (deep=2, 90min), (rem=3, 60min)
      // Total = 180 min ⇒ startMin = 450 - 180 = 270 = 04:30
      final pl = Uint8List.fromList([
        0xC2, 0x01, // endMinOfDay LE
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
      // the previous test. The parser must detect the bad alignment
      // and skip exactly one byte.
      final pl = Uint8List.fromList([
        0x00, // dayOffset
        0xC2, 0x01, // endMinOfDay LE 450
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
        0xC2, 0x01, // endMin 450
        0x01, 0x1E, // light 30
        0x02, 0x5A, // deep 90
        0x00, 0x00, // terminator
        0xF0, 0x00, // endMin 240 = 04:00
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

    test('maps H59MA-style score bytes (0x05..0x0f) to SleepStage.deep', () {
      // The H59MA v13 firmware emits stage bytes in the range
      // 0x05..0xff instead of the canonical Oudmon 0x01..0x04
      // (see `firmwares/GHIDRA_DECOMPILATION.md` §2.3). Previously
      // these collapsed every segment to `awake`, painting the
      // sleep chart solid red. The mapping now interprets the byte
      // as a coarse sleep-quality score.
      final pl = Uint8List.fromList([
        0x2A, 0x00, // endMin = 42
        0x09, 0x14, // score 9 → deep, 20 min
      ]);
      final segs = SleepParser.parseNightSleepSegments(pl, anchor: anchor);
      expect(segs.single.stage, SleepStage.deep);
      expect(segs.single.duration.inMinutes, 20);
    });

    test('H59MA score range 0x10..0x1f maps to SleepStage.light', () {
      final pl = Uint8List.fromList([
        0x2A, 0x00,
        0x15, 0x05, // score 0x15=21 → light, 5 min
      ]);
      final segs = SleepParser.parseNightSleepSegments(pl, anchor: anchor);
      expect(segs.single.stage, SleepStage.light);
    });

    test('H59MA score range 0x20..0x2f maps to SleepStage.rem', () {
      final pl = Uint8List.fromList([
        0x2A, 0x00,
        0x25, 0x05, // score 0x25=37 → rem, 5 min
      ]);
      final segs = SleepParser.parseNightSleepSegments(pl, anchor: anchor);
      expect(segs.single.stage, SleepStage.rem);
    });

    test('H59MA score 0x30+ falls through to SleepStage.awake', () {
      // The high end of the range is genuinely "lots of movement"
      // and stays awake — only the low/mid ranges got demoted.
      final pl = Uint8List.fromList([
        0x2A, 0x00,
        0x35, 0x05, // score 0x35=53 → awake, 5 min
      ]);
      final segs = SleepParser.parseNightSleepSegments(pl, anchor: anchor);
      expect(segs.single.stage, SleepStage.awake);
    });

    test('0x00 stays mapped to SleepStage.awake (no-data sentinel)', () {
      final pl = Uint8List.fromList([
        0x2A, 0x00,
        0x00, 0x05, // 0x00 → awake, 5 min
      ]);
      final segs = SleepParser.parseNightSleepSegments(pl, anchor: anchor);
      expect(segs.single.stage, SleepStage.awake);
    });
  });

  group('SleepParser — parseLunchSleepSegments (0x3e Ch-B)', () {
    final anchor = DateTime(2026, 6, 20);

    test('parses a single nap block identically to the night shape', () {
      // Lunch/nap is wire-compatible with night — same parser.
      final pl = Uint8List.fromList([
        0x0C, 0x03, // endMin 780 (13:00)
        0x01, 0x3C, // light 60 min
      ]);
      final segs = SleepParser.parseLunchSleepSegments(pl, anchor: anchor);
      expect(segs.single.stage, SleepStage.light);
      expect(segs.single.duration.inMinutes, 60);
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
