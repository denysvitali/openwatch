import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:openwatch/core/protocol/activity_parser.dart';

void main() {
  group('ActivityParser.parseHourlyBody', () {
    test('decodes 24 max/min SpO2 pairs', () {
      final body = Uint8List(48);
      body[0] = 98; // hour 0 max
      body[1] = 94; // hour 0 min
      body[2] = 97;
      body[3] = 93;
      body[46] = 96; // hour 23 max
      body[47] = 92;

      final samples = ActivityParser.parseHourlyBody(body);
      expect(samples, hasLength(24));
      expect(samples[0].max, 98);
      expect(samples[0].min, 94);
      expect(samples[1].max, 97);
      expect(samples[1].min, 93);
      expect(samples[23].max, 96);
      expect(samples[23].min, 92);
      expect(samples[2].hasData, isFalse);
    });

    test('normalises 0xFF holes via parsePayload', () {
      final body = List<int>.filled(48, 0x00);
      body[0] = 0xff;
      body[1] = 0xff;
      body[2] = 99;
      body[3] = 95;
      final payload = Uint8List.fromList([0x00, ...body]);
      final entries = ActivityParser.parsePayload(payload);
      expect(entries, hasLength(1));
      expect(entries.first.samples[0].max, 0);
      expect(entries.first.samples[0].min, 0);
      expect(entries.first.samples[1].max, 99);
      expect(entries.first.samples[1].min, 95);
    });
  });

  group('ActivityParser.dayRange', () {
    test('returns nulls when no hours have data', () {
      final range = ActivityParser.dayRange(
        ActivityParser.parseHourlyBody(Uint8List(48)),
      );
      expect(range.max, isNull);
      expect(range.min, isNull);
    });

    test('aggregates max/min across hours', () {
      final body = Uint8List(48);
      body[0] = 98;
      body[1] = 94;
      body[4] = 100;
      body[5] = 91;
      final range = ActivityParser.dayRange(
        ActivityParser.parseHourlyBody(body),
      );
      expect(range.max, 100);
      expect(range.min, 91);
    });
  });

  group('ActivityParser.parsePayload', () {
    test('parses multiple day offsets without treating 0 as terminator', () {
      final body = Uint8List(48)..[0] = 97;
      final payload = Uint8List.fromList([0x01, ...body, 0x00, ...body]);
      final entries = ActivityParser.parsePayload(payload);
      expect(entries.map((e) => e.dayOffset), [1, 0]);
    });
  });
}
