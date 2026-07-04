import 'package:flutter_test/flutter_test.dart';
import 'package:openwatch/core/ble/ble_transport.dart';
import 'package:openwatch/core/protocol/codec.dart';
import 'package:openwatch/core/protocol/opcodes.dart';
import 'package:openwatch/core/services/watch_manager.dart';

import 'support/fake_ble_transport.dart';

void main() {
  group('WatchManager custom watch face', () {
    test('sends DIY watch-face elements through Channel B', () async {
      final t = FakeBleTransport()..linkState.value = LinkState.disconnected;
      final mgr = WatchManager(t, autoSyncTime: false);
      addTearDown(mgr.dispose);

      await mgr.writeCustomWatchFace([
        (type: 1, x: 0x12, y: 0x34, r: 0xAA, g: 0xBB, b: 0xCC),
      ]);

      expect(t.sentB, hasLength(1));
      expect(Codec.rxChannelBCmd(t.sentB.single), OpB.customWatchFace);
      expect(Codec.rxChannelBPayload(t.sentB.single), [
        0x02,
        0x01,
        0x12,
        0x00,
        0x34,
        0x00,
        0xAA,
        0xBB,
        0xCC,
      ]);
    });
  });
}
