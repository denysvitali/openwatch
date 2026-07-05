import 'package:flutter_test/flutter_test.dart';
import 'package:openwatch/core/protocol/codec.dart';
import 'package:openwatch/core/protocol/opcodes.dart';
import 'package:openwatch/core/services/watch_manager.dart';

import 'support/fake_ble_transport.dart';

void main() {
  group('WatchManager battery refresh', () {
    test(
      'uses Channel A battery command even when FEE7 is advertised',
      () async {
        final t = FakeBleTransport();
        final mgr = WatchManager(t, autoSyncTime: false);
        addTearDown(mgr.dispose);
        await Future<void>.delayed(const Duration(milliseconds: 20));

        final sentABefore = t.sentA.length;
        final sentFee7Before = t.sentFee7.length;
        await mgr.refreshBattery();

        expect(t.sentFee7.skip(sentFee7Before), isEmpty);
        final channelAFrames = t.sentA.skip(sentABefore).toList();
        expect(channelAFrames, hasLength(1));
        expect(Codec.rxOpcode(channelAFrames.single), OpA.battery);
      },
    );

    test('falls back to Channel A battery command without FEE7', () async {
      final t = FakeBleTransport()..hasFee7Write = false;
      final mgr = WatchManager(t, autoSyncTime: false);
      addTearDown(mgr.dispose);
      await Future<void>.delayed(const Duration(milliseconds: 20));

      final sentABefore = t.sentA.length;
      final sentFee7Before = t.sentFee7.length;
      await mgr.refreshBattery();

      expect(t.sentFee7.skip(sentFee7Before), isEmpty);
      final channelAFrames = t.sentA.skip(sentABefore).toList();
      expect(channelAFrames, hasLength(1));
      expect(Codec.rxOpcode(channelAFrames.single), OpA.battery);
    });

    test('updates battery state from FEE7 battery response', () async {
      final t = FakeBleTransport();
      final mgr = WatchManager(t, autoSyncTime: false);
      addTearDown(mgr.dispose);
      await Future<void>.delayed(const Duration(milliseconds: 20));

      t.fee7In.add(Codec.buildChannelA(Fee7.battery, [77, 1]));
      await Future<void>.delayed(const Duration(milliseconds: 20));

      expect(mgr.batteryPercent, 77);
      expect(mgr.charging, isTrue);
    });
  });
}
