import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:openwatch/core/protocol/firmware_version.dart';

void main() {
  group('FirmwareVersion.parse', () {
    test('strips H59MA_ prefix and keeps the semantic version', () {
      final v = FirmwareVersion.parse('H59MA_1.00.13');
      expect(v.hardwareId, 'H59MA');
      expect(v.version, '1.00.13');
      expect(v.isStructured, isTrue);
      expect(v.pretty, '1.00.13');
    });

    test('accepts the long <hw>_<ver>_<build> form', () {
      final v = FirmwareVersion.parse('H59MA_1.00.13_251230');
      expect(v.hardwareId, 'H59MA');
      expect(v.version, '1.00.13');
      expect(v.raw, 'H59MA_1.00.13_251230');
    });

    test('handles bare version with no hardware prefix', () {
      final v = FirmwareVersion.parse('1.00.13');
      expect(v.hardwareId, '');
      expect(v.version, '1.00.13');
      expect(v.isStructured, isFalse);
    });

    test('falls back to raw text when no version is recognisable', () {
      final v = FirmwareVersion.parse('something-random');
      expect(v.hardwareId, 'something-random');
      expect(v.version, isNull);
      expect(v.pretty, 'something-random');
    });

    test('treats whitespace-only input as empty', () {
      final v = FirmwareVersion.parse('   ');
      expect(v.raw, '');
      expect(v.hardwareId, '');
      expect(v.version, isNull);
      expect(v.isStructured, isFalse);
    });

    test('fromBytes reads ASCII firmware revision characteristics', () {
      final bytes = Uint8List.fromList('H59MA_1.00.14'.codeUnits);
      final v = FirmwareVersion.fromBytes(bytes);
      expect(v.hardwareId, 'H59MA');
      expect(v.version, '1.00.14');
    });
  });
}
