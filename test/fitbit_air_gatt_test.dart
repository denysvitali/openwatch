import 'package:flutter_test/flutter_test.dart';
import 'package:openwatch/core/ble/ble_constants.dart';

void main() {
  test('identifies only the captured Fitbit Air private services', () {
    expect(
      BleUuids.isFitbitAirPrivateService(BleUuids.fitbitAirCommandService),
      isTrue,
    );
    expect(
      BleUuids.isFitbitAirPrivateService(BleUuids.fitbitAirDataService),
      isTrue,
    );
    expect(
      BleUuids.isFitbitAirPrivateService(BleUuids.fitbitAirTelemetryService),
      isTrue,
    );
    expect(
      BleUuids.isFitbitAirPrivateService(BleUuids.heartRateService),
      isFalse,
    );
  });
}
