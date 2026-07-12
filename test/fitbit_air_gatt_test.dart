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
      BleUuids.isFitbitAirPrivateService(BleUuids.fitbitAirControlService),
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

  test('models every characteristic UUID in the supplied capture', () {
    expect(
      <String>{
        BleUuids.fitbitAirCommandWrite.str,
        BleUuids.fitbitAirCommandNotify.str,
        BleUuids.fitbitAirDataNotify1.str,
        BleUuids.fitbitAirDataNotify2.str,
        BleUuids.fitbitAirDataRead.str,
        BleUuids.fitbitAirControlRead.str,
        BleUuids.fitbitAirControlWrite.str,
        BleUuids.fitbitAirTelemetryNotify1.str,
        BleUuids.fitbitAirTelemetryWrite.str,
        BleUuids.fitbitAirTelemetryRead.str,
        BleUuids.fitbitAirTelemetryIndicate.str,
        BleUuids.fitbitAirTelemetryNotify2.str,
        BleUuids.fitbitAirTelemetryReadWriteNotify.str,
        BleUuids.fitbitAirTelemetryReadWriteIndicate.str,
      },
      <String>{
        'abbaff01-e56a-484c-b832-8b17cf6cbfe8',
        'abbaff02-e56a-484c-b832-8b17cf6cbfe8',
        'abbafd01-e56a-484c-b832-8b17cf6cbfe8',
        'abbafd02-e56a-484c-b832-8b17cf6cbfe8',
        'abbafd03-e56a-484c-b832-8b17cf6cbfe8',
        'ac2f0145-8182-4be5-91e0-2992e6b40ebb',
        'ac2f2845-8182-4be5-91e0-2992e6b40ebb',
        '4eee1c01-4133-479b-8663-02c84bdc14be',
        '4eee1c02-4133-479b-8663-02c84bdc14be',
        '4eee1c03-4133-479b-8663-02c84bdc14be',
        '4eee1c04-4133-479b-8663-02c84bdc14be',
        '4eee1c05-4133-479b-8663-02c84bdc14be',
        '4eee1c06-4133-479b-8663-02c84bdc14be',
        '4eee1c07-4133-479b-8663-02c84bdc14be',
      },
    );
  });
}
