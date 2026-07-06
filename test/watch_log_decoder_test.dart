import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:openwatch/core/protocol/codec.dart';
import 'package:openwatch/core/protocol/opcodes.dart';
import 'package:openwatch/core/protocol/watch_log_decoder.dart';

const _chA = '6e400003-b5a3-f393-e0a9-e50e24dcca9e';
const _chB = 'de5bf729-d711-4e47-af26-65e3012a5dc7';
const _fee7 = '0000fea2-0000-1000-8000-00805f9b34fb';

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

    test('summarizes H59MA sleep summary frames opaquely', () {
      final frame = Codec.buildChannelB(OpB.h59SleepSummary, [
        0x02,
        ...List<int>.generate(100, (i) => i & 0xff),
      ]);

      final report = const WatchLogDecoder().decodeNrfConnectLog(
        _line(_chB, frame),
      );
      final decoded = report.frames.single;

      expect(decoded.valid, isTrue);
      expect(decoded.title, contains('H59 sleep summary dayOffset=2'));
      expect(decoded.title, contains('bytes=100'));
      expect(decoded.details['label'], 'h59SleepSummary');
      expect(decoded.details['dayOffset'], 2);
      expect(decoded.details['summaryBytes'], 100);
    });

    test('summarizes H59MA sleep detail frames opaquely', () {
      final frame = Codec.buildChannelB(OpB.h59SleepDetail, [
        0x01,
        ...List<int>.generate(288, (i) => i & 0xff),
      ]);

      final report = const WatchLogDecoder().decodeNrfConnectLog(
        _line(_chB, frame),
      );
      final decoded = report.frames.single;

      expect(decoded.valid, isTrue);
      expect(decoded.title, contains('H59 sleep detail dayOffset=1'));
      expect(decoded.title, contains('bytes=288'));
      expect(decoded.details['label'], 'h59SleepDetail');
      expect(decoded.details['dayOffset'], 1);
      expect(decoded.details['detailBytes'], 288);
    });

    test('summarizes H59MA sleep detail compact status frames', () {
      final frame = Codec.buildChannelB(OpB.h59SleepDetail, [0x02]);

      final report = const WatchLogDecoder().decodeNrfConnectLog(
        _line(_chB, frame),
      );
      final decoded = report.frames.single;

      expect(decoded.valid, isTrue);
      expect(decoded.title, contains('H59 sleep detail compactStatus=0x02'));
      expect(decoded.details['label'], 'h59SleepDetail');
      expect(decoded.details['compactStatusCode'], 2);
      expect(decoded.details['firmwareBehavior'], 'compact-status');
      expect(decoded.details['payloadBytes'], 1);
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

    test('decodes H59MA file-table list response TLVs', () {
      final frame = Codec.buildChannelB(OpB.h59FileListResponse, [
        0x02,
        // FUN_0083105a emits [recordLen, recordType, fieldTLVs...].
        // Field lengths include the length/id bytes.
        0x09, 0x04, 0x03, 0x01, 0xAA, 0x04, 0x02, 0xBB, 0xCC,
        0x05, 0x01, 0x03, 0x07, 0x10,
      ]);

      final report = const WatchLogDecoder().decodeNrfConnectLog(
        _line(_chB, frame),
      );
      final decoded = report.frames.single;
      expect(decoded.valid, isTrue);
      expect(decoded.title, contains('H59 file list records=2'));
      expect(decoded.title, contains('parsed=2'));
      expect(decoded.details['label'], 'h59FileListResponse');
      expect(decoded.details['fileRecordCount'], 2);
      expect(decoded.details['fileParsedRecordCount'], 2);
      expect(decoded.details['fileRecordBytes'], 14);
      expect(decoded.details['fileMalformed'], isFalse);

      final records = decoded.details['fileRecords']! as List<Object?>;
      final first = records[0]! as Map<String, Object?>;
      expect(first['length'], 9);
      expect(first['recordType'], '0x04');
      expect(first['fieldCount'], 2);

      final firstFields = first['fields']! as List<Object?>;
      final field0 = firstFields[0]! as Map<String, Object?>;
      expect(field0['length'], 3);
      expect(field0['fieldId'], '0x01');
      expect(field0['value'], 'aa');
    });

    test('summarizes H59MA file metadata and chunk frames', () {
      final metadata = Codec.buildChannelB(OpB.h59FileMetadata, [
        0x00,
        0x03,
        0x00,
        0x04,
        0x01,
        0x11,
      ]);
      final missing = Codec.buildChannelB(OpB.h59FileMetadata, [
        0x01,
        0x07,
        0x78,
        0x56,
        0x34,
        0x12,
      ]);
      final chunk = Codec.buildChannelB(OpB.h59FileChunk, [
        0x02,
        0x00,
        0xAA,
        0xBB,
        0xCC,
      ]);

      final report = const WatchLogDecoder().decodeNrfConnectLog(
        [
          _line(_chB, metadata),
          _line(_chB, missing),
          _line(_chB, chunk),
        ].join('\n'),
      );

      final metadataFrame = report.frames[0];
      expect(metadataFrame.title, contains('file metadata ok chunks=3'));
      expect(metadataFrame.details['label'], 'h59FileMetadata');
      expect(metadataFrame.details['fileStatus'], '0x00');
      expect(metadataFrame.details['chunkCount'], 3);
      expect(metadataFrame.details['metadataByte5'], '0x11');

      final missingFrame = report.frames[1];
      expect(missingFrame.title, contains('file metadata not-found'));
      expect(missingFrame.details['selector'], '0x07');
      expect(missingFrame.details['recordId'], '0x12345678');

      final chunkFrame = report.frames[2];
      expect(chunkFrame.title, contains('file chunk index=2 bytes=3'));
      expect(chunkFrame.details['label'], 'h59FileChunk');
      expect(chunkFrame.details['chunkIndex'], 2);
      expect(chunkFrame.details['chunkReserved'], '0x00');
      expect(chunkFrame.details['chunkDataBytes'], 3);
      expect(chunkFrame.details['chunkMalformed'], isFalse);
    });

    test('labels H59MA Channel-B no-op placeholders', () {
      final frames = [
        for (final cmd in [
          OpB.h59Noop13,
          OpB.h59Noop29,
          OpB.h59Noop3b,
          OpB.h59Noop47,
          OpB.h59Noop4b,
        ])
          Codec.buildChannelB(cmd, [0x5A]),
      ];

      final report = const WatchLogDecoder().decodeNrfConnectLog(
        frames.map((f) => _line(_chB, f)).join('\n'),
      );

      expect(report.frames, hasLength(5));
      for (final frame in report.frames) {
        expect(frame.title, contains('no-op payloadBytes=1'));
        expect(frame.details['label'], startsWith('h59Noop'));
        expect(frame.details['firmwareBehavior'], 'no-op');
      }
    });

    test('labels H59MA Channel-B cleanup bypass commands', () {
      final frames = [
        Codec.buildChannelB(OpB.h59CleanupBypass10, [0x5A]),
        Codec.buildChannelB(OpB.h59CleanupBypass46, [0x5A]),
      ];

      final report = const WatchLogDecoder().decodeNrfConnectLog(
        frames.map((f) => _line(_chB, f)).join('\n'),
      );

      expect(report.frames, hasLength(2));
      expect(report.frames[0].title, contains('h59CleanupBypass10'));
      expect(report.frames[0].details['label'], 'h59CleanupBypass10');
      expect(report.frames[1].title, contains('h59CleanupBypass46'));
      expect(report.frames[1].details['label'], 'h59CleanupBypass46');
    });

    test('labels H59MA Channel-B explicit rejects', () {
      final frames = [
        OpB.h59ExplicitReject21,
        OpB.h59ExplicitReject22,
        OpB.h59ExplicitReject23,
        OpB.h59ExplicitReject24,
      ].map((cmd) => Codec.buildChannelB(cmd, [0x01])).toList();

      final report = const WatchLogDecoder().decodeNrfConnectLog(
        frames.map((f) => _line(_chB, f)).join('\n'),
      );

      expect(report.frames, hasLength(4));
      expect(report.frames.map((f) => f.details['label']), [
        'h59ExplicitReject21',
        'h59ExplicitReject22',
        'h59ExplicitReject23',
        'h59ExplicitReject24',
      ]);
      for (final frame in report.frames) {
        expect(frame.title, contains('explicit-reject compactNak=2'));
        expect(frame.details['firmwareBehavior'], 'compact-nak-2');
        expect(frame.details['compactNakCode'], 2);
      }
    });

    test('labels APK FileHandle commands as unsupported on H59MA', () {
      final frames = [
        OpB.fileList,
        OpB.fileInit,
        OpB.filePocket,
        OpB.fileCheck,
        OpB.fileDelete,
      ].map((cmd) => Codec.buildChannelB(cmd, [0x01])).toList();

      final report = const WatchLogDecoder().decodeNrfConnectLog(
        frames.map((f) => _line(_chB, f)).join('\n'),
      );

      expect(report.frames, hasLength(5));
      expect(report.frames.map((f) => f.details['label']), [
        'apkFileListUnsupported',
        'apkFileInitUnsupported',
        'apkFilePocketUnsupported',
        'apkFileCheckUnsupported',
        'apkFileDeleteUnsupported',
      ]);
      for (final frame in report.frames) {
        expect(frame.title, contains('unsupported compactNak=0'));
        expect(frame.details['firmwareBehavior'], 'compact-nak-0');
      }
    });

    test('labels APK sidecar commands as unsupported on H59MA', () {
      final cases = [
        (OpB.apkMusicSendUnsupported, 'apkMusicSendUnsupported'),
        (OpB.apkLocationUnsupported, 'apkLocationUnsupported'),
        (
          OpB.apkTemperatureSeriesUnsupported,
          'apkTemperatureSeriesUnsupported',
        ),
        (OpB.apkTemperatureOnceUnsupported, 'apkTemperatureOnceUnsupported'),
        (OpB.apkManualHeartRateUnsupported, 'apkManualHeartRateUnsupported'),
        (OpB.apkContactUnsupported, 'apkContactUnsupported'),
        (OpB.apkBtMacUnsupported, 'apkBtMacUnsupported'),
        (OpB.apkQrCodeUnsupported, 'apkQrCodeUnsupported'),
        (OpB.apkPlateListUnsupported, 'apkPlateListUnsupported'),
        (OpB.apkCustomWatchFaceUnsupported, 'apkCustomWatchFaceUnsupported'),
        (OpB.apkGpsNavigationUnsupported, 'apkGpsNavigationUnsupported'),
        (OpB.apkManualOxygenUnsupported, 'apkManualOxygenUnsupported'),
        (OpB.apkAvatarDeviceUnsupported, 'apkAvatarDeviceUnsupported'),
        (OpB.apkSmsQuickUnsupported, 'apkSmsQuickUnsupported'),
        (OpB.apkAgpsUnsupported, 'apkAgpsUnsupported'),
        (
          OpB.apkIntervalBloodOxygenUnsupported,
          'apkIntervalBloodOxygenUnsupported',
        ),
        (
          OpB.apkIntervalHeartRateUnsupported,
          'apkIntervalHeartRateUnsupported',
        ),
        (
          OpB.apkAlbumEbookRecordListUnsupported,
          'apkAlbumEbookRecordListUnsupported',
        ),
        (OpB.apkEbookDeleteUnsupported, 'apkEbookDeleteUnsupported'),
        (OpB.apkRecordReadUnsupported, 'apkRecordReadUnsupported'),
      ];
      final frames = cases
          .map((entry) => Codec.buildChannelB(entry.$1, [0x01]))
          .toList();

      final report = const WatchLogDecoder().decodeNrfConnectLog(
        frames.map((f) => _line(_chB, f)).join('\n'),
      );

      expect(report.frames, hasLength(cases.length));
      expect(
        report.frames.map((f) => f.details['label']),
        cases.map((entry) => entry.$2),
      );
      for (final frame in report.frames) {
        expect(frame.title, contains('unsupported compactNak=0'));
        expect(frame.details['firmwareBehavior'], 'compact-nak-0');
      }
    });

    test('labels unknown Channel-B one-byte responses as compact status', () {
      final frame = Codec.buildChannelB(0x60, [0x00]);

      final report = const WatchLogDecoder().decodeNrfConnectLog(
        _line(_chB, frame),
      );
      final decoded = report.frames.single;

      expect(decoded.valid, isTrue);
      expect(decoded.title, contains('B 0x60 unknown compactStatus=0x00'));
      expect(decoded.details['label'], 'unknown');
      expect(decoded.details['compactStatusCode'], 0);
      expect(decoded.details['firmwareBehavior'], 'compact-status');
      expect(decoded.details['payloadBytes'], 1);
    });

    test('summarizes H59MA Channel-B alarm read records', () {
      final frame = Codec.buildChannelB(OpB.alarm, [
        0x01,
        0x01,
        0x07,
        0x83,
        0x3c,
        0x01,
        ..._ascii('Gym'),
      ]);

      final report = const WatchLogDecoder().decodeNrfConnectLog(
        _line(_chB, frame),
      );

      final decoded = report.frames.single;
      expect(decoded.title, contains('alarm read records=1/1'));
      expect(decoded.title, contains('first=05:16 "Gym"'));
      expect(decoded.details['label'], 'alarm');
      expect(decoded.details['declaredCount'], 1);
      final records = decoded.details['alarmRecords']! as List<Object?>;
      final alarm = records.single! as Map<String, Object?>;
      expect(alarm['flags'], '0x83');
      expect(alarm['flag80'], isTrue);
      expect(alarm['weekMask'], 0x03);
      expect(alarm['weekdays'], [0, 1]);
      expect(alarm['minuteOfDay'], 316);
      expect(alarm['label'], 'Gym');
    });

    test('summarizes Channel B device-info static TLVs', () {
      final frame = Codec.buildChannelB(OpB.deviceInfoConfig, [
        0x03,
        0x01,
        0x06,
        0x01,
        0x07,
        ..._ascii('H59MAX_'),
        0x02,
        0x07,
        ..._ascii('H59MAX_'),
        0x03,
        0x0a,
        ..._ascii('H59MA_V1.0'),
        0x04,
        0x06,
        ..._ascii('H59MA_'),
        0x05,
        0x08,
        ..._ascii('1.00.14_'),
        0x06,
        0x06,
        ..._ascii('260508'),
      ]);

      final report = const WatchLogDecoder().decodeNrfConnectLog(
        _line(_chB, frame),
      );

      final decoded = report.frames.single;
      expect(decoded.valid, isTrue);
      expect(decoded.title, contains('device info static'));
      expect(decoded.details['label'], 'deviceInfoConfig');
      expect(decoded.details['hardwareId'], 'H59MA_V1.0');
      expect(decoded.details['firmwareVersion'], 'H59MA_1.00.14_260508');
    });

    test('summarizes clock alarm read replies', () {
      final frame = Codec.buildChannelA(OpA.readAlarm, [
        2,
        1,
        Codec.toBcd(6),
        Codec.toBcd(30),
        0,
        1,
        1,
        1,
        1,
        1,
        0,
      ]);

      final decoded = const WatchLogDecoder().decodeHex(
        frame.map((b) => b.toRadixString(16).padLeft(2, '0')).join('-'),
      );

      expect(decoded.valid, isTrue);
      expect(decoded.details['label'], 'readAlarm');
      expect(decoded.title, contains('clock alarm slot=2'));
      expect(decoded.title, contains('time=06:30'));
      expect(decoded.details['enabled'], isTrue);
      expect(decoded.details['weekMask'], 0x3e);
      expect(decoded.details['weekdays'], [1, 2, 3, 4, 5]);
    });

    test('summarizes drink alarm read replies separately', () {
      final frame = Codec.buildChannelA(OpA.readDrinkAlarm, [
        7,
        2,
        Codec.toBcd(14),
        Codec.toBcd(25),
        1,
        0,
        1,
        0,
        1,
        0,
        1,
      ]);

      final decoded = const WatchLogDecoder().decodeHex(
        frame.map((b) => b.toRadixString(16).padLeft(2, '0')).join('-'),
      );

      expect(decoded.valid, isTrue);
      expect(decoded.details['label'], 'readDrinkAlarm');
      expect(decoded.title, contains('drink alarm slot=7'));
      expect(decoded.title, contains('enabled=false'));
      expect(decoded.title, contains('weekMask=0x55'));
      expect(decoded.details['hour'], 14);
      expect(decoded.details['minute'], 25);
    });

    test('summarizes data-distribution bitmask replies', () {
      final frame = Codec.buildChannelA(OpA.queryDataDistribution, [
        0x00,
        0x00,
        0x00,
        0x05,
      ]);

      final decoded = const WatchLogDecoder().decodeHex(
        frame.map((b) => b.toRadixString(16).padLeft(2, '0')).join('-'),
      );

      expect(decoded.valid, isTrue);
      expect(decoded.details['label'], 'queryDataDistribution');
      expect(decoded.details['mask'], 0x00000005);
      expect(decoded.details['daysWithData'], [0, 2]);
      expect(decoded.title, contains('mask=0x00000005'));
      expect(decoded.title, contains('offsets=[0, 2]'));
    });

    test('summarizes display-clock toggle replies', () {
      final frame = Codec.buildChannelA(OpA.displayClock, [OpA.mixWrite, 1]);

      final decoded = const WatchLogDecoder().decodeHex(
        frame.map((b) => b.toRadixString(16).padLeft(2, '0')).join('-'),
      );

      expect(decoded.valid, isTrue);
      expect(decoded.details['label'], 'displayClock');
      expect(decoded.details['sub'], '0x02');
      expect(decoded.details['state'], 1);
      expect(decoded.details['enabled'], isTrue);
      expect(decoded.title, contains('displayClock sub=0x02'));
      expect(decoded.title, contains('state=1'));
      expect(decoded.title, contains('enabled=true'));
    });

    test('summarizes watchface display-clock echo frames', () {
      final frame = Codec.buildChannelA(OpA.watchfaceDisplayClock, [
        0x22,
        5,
        3,
        ...'ABC'.codeUnits,
      ]);

      final decoded = const WatchLogDecoder().decodeHex(
        frame.map((b) => b.toRadixString(16).padLeft(2, '0')).join('-'),
      );

      expect(decoded.valid, isTrue);
      expect(decoded.details['label'], 'watchfaceDisplayClock');
      expect(decoded.details['style'], 0x22);
      expect(decoded.details['length'], 5);
      expect(decoded.details['echoedLength'], 3);
      expect(decoded.details['echoedLabel'], 'ABC');
      expect(decoded.details['payload'], isNotNull);
      expect(decoded.title, contains('watchfaceDisplayClock style=0x22'));
      expect(decoded.title, contains('length=5'));
      expect(decoded.title, contains('echoedLength=3'));
      expect(decoded.title, contains('label="ABC"'));
    });

    test('summarizes minimal watchface display-clock frames with no label', () {
      final frame = Codec.buildChannelA(OpA.watchfaceDisplayClock, [
        0x01,
        0x02,
      ]);

      final decoded = const WatchLogDecoder().decodeHex(
        frame.map((b) => b.toRadixString(16).padLeft(2, '0')).join('-'),
      );

      expect(decoded.valid, isTrue);
      expect(decoded.details['label'], 'watchfaceDisplayClock');
      expect(decoded.details['style'], 0x01);
      expect(decoded.details['length'], 2);
      expect(decoded.details['echoedLength'], 0);
      expect(decoded.details['echoedLabel'], '');
      expect(decoded.title, contains('watchfaceDisplayClock style=0x01'));
      expect(decoded.title, contains('length=2'));
      expect(decoded.title, contains('echoedLength=0'));
      expect(decoded.title, contains('label=none'));
    });

    test('summarizes common display and setting replies', () {
      final dnd = _decodeA(OpA.dnd, [OpA.mixWrite, 1, 22, 0, 7, 30]);
      expect(dnd.details['label'], 'doNotDisturb');
      expect(dnd.details['enabled'], isTrue);
      expect(dnd.details['startHour'], 22);
      expect(dnd.details['endMinute'], 30);
      expect(dnd.title, contains('window=22:00-07:30'));

      final timeFormat = _decodeA(OpA.timeFormat, [OpA.mixWrite, 0, 1]);
      expect(timeFormat.details['label'], 'timeFormat');
      expect(timeFormat.details['is24Hour'], isTrue);
      expect(timeFormat.details['metric'], isFalse);
      expect(timeFormat.title, contains('is24Hour=true'));
      expect(timeFormat.title, contains('metric=false'));

      final orientation = _decodeA(OpA.displayOrientation, [
        OpA.mixWrite,
        1,
        2,
      ]);
      expect(orientation.details['label'], 'displayOrientation');
      expect(orientation.details['autoRotate'], isTrue);
      expect(orientation.details['landscape'], isFalse);
      expect(orientation.title, contains('autoRotate=true'));

      final displayStyle = _decodeA(OpA.displayStyle, [OpA.mixWrite, 7]);
      expect(displayStyle.details['label'], 'displayStyle');
      expect(displayStyle.details['style'], 7);

      final displayTime = _decodeA(OpA.displayTime, [
        OpA.mixWrite,
        30,
        1,
        200,
        0,
        4,
        2,
      ]);
      expect(displayTime.details['label'], 'displayTime');
      expect(displayTime.details['displayTime'], 30);
      expect(displayTime.details['alpha'], 200);
      expect(displayTime.title, contains('index=2/4'));

      final brightness = _decodeA(OpA.brightness, [OpA.mixWrite, 9]);
      expect(brightness.details['label'], 'brightness');
      expect(brightness.details['level'], 9);

      final degree = _decodeA(OpA.degreeSwitch, [OpA.mixWrite, 1, 2]);
      expect(degree.details['label'], 'degreeSwitch');
      expect(degree.details['enabled'], isTrue);
      expect(degree.details['isCelsius'], isFalse);
      expect(degree.title, contains('unit=F'));

      final palm = _decodeA(OpA.palmScreen, [OpA.mixWrite, 1, 2, 6]);
      expect(palm.details['label'], 'palmScreen');
      expect(palm.details['enabled'], isTrue);
      expect(palm.details['secondary'], isFalse);
      expect(palm.details['commitFlag'], isTrue);

      final intell = _decodeA(OpA.intell, [OpA.mixWrite, 1, 12]);
      expect(intell.details['label'], 'intell');
      expect(intell.details['enabled'], isTrue);
      expect(intell.details['delaySeconds'], 12);
      expect(intell.title, contains('delay=12s'));
    });

    test('summarizes music notify frames with decoded metadata', () {
      final frame = Codec.buildChannelA(OpA.musicNotify, [
        0x00, // playing^1 -> playing=true
        64,
        80,
        ...'Vulfpeck'.codeUnits,
      ]);

      final decoded = const WatchLogDecoder().decodeHex(
        frame.map((b) => b.toRadixString(16).padLeft(2, '0')).join('-'),
      );

      expect(decoded.valid, isTrue);
      expect(decoded.details['label'], 'musicNotify');
      expect(decoded.details['playing'], isTrue);
      expect(decoded.details['progress'], 64);
      expect(decoded.details['volume'], 80);
      expect(decoded.details['track'], 'Vulfpeck');
      expect(decoded.title, contains('music playing=true'));
      expect(decoded.title, contains('track="Vulfpeck"'));
    });

    test(
      'summarizes music notify frames after trimming null title padding',
      () {
        final frame = Codec.buildChannelA(OpA.musicNotify, [
          0x01, // playing^1 -> playing=false
          0,
          10,
          0,
          ...'Idle'.codeUnits,
          0,
          0,
        ]);

        final decoded = const WatchLogDecoder().decodeHex(
          frame.map((b) => b.toRadixString(16).padLeft(2, '0')).join('-'),
        );

        expect(decoded.valid, isTrue);
        expect(decoded.details['playing'], isFalse);
        expect(decoded.details['volume'], 10);
        expect(decoded.details['track'], 'Idle');
        expect(decoded.title, contains('music playing=false'));
        expect(decoded.title, contains('track="Idle"'));
      },
    );

    test('summarizes FEE7 battery responses from the vendor notify UUID', () {
      final frame = Codec.buildChannelA(Fee7.battery, [80, 1]);

      final decoded = const WatchLogDecoder().decodeHex(
        frame.map((b) => b.toRadixString(16).padLeft(2, '0')).join('-'),
        uuid: _fee7,
      );

      expect(decoded.valid, isTrue);
      expect(decoded.channel, WatchLogChannel.fee7);
      expect(decoded.details['label'], 'battery');
      expect(decoded.title, contains('battery 80%'));
      expect(decoded.title, contains('charging=true'));
      expect(decoded.details['batteryPercent'], 80);
      expect(decoded.details['charging'], isTrue);
    });

    test('summarizes FEE7 status responses from the vendor notify UUID', () {
      final frame = Codec.buildChannelA(Fee7.statusResponse, [
        0x78,
        0x56,
        0x34,
        0x12,
      ]);

      final decoded = const WatchLogDecoder().decodeHex(
        frame.map((b) => b.toRadixString(16).padLeft(2, '0')).join('-'),
        uuid: _fee7,
      );

      expect(decoded.valid, isTrue);
      expect(decoded.channel, WatchLogChannel.fee7);
      expect(decoded.details['label'], 'status');
      expect(decoded.title, contains('status value=0x12345678'));
      expect(decoded.title, contains('low=0x78'));
      expect(decoded.details['statusValue'], 0x12345678);
      expect(decoded.details['statusLowByte'], 0x78);
      expect(decoded.details['idle'], isFalse);
    });

    test('labels FEE7 0x60 as pending status write', () {
      final frame = Codec.buildChannelA(Fee7.pendingStatusWrite, [
        0x44,
        0x33,
        0x22,
        0x11,
      ]);

      final decoded = const WatchLogDecoder().decodeHex(
        frame.map((b) => b.toRadixString(16).padLeft(2, '0')).join('-'),
        uuid: _fee7,
      );

      expect(decoded.valid, isTrue);
      expect(decoded.channel, WatchLogChannel.fee7);
      expect(decoded.details['opcode'], '0x60');
      expect(decoded.details['label'], 'pendingStatusWrite');
      expect(decoded.title, contains('pendingStatusWrite'));
    });

    test('labels FEE7 0x3e as lipids, not blood oxygen', () {
      final frame = Codec.buildChannelA(Fee7.lipidsUpdate, [0x01, 0x00]);

      final decoded = const WatchLogDecoder().decodeHex(
        frame.map((b) => b.toRadixString(16).padLeft(2, '0')).join('-'),
        uuid: _fee7,
      );

      expect(decoded.valid, isTrue);
      expect(decoded.channel, WatchLogChannel.fee7);
      expect(decoded.details['opcode'], '0x3e');
      expect(decoded.details['label'], 'lipidsUpdate');
      expect(decoded.title, contains('lipidsUpdate'));
      expect(decoded.title, isNot(contains('blood')));
    });

    test('labels low-range FEE7 setting mirrors from reversed firmware', () {
      const cases = {
        Fee7.camera: 'camera',
        Fee7.bindAncs: 'bindAncs',
        Fee7.timeFormat: 'timeFormat',
        Fee7.bpSetting: 'bpSetting',
        Fee7.bpData: 'bpData',
        Fee7.shortAlert: 'shortAlert',
        Fee7.lowNoop14: 'lowNoop',
        Fee7.heartRateSetting: 'heartRateSetting',
        Fee7.degreeSwitch: 'degreeSwitch',
        Fee7.targetSetting: 'targetSetting',
      };

      for (final entry in cases.entries) {
        final frame = Codec.buildChannelA(entry.key, [0x01, 0x00]);

        final decoded = const WatchLogDecoder().decodeHex(
          frame.map((b) => b.toRadixString(16).padLeft(2, '0')).join('-'),
          uuid: _fee7,
        );

        expect(decoded.valid, isTrue);
        expect(decoded.channel, WatchLogChannel.fee7);
        expect(decoded.details['label'], entry.value);
        expect(decoded.title, contains(entry.value));
      }
    });

    test(
      'summarizes high-bit FEE7 OTA and synthetic sleep frames as raw opcodes',
      () {
        final ota = Codec.buildChannelA(Fee7.otaTrigger, [1, 1]);
        final syntheticSleep = Codec.buildChannelA(Fee7.syntheticSleep, [
          0x2c,
          0x01,
        ]);

        final otaDecoded = const WatchLogDecoder().decodeHex(
          ota.map((b) => b.toRadixString(16).padLeft(2, '0')).join('-'),
          uuid: _fee7,
        );
        final syntheticSleepDecoded = const WatchLogDecoder().decodeHex(
          syntheticSleep
              .map((b) => b.toRadixString(16).padLeft(2, '0'))
              .join('-'),
          uuid: _fee7,
        );

        expect(otaDecoded.valid, isTrue);
        expect(otaDecoded.details['opcode'], '0xc3');
        expect(otaDecoded.details['label'], 'otaControl');
        expect(otaDecoded.details['action'], 1);
        expect(otaDecoded.details['serviceResetRequested'], isTrue);
        expect(otaDecoded.details['startsDfu'], isTrue);
        expect(otaDecoded.details['routesToOta'], isTrue);
        expect(otaDecoded.title, contains('otaControl action=1'));
        expect(otaDecoded.title, contains('reset=true'));

        expect(syntheticSleepDecoded.valid, isTrue);
        expect(syntheticSleepDecoded.details['opcode'], '0xfe');
        expect(syntheticSleepDecoded.details['label'], 'syntheticSleep');
        expect(syntheticSleepDecoded.details['durationMinutes'], 300);
        expect(syntheticSleepDecoded.title, contains('duration=300m'));
      },
    );

    test('summarizes high-range FEE7 session and model/status frames', () {
      final build = Codec.buildChannelA(
        Fee7.firmwareBuildInfo,
        '1.00.14_260508'.codeUnits,
      );
      final session = Codec.buildChannelA(Fee7.sessionModeStatus, [0x88]);
      final model = Codec.buildChannelA(Fee7.modelName, 'H59MA_V1.0'.codeUnits);
      final highStatus = Codec.buildChannelA(Fee7.highStatusFrame, [
        0x01,
        0x23,
        0x21,
        0x04,
        0x12,
        0x34,
        0x07,
        0x56,
        0x78,
      ]);

      final buildDecoded = const WatchLogDecoder().decodeHex(
        build.map((b) => b.toRadixString(16).padLeft(2, '0')).join('-'),
        uuid: _fee7,
      );
      final sessionDecoded = const WatchLogDecoder().decodeHex(
        session.map((b) => b.toRadixString(16).padLeft(2, '0')).join('-'),
        uuid: _fee7,
      );
      final modelDecoded = const WatchLogDecoder().decodeHex(
        model.map((b) => b.toRadixString(16).padLeft(2, '0')).join('-'),
        uuid: _fee7,
      );
      final highStatusDecoded = const WatchLogDecoder().decodeHex(
        highStatus.map((b) => b.toRadixString(16).padLeft(2, '0')).join('-'),
        uuid: _fee7,
      );

      expect(buildDecoded.details['label'], 'firmwareBuildInfo');
      expect(buildDecoded.details['versionBuild'], '1.00.14_260508');
      expect(buildDecoded.details['headerAck'], isFalse);
      expect(buildDecoded.title, contains('firmwareBuildInfo'));

      expect(sessionDecoded.details['label'], 'sessionModeStatus');
      expect(sessionDecoded.details['stateByte'], 0x88);
      expect(sessionDecoded.details['isMode2'], isTrue);
      expect(sessionDecoded.title, contains('state=0x88'));

      expect(modelDecoded.details['label'], 'modelName');
      expect(modelDecoded.details['modelName'], 'H59MA_V1.0');
      expect(modelDecoded.title, contains('modelName "H59MA_V1.0"'));

      expect(highStatusDecoded.details['label'], 'highStatus');
      expect(highStatusDecoded.details['dataBytes'], 14);
      expect(highStatusDecoded.details['marker23'], isTrue);
      expect(highStatusDecoded.details['marker21'], isTrue);
      expect(highStatusDecoded.title, contains('highStatus bytes=14'));
    });

    test('labels FEE7 no-response placeholders from reversed firmware', () {
      for (final opcode in [
        Fee7.highNoop92,
        Fee7.highNoop97,
        Fee7.highNoop99,
        Fee7.highNoop9d,
        Fee7.highNoop9f,
      ]) {
        final frame = Codec.buildChannelA(opcode);

        final decoded = const WatchLogDecoder().decodeHex(
          frame.map((b) => b.toRadixString(16).padLeft(2, '0')).join('-'),
          uuid: _fee7,
        );

        expect(decoded.valid, isTrue);
        expect(decoded.channel, WatchLogChannel.fee7);
        expect(decoded.details['label'], 'noResponsePlaceholder');
        expect(decoded.title, contains('noResponsePlaceholder'));
      }
    });

    test('labels FEE7 vendor debug opcodes from reversed firmware', () {
      const cases = {
        Fee7.unaryC4: 'runtimeNoop',
        Fee7.unaryC5: 'runtimeFlagWrite',
        Fee7.unaryC8: 'runtimeFlagWrite',
        Fee7.unaryC9: 'runtimeFlagWrite',
        Fee7.unaryCd: 'smallMemoryRead',
        Fee7.unaryCe: 'factoryTest',
      };

      for (final entry in cases.entries) {
        final frame = Codec.buildChannelA(entry.key, [0x01, 0x02]);

        final decoded = const WatchLogDecoder().decodeHex(
          frame.map((b) => b.toRadixString(16).padLeft(2, '0')).join('-'),
          uuid: _fee7,
        );

        expect(decoded.valid, isTrue);
        expect(decoded.channel, WatchLogChannel.fee7);
        expect(decoded.details['label'], entry.value);
        expect(decoded.title, contains(entry.value));
      }
    });

    test(
      'labels FEE7 echo and state-update opcodes from reversed firmware',
      () {
        const cases = {
          Fee7.echoBase: 'selfMarkerEcho',
          Fee7.echoBase2: 'checksumEcho',
          Fee7.stateUpdateMode1: 'stateUpdateMode1',
          Fee7.stateUpdateMode3: 'stateUpdateMode3',
          Fee7.resetState: 'resetState',
          Fee7.memoryWrite: 'memoryWrite',
        };

        for (final entry in cases.entries) {
          final frame = Codec.buildChannelA(entry.key);

          final decoded = const WatchLogDecoder().decodeHex(
            frame.map((b) => b.toRadixString(16).padLeft(2, '0')).join('-'),
            uuid: _fee7,
          );

          expect(decoded.valid, isTrue);
          expect(decoded.channel, WatchLogChannel.fee7);
          expect(decoded.details['label'], entry.value);
          expect(decoded.title, contains(entry.value));
        }
      },
    );

    test('summarizes FEE7 memory-read chunks as raw data frames', () {
      final frame = Codec.buildChannelA(
        Fee7.memoryRead,
        List<int>.generate(14, (i) => 0x20 + i),
      );

      final decoded = const WatchLogDecoder().decodeHex(
        frame.map((b) => b.toRadixString(16).padLeft(2, '0')).join('-'),
        uuid: _fee7,
      );

      expect(decoded.valid, isTrue);
      expect(decoded.details['opcode'], '0xc0');
      expect(decoded.details['label'], 'memoryRead');
      expect(decoded.details['dataBytes'], 14);
      expect(decoded.title, contains('memoryRead chunk bytes=14'));
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

DecodedLogFrame _decodeA(int opcode, List<int> payload) {
  final frame = Codec.buildChannelA(opcode, payload);
  return const WatchLogDecoder().decodeHex(_hexBytes(frame));
}

List<int> _ascii(String value) => value.codeUnits;

String _hexBytes(List<int> bytes) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join('-');

List<int> _bytes(String hex) => [
  for (final match in RegExp(r'[0-9A-Fa-f]{2}').allMatches(hex))
    int.parse(match.group(0)!, radix: 16),
];
