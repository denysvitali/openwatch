import 'package:flutter_test/flutter_test.dart';
import 'package:openwatch/core/protocol/codec.dart';
import 'package:openwatch/core/protocol/opcodes.dart';
import 'package:openwatch/core/services/watch_manager.dart';

import 'support/fake_ble_transport.dart';

void main() {
  group('WatchManager.enableNotifications', () {
    test(
      'sends bind over Channel A when the vendor service is available',
      () async {
        final t = FakeBleTransport();
        final mgr = WatchManager(t, autoSyncTime: false);
        addTearDown(mgr.dispose);
        await Future<void>.delayed(const Duration(milliseconds: 20));

        final sentABefore = t.sentA.length;
        final sentFee7Before = t.sentFee7.length;
        await mgr.enableNotifications('ABCDEFGHIJKLMNO');

        expect(t.sentFee7.skip(sentFee7Before), isEmpty);

        final channelAFrames = t.sentA.skip(sentABefore).toList();
        expect(channelAFrames, hasLength(1));
        expect(Codec.rxOpcode(channelAFrames[0]), OpA.bindAncs);
        expect(channelAFrames[0].sublist(3, 15), 'ABCDEFGHIJKL'.codeUnits);
      },
    );

    test('falls back to Channel A bind when FEE7 is unavailable', () async {
      final t = FakeBleTransport()..hasFee7Write = false;
      final mgr = WatchManager(t, autoSyncTime: false);
      addTearDown(mgr.dispose);
      await Future<void>.delayed(const Duration(milliseconds: 20));

      final sentABefore = t.sentA.length;
      final sentFee7Before = t.sentFee7.length;
      await mgr.enableNotifications('ABCDEFGHIJKLMNO');

      expect(t.sentFee7.skip(sentFee7Before), isEmpty);
      final channelAFrames = t.sentA.skip(sentABefore).toList();
      expect(channelAFrames, hasLength(1));
      expect(Codec.rxOpcode(channelAFrames[0]), OpA.bindAncs);
    });
  });

  group('WatchManager notify frames', () {
    test('records non-HR 0x73/0x78 dataTypes as opaque diagnostics', () async {
      final t = FakeBleTransport();
      final mgr = WatchManager(t, autoSyncTime: false);
      addTearDown(mgr.dispose);
      await Future<void>.delayed(const Duration(milliseconds: 20));

      t.inA.add(
        Codec.buildChannelA(OpA.deviceNotify, [
          0x09, // hypothetical ECG/PPG dataType: not in the HR allowlist
          80, // plausible bpm byte that must not poison lastHeartRate
          0x01,
          0x02,
        ]),
      );
      await Future<void>.delayed(const Duration(milliseconds: 20));

      expect(mgr.lastHeartRate, isNull);
      expect(mgr.observedUnknownNotifyTypes, contains(0x09));
      expect(
        mgr.lastUnknownNotifyPayload,
        orderedEquals([0x09, 80, 0x01, 0x02, ...List.filled(10, 0)]),
      );

      t.inA.add(
        Codec.buildChannelA(OpA.deviceSportNotify, [
          0x0b, // another non-HR dataType on the sibling notify opcode
          120,
          0x03,
        ]),
      );
      await Future<void>.delayed(const Duration(milliseconds: 20));

      expect(mgr.lastHeartRate, isNull);
      expect(mgr.observedUnknownNotifyTypes, containsAll(<int>[0x09, 0x0b]));
      expect(
        mgr.lastUnknownNotifyPayload,
        orderedEquals([0x0b, 120, 0x03, ...List.filled(11, 0)]),
      );
    });

    test('updates heart rate only for known HR notify dataTypes', () async {
      final t = FakeBleTransport();
      final mgr = WatchManager(t, autoSyncTime: false);
      addTearDown(mgr.dispose);
      await Future<void>.delayed(const Duration(milliseconds: 20));

      t.inA.add(Codec.buildChannelA(OpA.deviceSportNotify, [0x05, 99]));
      await Future<void>.delayed(const Duration(milliseconds: 20));

      expect(mgr.lastHeartRate, 99);
      expect(mgr.observedUnknownNotifyTypes, isEmpty);
      expect(mgr.lastUnknownNotifyPayload, isNull);
    });
  });
}
