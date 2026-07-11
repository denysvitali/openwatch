import 'package:flutter_test/flutter_test.dart';
import 'package:openwatch/core/protocol/standard_heart_rate.dart';

void main() {
  group('StandardHeartRate', () {
    test('parses UINT8 heart rate measurements', () {
      expect(StandardHeartRate.parse([0x00, 72]), 72);
    });

    test('parses UINT16 little-endian heart rate measurements', () {
      expect(StandardHeartRate.parse([0x01, 0xC8, 0x00]), 200);
    });

    test('rejects incomplete and implausible measurements', () {
      expect(StandardHeartRate.parse([]), isNull);
      expect(StandardHeartRate.parse([0x01, 72]), isNull);
      expect(StandardHeartRate.parse([0x00, 0]), isNull);
      expect(StandardHeartRate.parse([0x01, 0xF1, 0x00]), isNull);
    });
  });
}
