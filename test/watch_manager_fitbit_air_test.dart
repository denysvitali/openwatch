import 'package:flutter_test/flutter_test.dart';
import 'package:openwatch/core/ble/ble_constants.dart';
import 'package:openwatch/core/services/watch_manager.dart';

import 'support/fake_ble_transport.dart';

void main() {
  test(
    'Fitbit Air consumes standard heart-rate notifications without commands',
    () async {
      final transport = FakeBleTransport()..profile = WatchProfile.fitbitAir;
      final manager = WatchManager(transport, autoSyncTime: false);
      addTearDown(manager.dispose);

      await Future<void>.delayed(const Duration(milliseconds: 20));

      expect(manager.capabilities.heart, isTrue);
      expect(manager.supportsActiveHeartRateMeasurement, isFalse);
      expect(transport.sentA, isEmpty);

      transport.standardHeartRateIn.add(72);
      await Future<void>.delayed(const Duration(milliseconds: 20));

      expect(manager.lastHeartRate, 72);
      expect(transport.sentA, isEmpty);
    },
  );
}
