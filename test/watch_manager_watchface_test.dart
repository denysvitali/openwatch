import 'package:flutter_test/flutter_test.dart';
import 'package:openwatch/core/ble/ble_transport.dart';
import 'package:openwatch/core/services/watch_manager.dart';

import 'support/fake_ble_transport.dart';

void main() {
  group('WatchManager custom watch face', () {
    test('surfaces unsupported H59MA v14 0x3a path without sending', () async {
      final t = FakeBleTransport()..linkState.value = LinkState.disconnected;
      final mgr = WatchManager(t, autoSyncTime: false);
      addTearDown(mgr.dispose);

      await expectLater(
        // ignore: deprecated_member_use_from_same_package
        mgr.writeCustomWatchFace([
          (type: 1, x: 0x12, y: 0x34, r: 0xAA, g: 0xBB, b: 0xCC),
        ]),
        throwsA(isA<UnsupportedError>()),
      );

      expect(t.sentB, isEmpty);
    });
  });
}
