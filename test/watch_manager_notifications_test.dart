import 'package:flutter_test/flutter_test.dart';
import 'package:openwatch/core/protocol/codec.dart';
import 'package:openwatch/core/protocol/opcodes.dart';
import 'package:openwatch/core/services/watch_manager.dart';

import 'support/fake_ble_transport.dart';

void main() {
  group('WatchManager.enableNotifications', () {
    test('sends bind over FEE7 when the vendor service is available', () async {
      final t = FakeBleTransport();
      final mgr = WatchManager(t, autoSyncTime: false);
      addTearDown(mgr.dispose);
      await Future<void>.delayed(const Duration(milliseconds: 20));

      final sentABefore = t.sentA.length;
      final sentFee7Before = t.sentFee7.length;
      await mgr.enableNotifications('ABCDEFGHIJKLMNO');

      final fee7Frames = t.sentFee7.skip(sentFee7Before).toList();
      expect(fee7Frames, hasLength(1));
      expect(Codec.rxOpcode(fee7Frames.single), Fee7.bindAncs);
      expect(fee7Frames.single.sublist(3, 15), 'ABCDEFGHIJKL'.codeUnits);

      final channelAFrames = t.sentA.skip(sentABefore).toList();
      expect(channelAFrames, hasLength(1));
      expect(Codec.rxOpcode(channelAFrames.single), OpA.setAncs);
    });

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
      expect(channelAFrames, hasLength(2));
      expect(Codec.rxOpcode(channelAFrames[0]), OpA.bindAncs);
      expect(Codec.rxOpcode(channelAFrames[1]), OpA.setAncs);
    });
  });
}
