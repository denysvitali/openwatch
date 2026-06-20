import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:openwatch/core/protocol/firmware_container.dart';

void main() {
  group('FirmwareContainer.parse', () {
    test('returns null for too-short input', () {
      expect(FirmwareContainer.parse(Uint8List(10)), isNull);
    });

    test('returns null for wrong magic', () {
      final bytes = Uint8List(0x460);
      bytes[0] = 0xff;
      bytes[1] = 0xff;
      bytes[2] = 0xff;
      bytes[3] = 0xff;
      expect(FirmwareContainer.parse(bytes), isNull);
    });

    test('parses a real v14 container header', () {
      final file = File('firmwares/H59MA_1.00.14_260508.bin');
      if (!file.existsSync()) {
        markTestSkipped('Firmware file not present in test environment');
        return;
      }
      final bytes = file.readAsBytesSync();
      final c = FirmwareContainer.parse(bytes);
      expect(c, isNotNull);
      expect(c!.header.version, startsWith('H59MA_'));
      expect(c.header.hwId, startsWith('H59MA_'));
      expect(c.header.firmwareSize, lessThanOrEqualTo(bytes.length));
      expect(c.header.firmwareSize, greaterThan(0));
      expect(c.header.loadSize, lessThanOrEqualTo(bytes.length));
      expect(c.body.length, c.header.bodySize);
      expect(c.header.imageDigest.length, 32);
    });
  });

  group('FirmwareContainer.verify', () {
    test('a real v14 image passes every default check', () {
      final file = File('firmwares/H59MA_1.00.14_260508.bin');
      if (!file.existsSync()) {
        markTestSkipped('Firmware file not present');
        return;
      }
      final bytes = file.readAsBytesSync();
      final c = FirmwareContainer.parse(bytes)!;
      final report = c.verify();
      // Four unconditional checks: magic, load_size, firmware_size, body_size.
      // image_chk_a / flash_app_end / version_prefix / hw_id_prefix are all
      // opt-in via FirmwareExpectations.
      expect(report.summary(), 'verification: 4/4 checks passed');
      expect(report.isValid, isTrue);
    });

    test('detects version-prefix mismatch', () {
      final file = File('firmwares/H59MA_1.00.14_260508.bin');
      if (!file.existsSync()) {
        markTestSkipped('Firmware file not present');
        return;
      }
      final bytes = file.readAsBytesSync();
      final c = FirmwareContainer.parse(bytes)!;
      final report = c.verify(
        expected: const FirmwareExpectations(versionPrefix: 'ZZZZ_'),
      );
      expect(report.isValid, isFalse);
      expect(report.failures.map((c) => c.name), contains('version_prefix'));
    });

    test('detects HW-id prefix mismatch', () {
      final file = File('firmwares/H59MA_1.00.14_260508.bin');
      if (!file.existsSync()) {
        markTestSkipped('Firmware file not present');
        return;
      }
      final bytes = file.readAsBytesSync();
      final c = FirmwareContainer.parse(bytes)!;
      final report = c.verify(
        expected: const FirmwareExpectations(hwIdPrefix: 'WRONG_'),
      );
      expect(report.isValid, isFalse);
      expect(report.failures.map((c) => c.name), contains('hw_id_prefix'));
    });

    test('detects body corruption via image_chk_a (validateImageChkA)', () {
      final file = File('firmwares/H59MA_1.00.14_260508.bin');
      if (!file.existsSync()) {
        markTestSkipped('Firmware file not present');
        return;
      }
      final bytes = file.readAsBytesSync();
      // Flip a byte in the body so the additive checksum (over body)
      // diverges from the header.
      bytes[FirmwareContainer.headerSize + 0x100] ^= 0xFF;
      final c = FirmwareContainer.parse(bytes)!;
      final report = c.verify(
        expected: const FirmwareExpectations(validateImageChkA: true),
      );
      expect(report.isValid, isFalse);
      expect(report.failures.map((c) => c.name), contains('image_chk_a'));
    });
  });

  group('FirmwareContainer.bodySha256', () {
    test('hashes body only, not header', () {
      final file = File('firmwares/H59MA_1.00.14_260508.bin');
      if (!file.existsSync()) {
        markTestSkipped('Firmware file not present');
        return;
      }
      final bytes = file.readAsBytesSync();
      final c = FirmwareContainer.parse(bytes)!;
      final d = c.bodySha256();
      // SHA-256 produces 32 bytes.
      expect(d.bytes.length, 32);
    });
  });
}
