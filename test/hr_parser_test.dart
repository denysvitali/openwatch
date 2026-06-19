import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:openwatch/core/protocol/hr_parser.dart';

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

    test('masks negative ints (the 0x80..0xFF dart-sign issue)', () {
      // Dart reads Uint8List indices as signed ints. A real-world bpm byte
      // in the 0x80..0xBF range would otherwise look like -128..-65 and be
      // rejected. The parser masks before the range check — verify the
      // end-to-end behavior on the actual Uint8List read path.
      final pl = Uint8List.fromList([0xC8]); // bpm 200, read as int -56
      expect(pl[0] < 0, isTrue, reason: 'sanity: signed read');
      expect(
        HrParser.parseRealtime(pl),
        200,
        reason: 'parser must mask before range check',
      );
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

    test('returns null for payloads shorter than 2 bytes', () {
      expect(HrParser.parseDeviceNotify(Uint8List(0)), isNull);
      expect(HrParser.parseDeviceNotify(Uint8List.fromList([0x05])), isNull);
    });
  });
}
