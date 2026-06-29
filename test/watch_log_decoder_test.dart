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

    test('decodes a multi-line log packet across channels', () {
      // A realistic capture: Ch-A battery reply, Ch-A heart-rate setting,
      // Ch-B nap sleep. All three frames stitched into one log blob.
      final battery = Codec.buildChannelA(OpA.battery, [82]);
      final hrSetting = Codec.buildChannelA(OpA.heartRateSetting, [
        0x01,
        0x01,
        5,
      ]);
      final nap = Codec.buildChannelB(OpB.sleepLunchNew, [
        // day offset = 0, segments end at 13:30 + 5min light + 1min awake...
        0,
        0x06,
        0x6a, // 06:30 cutoff
        1,
        1, // awake
        0x03,
        0x04, // then resume — header-style: 13:30 endMin (0x051A)
        ..._bytes('051a-03-04'),
      ]);
      final log = [
        _lineAt('08:01:12.345', _chA, battery),
        _lineAt('08:01:12.812', _chA, hrSetting),
        _lineAt('08:01:13.044', _chB, nap),
      ].join('\n');

      final report = const WatchLogDecoder().decodeNrfConnectLog(log);

      expect(report.frames, hasLength(3));
      expect(report.channelCounts, {'channelA': 2, 'channelB': 1});
      expect(report.validFrameCount, 3);
      expect(report.invalidFrameCount, 0);
      // A single nRF log blob feeds the assembly state, but no series
      // spans all three frames — explicit assert so the state-machine
      // can't quietly mis-accumulate.
      expect(report.heartRateSeries, isEmpty);
      expect(report.pressureSeries, isEmpty);
      expect(report.hrvSeries, isEmpty);
    });

    test('extracts the nRF Connect time-of-day timestamp from each line', () {
      final frame = Codec.buildChannelA(OpA.battery, [55]);
      final log = _lineAt('13:45:09.777', _chA, frame);

      final report = const WatchLogDecoder().decodeNrfConnectLog(log);

      expect(report.frames.single.timestamp, '13:45:09.777');
      expect(report.frames.single.lineNo, 1);
    });

    test('maps opcode to a label topic and surfaces invalid frame as a '
        'safe-degrade variant', () {
      // Valid Channel-A reply: opcode label = battery.
      final ok = Codec.buildChannelA(OpA.battery, [91]);
      // Header-only fragment of a 6-byte Channel-B frame → invalid magic
      // check; decoder must still produce a frame so it can be logged
      // rather than silently dropped.
      final truncated = Codec.buildChannelB(0x42, [
        1,
        2,
        3,
        4,
        5,
        6,
      ]).sublist(0, 4);

      final report = const WatchLogDecoder().decodeNrfConnectLog(
        '${_lineAt('09:00:00.000', _chA, ok)}\n'
        '${_lineAt('09:00:00.250', _chB, truncated)}',
      );

      expect(report.frames, hasLength(2));
      final a = report.frames[0];
      final b = report.frames[1];

      // Channel-A: label == opcode topic ("battery"), valid == true,
      // invalidFrames does NOT include it.
      expect(a.channel, WatchLogChannel.channelA);
      expect(a.valid, isTrue);
      expect(a.details['label'], 'battery');

      // Channel-B: CRC/length decoder rejects the truncated frame;
      // the result is still modeled (channelCounts counts it) so the
      // caller can decide what to do — that's the safe-degrade path.
      expect(b.channel, WatchLogChannel.channelB);
      expect(b.valid, isFalse);
      expect(b.title, contains('Channel B invalid frame'));
      expect(report.invalidFrames.single, same(b));
      expect(report.channelCounts, {'channelA': 1, 'channelB': 1});
    });

    test('survives a truncated Channel-A packet (not 16 bytes)', () {
      // Real captures occasionally hand the parser a write-in-flight
      // glitch (rxCharacteristicChanged arrives mid-MTU). The decoder
      // must NOT throw — it must log a frame and continue.
      final truncated = [0x03, 0x37, 0x00]; // 3 bytes
      final full = Codec.buildChannelA(OpA.battery, [60]);

      final report = const WatchLogDecoder().decodeNrfConnectLog(
        '${_lineAt('10:11:12.000', _chA, truncated)}\n'
        '${_lineAt('10:11:12.500', _chA, full)}',
      );

      expect(report.frames, hasLength(2));
      final bad = report.frames[0];
      final good = report.frames[1];

      expect(bad.valid, isFalse);
      expect(bad.title, contains('Channel A invalid length 3'));
      // noisy frame is still counted in the channel histogram so
      // diagnostics can correlate dropped frames against transport glitches
      expect(report.channelCounts, {'channelA': 2});

      expect(good.valid, isTrue);
      expect(good.title, contains('battery'));
      expect(report.validFrameCount, 1);
      expect(report.invalidFrameCount, 1);
    });

    test('ignores nRF log lines without a notification line', () {
      // The capture file may contain logcat-style noise (no
      // "Notification received from") that the regex must skip without
      // adding to frameCount.
      final frame = Codec.buildChannelA(OpA.battery, [42]);
      final log = [
        'D 10:00:00.000 BluetoothGatt characteristic read failed',
        'W 10:00:00.250 something else',
        _lineAt('10:00:01.000', _chA, frame),
        '', // blank line — must also be a no-op
      ].join('\n');

      final report = const WatchLogDecoder().decodeNrfConnectLog(log);

      expect(report.frames, hasLength(1));
      expect(report.channelCounts, {'channelA': 1});
    });

    test('toJson honours includeFrames=false for lightweight summaries', () {
      final frame = Codec.buildChannelA(OpA.battery, [77]);
      final report = const WatchLogDecoder().decodeNrfConnectLog(
        _line(_chA, frame),
      );

      final summary = jsonEncode(report.toJson(includeFrames: false));
      final full = jsonEncode(report.toJson());

      expect(summary, isNot(contains('"frames"')));
      expect(full, contains('"frames"'));
      // The numeric shape is preserved across both modes.
      expect(summary, contains('"frameCount":1'));
      expect(summary, contains('"validFrameCount":1'));
      expect(summary, contains('"heartRateSeries"'));
    });

    test(
      'decodeHex parses a single Channel-A frame and skips the timestamp',
      () {
        // decodeHex is the entrypoint used by tools/bin and any caller that
        // has raw bytes but no nRF line metadata — timestamp must be null.
        final frame = Codec.buildChannelA(OpA.battery, [88]);

        final decoded = const WatchLogDecoder().decodeHex(
          frame.map((b) => b.toRadixString(16).padLeft(2, '0')).join('-'),
        );

        expect(decoded.valid, isTrue);
        expect(decoded.timestamp, isNull);
        expect(decoded.channel, WatchLogChannel.channelA);
        expect(decoded.details['label'], 'battery');
        expect(decoded.details['batteryPercent'], 88);
      },
    );

    test('handles ASCII-non-printable payload bytes without crashing', () {
      // A Channel-A 0x73 deviceNotify frame whose payload contains 0x00
      // and 0xFF interspersed (the decoder's label machinery must use
      // hex, not String.fromCharCodes). Build a frame with all bytes
      // covering the "unprintable" range.
      final payload = List<int>.generate(14, (i) => i); // 0x00..0x0d
      final frame = Codec.buildChannelA(OpA.deviceNotify, payload);

      final report = const WatchLogDecoder().decodeNrfConnectLog(
        _lineAt('12:34:56.789', _chA, frame),
      );

      final decoded = report.frames.single;
      expect(decoded.valid, isTrue);
      expect(decoded.channel, WatchLogChannel.channelA);
      // 0x73 has a fixed-decoder summary: payload is rendered as
      // compactHex, so null/control bytes never enter a string path that
      // could throw or corrupt surrounding text.
      expect(decoded.title, contains('A 0x73 device notify payload='));
      expect(decoded.title, isNot(contains('\n')));
      // Hex digits only — guard against any future change that would
      // accidentally pretty-print raw bytes through utf8.decode.
      final hexPart = decoded.title.split('payload=').last;
      expect(
        RegExp(r'^[0-9a-f-]+$').hasMatch(hexPart),
        isTrue,
        reason: 'payload must be compact-hex only, got "$hexPart"',
      );
    });
  });
}

String _line(String uuid, List<int> bytes) =>
    'I\t22:20:05.000\tNotification received from $uuid, value: (0x) '
    '${bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join('-')}';

String _lineAt(String time, String uuid, List<int> bytes) =>
    'I\t$time\tNotification received from $uuid, value: (0x) '
    '${bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join('-')}';

List<int> _bytes(String hex) => [
  for (final match in RegExp(r'[0-9A-Fa-f]{2}').allMatches(hex))
    int.parse(match.group(0)!, radix: 16),
];
