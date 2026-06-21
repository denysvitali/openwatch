import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:openwatch/core/protocol/codec.dart';
import 'package:openwatch/core/protocol/opcodes.dart';
import 'package:openwatch/core/protocol/watch_log_decoder.dart';

const _chA = '6e400003-b5a3-f393-e0a9-e50e24dcca9e';
const _chB = 'de5bf729-d711-4e47-af26-65e3012a5dc7';

void main() {
  group('WatchLogDecoder', () {
    test(
      'extracts nRF Connect Channel A notifications and validates checksum',
      () {
        final frame = Codec.buildChannelA(OpA.battery, [74]);
        final log = _line(_chA, frame);

        final report = const WatchLogDecoder().decodeNrfConnectLog(log);

        expect(report.frames, hasLength(1));
        expect(report.frames.single.valid, isTrue);
        expect(report.frames.single.title, contains('battery 74%'));
        expect(report.channelCounts, {'channelA': 1});
      },
    );

    test('decodes firmware-shaped 0x15 history header and chunks', () {
      final header = Codec.buildChannelA(OpA.readHeartRate, [0x00, 0x03, 0x05]);
      final chunk1 = Codec.buildChannelA(OpA.readHeartRate, [
        0x01,
        0x08,
        0xd8,
        0x35,
        0x6a,
        65,
        66,
        67,
        68,
        69,
        0,
        0,
        0,
        0,
      ]);
      final chunk2 = Codec.buildChannelA(OpA.readHeartRate, [
        0x02,
        70,
        71,
        72,
        73,
        74,
        75,
        76,
        77,
        78,
        79,
        80,
        81,
        82,
      ]);
      final log = [
        _line(_chA, header),
        _line(_chA, chunk1),
        _line(_chA, chunk2),
      ].join('\n');

      final report = const WatchLogDecoder().decodeNrfConnectLog(log);

      expect(report.heartRateSeries, hasLength(1));
      final series = report.heartRateSeries.single;
      expect(series.expectedChunks, 2);
      expect(series.receivedChunks, 2);
      expect(series.sampleIntervalMinutes, 5);
      expect(series.samples, 18);
      expect(series.minBpm, 65);
      expect(series.maxBpm, 82);
    });

    test('validates and summarizes Channel B sleep frames from nRF log', () {
      const raw =
          'BC-27-37-00-BF-D6-01-00-34-75-05-0E-02-02-13-03-10-04-'
          '0E-02-22-04-0F-02-19-03-1D-02-15-04-0B-03-1F-02-0A-'
          '03-2E-04-02-05-07-02-15-04-15-02-2A-03-26-04-0E-03-'
          '35-04-0F-03-1E-02-32-02-05';
      final report = const WatchLogDecoder().decodeNrfConnectLog(
        _line(_chB, _bytes(raw)),
      );

      expect(report.frames.single.valid, isTrue);
      expect(report.frames.single.title, contains('night sleep'));
      expect(report.frames.single.details['dayOffset'], 1);
      expect(report.frames.single.details['segmentCount'], greaterThan(0));
    });

    test('summarizes Channel B activity records and supports JSON output', () {
      final body = List<int>.filled(48, 0);
      body[2] = 100;
      body[8] = 50;
      body[11] = 80;
      final frame = Codec.buildChannelB(OpB.activitySummary, [1, ...body]);

      final report = const WatchLogDecoder().decodeNrfConnectLog(
        _line(_chB, frame),
      );
      final json = report.toJson();

      expect(report.frames.single.title, contains('activity records=1'));
      final encoded = jsonEncode(json);
      expect(encoded, contains('"steps":100'));
      expect(encoded, contains('"calories":50'));
      expect(encoded, contains('"distanceMeters":80'));
    });
  });
}

String _line(String uuid, List<int> bytes) =>
    'I\t22:20:05.000\tNotification received from $uuid, value: (0x) '
    '${bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join('-')}';

List<int> _bytes(String hex) => [
  for (final match in RegExp(r'[0-9A-Fa-f]{2}').allMatches(hex))
    int.parse(match.group(0)!, radix: 16),
];
