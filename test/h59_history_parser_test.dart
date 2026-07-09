import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:openwatch/core/protocol/h59_history_parser.dart';
import 'package:openwatch/core/protocol/sleep_parser.dart';

void main() {
  test('decodes a wrapped 0x11 summary and preserves its pairs', () {
    final body = Uint8List(100);
    body[0x0e] = 1200 & 0xff;
    body[0x0f] = 1200 >> 8;
    body[0x10] = 60;
    body[0x13] = 2;
    body[0x14] = 2;
    body[0x15] = 5;
    body[0x3c] = 60;
    body[0x3d] = 60;
    final parsed = H59HistoryParser.parseSummary(
      Uint8List.fromList([1, ...body]),
    );
    expect(parsed, isNotNull);
    expect(parsed!.dayOffset, 1);
    expect(parsed.startMinute, 1200);
    expect(parsed.endMinute, 60);
    expect(parsed.segments, hasLength(2));
    expect(parsed.segments[0].stage, SleepStage.deep);
    expect(parsed.segments[1].stage, SleepStage.light);

    final anchored = H59HistoryParser.anchorSummary(
      parsed,
      DateTime(2026, 7, 10),
    );
    expect(anchored.segments.first.start, DateTime(2026, 7, 9, 20));
  });

  test('decodes 0x12 hourly detail and ignores empty 0xffff slots', () {
    final body = Uint8List(288);
    body[0] = 100;
    body[4] = 50;
    body[6] = 30;
    body[8] = 12;
    body[12] = 0xff;
    body[13] = 0xff;
    final parsed = H59HistoryParser.parseDetail(
      Uint8List.fromList([2, ...body]),
    );
    expect(parsed, isNotNull);
    expect(parsed!.dayOffset, 2);
    expect(parsed.steps, 100);
    expect(parsed.calories, 50);
    expect(parsed.distanceMeters, 300);
    expect(parsed.durationSeconds, 12);
  });

  test('accepts an empty 0x11 summary as a valid response', () {
    final parsed = H59HistoryParser.parseSummary(Uint8List(101));
    expect(parsed, isNotNull);
    expect(parsed!.segments, isEmpty);
  });

  test('rejects compact NAK and truncated H59 records', () {
    expect(H59HistoryParser.parseSummary(Uint8List(1)), isNull);
    expect(H59HistoryParser.parseDetail(Uint8List.fromList([0, 1, 2])), isNull);
  });
}
