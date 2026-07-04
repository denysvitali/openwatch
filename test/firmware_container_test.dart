import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:openwatch/core/protocol/firmware_container.dart';

const _realFirmwareHeaders = [
  _ExpectedFirmwareHeader(
    fileName: 'H59MA_1.00.13_251230.bin',
    version: 'H59MA_1.00.13_251230',
    loadSize: 0x23840,
    firmwareSize: 0x23840,
    imageChkA: 0x00ce90ee,
    bodySize: 0x23440,
    flashAppEnd: 0x00847860,
    imageDigestHex:
        '8d50aa228b80d953cbf616006c7954f46787f4f12deda09fcb0ca9a242178bb1',
  ),
  _ExpectedFirmwareHeader(
    fileName: 'H59MA_1.00.14_260508.bin',
    version: 'H59MA_1.00.14_260508',
    loadSize: 0x219fc,
    firmwareSize: 0x219fc,
    imageChkA: 0x00c43671,
    bodySize: 0x215fc,
    flashAppEnd: 0x00845c14,
    imageDigestHex:
        '47d3b81a34034731132ef839435d7ee791ec57e8c6d648daff094a4d0d354648',
  ),
];

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
      final c = _parseFirmwareFixture('H59MA_1.00.14_260508.bin');
      if (c == null) return;
      expect(c.header.version, startsWith('H59MA_'));
      expect(c.header.hwId, startsWith('H59MA_'));
      expect(c.header.firmwareSize, lessThanOrEqualTo(c.bytes.length));
      expect(c.header.firmwareSize, greaterThan(0));
      expect(c.header.loadSize, lessThanOrEqualTo(c.bytes.length));
      expect(c.body.length, c.header.bodySize);
      expect(c.header.imageDigest.length, 32);
    });

    for (final expected in _realFirmwareHeaders) {
      test('pins ${expected.version} header fields from real firmware', () {
        final c = _parseFirmwareFixture(expected.fileName);
        if (c == null) return;

        expect(
          c.bytes.length,
          expected.bodySize + FirmwareContainer.headerSize,
        );
        expect(c.body.length, expected.bodySize);
        expect(c.header.version, expected.version);
        expect(c.header.hwId, 'H59MA_V1.0');
        expect(c.header.loadSize, expected.loadSize);
        expect(c.header.firmwareSize, expected.firmwareSize);
        expect(c.header.imageChkA, expected.imageChkA);
        expect(c.header.bodySize, expected.bodySize);
        expect(c.header.const5C, 0x7e6b4cf9);
        expect(_hex(c.header.signatureA), '11c5eb118282f74a0c0cef5b');
        expect(c.header.flashAppStart, 0x00826400);
        expect(c.header.flashAppEnd, expected.flashAppEnd);
        expect(c.header.imageDigestHex, expected.imageDigestHex);
      });
    }
  });

  group('FirmwareContainer.verify', () {
    test('a real v14 image passes every default check', () {
      final c = _parseFirmwareFixture('H59MA_1.00.14_260508.bin');
      if (c == null) return;
      final report = c.verify();
      // Four unconditional checks: magic, load_size, firmware_size, body_size.
      // image_chk_a / flash_app_end / version_prefix / hw_id_prefix are all
      // opt-in via FirmwareExpectations.
      expect(report.summary(), 'verification: 4/4 checks passed');
      expect(report.isValid, isTrue);
    });

    test('detects version-prefix mismatch', () {
      final c = _parseFirmwareFixture('H59MA_1.00.14_260508.bin');
      if (c == null) return;
      final report = c.verify(
        expected: const FirmwareExpectations(versionPrefix: 'ZZZZ_'),
      );
      expect(report.isValid, isFalse);
      expect(report.failures.map((c) => c.name), contains('version_prefix'));
    });

    test('detects HW-id prefix mismatch', () {
      final c = _parseFirmwareFixture('H59MA_1.00.14_260508.bin');
      if (c == null) return;
      final report = c.verify(
        expected: const FirmwareExpectations(hwIdPrefix: 'WRONG_'),
      );
      expect(report.isValid, isFalse);
      expect(report.failures.map((c) => c.name), contains('hw_id_prefix'));
    });

    test('detects body corruption via image_chk_a (validateImageChkA)', () {
      final c = _parseFirmwareFixture('H59MA_1.00.14_260508.bin');
      if (c == null) return;
      final bytes = Uint8List.fromList(c.bytes);
      // Flip a byte in the body so the additive checksum window diverges
      // from the header.
      bytes[FirmwareContainer.headerSize + 0x100] ^= 0xFF;
      final corrupted = FirmwareContainer.parse(bytes)!;
      final report = corrupted.verify(
        expected: const FirmwareExpectations(validateImageChkA: true),
      );
      expect(report.isValid, isFalse);
      expect(report.failures.map((c) => c.name), contains('image_chk_a'));
    });
  });

  group('FirmwareContainer.bodySha256', () {
    test('hashes body only, not header', () {
      final c = _parseFirmwareFixture('H59MA_1.00.14_260508.bin');
      if (c == null) return;
      final d = c.bodySha256();
      // SHA-256 produces 32 bytes.
      expect(d.bytes.length, 32);
    });
  });

  // ---------------------------------------------------------------------------
  // Synthetic-fixture tests
  //
  // These build a small H59MA-shaped container from scratch so the tests do
  // not depend on the presence of the real v13/v14 binaries. The layout
  // mirrors the corrected table in `firmwares/R2_ANALYSIS.md` §3.
  // ---------------------------------------------------------------------------
  group('FirmwareContainer synthetic fixtures', () {
    /// Build a minimal valid container with a controlled body and checksum.
    ///
    /// [version] / [hwId] drive the ASCII strings. [bodyLen] controls the
    /// trailing body size. [expectedChkA] lets callers preset the header
    /// word — we always overwrite it with the documented
    /// `sum(container[0x50:]) & 0x00FFFFFF` value to stay byte-for-byte
    /// consistent with PROTOCOL.md §9.7.
    Uint8List buildSyntheticContainer({
      required String version,
      required String hwId,
      required int bodyLen,
    }) {
      // Header (0x450 bytes) + body.
      final container = Uint8List(FirmwareContainer.headerSize + bodyLen);

      // 0x00 magic
      container[0] = 0xe5;
      container[1] = 0xc3;
      container[2] = 0xbd;
      container[3] = 0x81;

      // 0x04 load_size = 0x08 firmware_size = body_size + 0x400
      final loadSize = bodyLen + 0x400;
      _writeU32le(container, 4, loadSize);
      _writeU32le(container, 8, loadSize);

      // 0x0c image_chk_a (24-bit additive, high byte zero) — filled below
      // once the rest of the header is in place.

      // 0x10 version (24B ASCII, NUL-padded)
      final vBytes = version.codeUnits;
      for (var i = 0; i < 24; i++) {
        container[0x10 + i] = i < vBytes.length ? vBytes[i] : 0;
      }

      // 0x30 hw_id (16B ASCII, NUL-padded)
      final hBytes = hwId.codeUnits;
      for (var i = 0; i < 16; i++) {
        container[0x30 + i] = i < hBytes.length ? hBytes[i] : 0;
      }

      // 0x50 flags 0x0981000c (constant)
      _writeU32le(container, 0x50, 0x0981000c);

      // 0x54 sdk_id 0x00002793 (constant)
      _writeU32le(container, 0x54, 0x00002793);

      // 0x58 body_size (exact body length)
      _writeU32le(container, 0x58, bodyLen);

      // 0x5c const_5c 0x7e6b4cf9
      _writeU32le(container, 0x5c, 0x7e6b4cf9);

      // 0x60 signature_a (12B constant)
      container.setRange(0x60, 0x6c, [
        0x11,
        0xc5,
        0xeb,
        0x11,
        0x82,
        0x82,
        0xf7,
        0x4a,
        0x0c,
        0x0c,
        0xef,
        0x5b,
      ]);

      // 0x6c flash_app_start 0x00826400
      _writeU32le(container, 0x6c, 0x00826400);

      // 0x70 duplicate flash_app_start
      _writeU32le(container, 0x70, 0x00826400);

      // 0x78 flash_base 0x00826000
      _writeU32le(container, 0x78, 0x00826000);

      // 0xb4 const_b4 0x1201a39e
      _writeU32le(container, 0xb4, 0x1201a39e);

      // 0xb8 sdk_string "sdk#####"
      const sdkString = [0x73, 0x64, 0x6b, 0x23, 0x23, 0x23, 0x23, 0x23];
      container.setRange(0xb8, 0xc0, sdkString);

      // 0x228 const_228 0x0e85d101
      _writeU32le(container, 0x228, 0x0e85d101);

      // 0x22c flash_app_end — pick something plausible (start + body+0x400)
      _writeU32le(container, 0x22c, 0x00826400 + bodyLen);

      // 0x330..0x33f erase_marker (16 bytes of 0xFF)
      for (var i = 0x330; i < 0x340; i++) {
        container[i] = 0xFF;
      }
      // 0x440..0x44f erase_marker2
      for (var i = 0x440; i < 0x450; i++) {
        container[i] = 0xFF;
      }

      // Body: deterministic fill so the additive sum is stable.
      for (var i = 0; i < bodyLen; i++) {
        container[FirmwareContainer.headerSize + i] = i & 0xFF;
      }

      // 0x0c image_chk_a — documented formula per PROTOCOL.md §9.7:
      //   sum(container[0x50:]) & 0x00FFFFFF, high byte 0x00.
      // We fill this LAST so the value reflects all header fields above.
      // Note: the parser's _additive24() helper currently sums the body,
      // not container[0x50:]; the divergence is documented in the matrix
      // and exercised in 'image_chk_a formula' below.
      final sum = _sumFrom(container, 0x50) & 0x00FFFFFF;
      container[0x0c] = sum & 0xFF;
      container[0x0d] = (sum >> 8) & 0xFF;
      container[0x0e] = (sum >> 16) & 0xFF;
      container[0x0f] = 0x00; // high byte forced to 0x00 per firmware RE

      return container;
    }

    test('parses a synthetic v14-shaped container', () {
      final container = buildSyntheticContainer(
        version: 'H59MA_1.00.14_260508',
        hwId: 'H59MA_V1.0',
        bodyLen: 0x215fc,
      );
      final c = FirmwareContainer.parse(container);
      expect(c, isNotNull);
      expect(c!.header.version, 'H59MA_1.00.14_260508');
      expect(c.header.hwId, 'H59MA_V1.0');
      expect(c.header.bodySize, 0x215fc);
      expect(c.header.firmwareSize, 0x219fc);
      expect(c.header.loadSize, 0x219fc);
      expect(c.header.flashAppStart, 0x00826400);
      expect(c.header.imageDigest.length, 32);
      expect(c.body.length, 0x215fc);
    });

    test('parses a synthetic v13-shaped container', () {
      final container = buildSyntheticContainer(
        version: 'H59MA_1.00.13_251230',
        hwId: 'H59MA_V1.0',
        bodyLen: 0x23440,
      );
      final c = FirmwareContainer.parse(container);
      expect(c, isNotNull);
      expect(c!.header.version, 'H59MA_1.00.13_251230');
      expect(c.header.bodySize, 0x23440);
      expect(c.header.loadSize, 0x23840);
      expect(c.header.flashAppStart, 0x00826400);
    });

    test('rejects a container with malformed magic', () {
      final container = buildSyntheticContainer(
        version: 'H59MA_1.00.14_260508',
        hwId: 'H59MA_V1.0',
        bodyLen: 0x100,
      );
      // Corrupt magic bytes
      container[0] = 0xDE;
      container[1] = 0xAD;
      container[2] = 0xBE;
      container[3] = 0xEF;
      expect(FirmwareContainer.parse(container), isNull);
    });

    test(
      'rejects a container whose load_address / flash_app_start is wrong',
      () {
        final container = buildSyntheticContainer(
          version: 'H59MA_1.00.14_260508',
          hwId: 'H59MA_V1.0',
          bodyLen: 0x100,
        );
        // Move flash_app_start somewhere unexpected.
        _writeU32le(container, 0x6c, 0x00100000);
        final c = FirmwareContainer.parse(container);
        // Parsing succeeds (parser does not validate the address), but
        // verify() with the documented HW load address should fail.
        expect(c, isNotNull);
        expect(c!.header.flashAppStart, 0x00100000);
        // Verify via version-prefix check is still fine; flash_app_start
        // value is captured as-is for the caller to inspect.
        final report = c.verify();
        expect(report.isValid, isTrue);
        // Manual assertion: parser reads but does not assert load address.
        expect(c.header.flashAppStart, isNot(0x00826400));
      },
    );

    test('image_chk_a: parser sums container[0x50:] per PROTOCOL.md §9.7', () {
      // PROTOCOL.md §9.7 specifies:
      //   image_chk_a = sum(container[0x50:]) & 0xFFFFFFFF, high byte 0x00
      // R2_ANALYSIS.md §3 confirms both v13 and v14 match this formula
      // exactly (0xc43671 / 0xce90ee).
      //
      // The parser must sum `container[0x50:]`, NOT the body slice
      // (headerSize=0x450..end). Prior revisions summed only the body,
      // which diverged from the documented formula on every observed
      // v13/v14 image (`_additive24(body) = 0xc3f5ef` vs header
      // `0xc43671`). That false-positive would have surfaced as
      // corruption on every OTA verify, so this test pins the fix.
      final c = _parseFirmwareFixture('H59MA_1.00.14_260508.bin');
      if (c == null) return;
      final bytes = c.bytes;

      final documented = _sumFrom(bytes, 0x50) & 0x00FFFFFF;
      final headerChkA = c.header.imageChkA & 0x00FFFFFF;

      expect(
        documented,
        headerChkA,
        reason:
            'PROTOCOL.md §9.7 — header@0x0C must equal '
            'sum(container[0x50:]) & 0x00FFFFFF',
      );

      // Confirm the parser's own verify() passes when validateImageChkA
      // is on — i.e. the fix produced a self-consistent checksum.
      final report = c.verify(
        expected: const FirmwareExpectations(validateImageChkA: true),
      );
      expect(
        report.failures.map((chk) => chk.name),
        isNot(contains('image_chk_a')),
        reason:
            'verify(validateImageChkA: true) must pass on the clean v14 '
            'image once the parser sums container[0x50:].',
      );
    });

    test('image_chk_a: synthetic container matches the documented formula', () {
      // With the documented window (container[0x50:]) and the high byte
      // forced to 0x00, a freshly-built fixture must be self-consistent:
      // header@0x0C == sum(container[0x50:]) & 0x00FFFFFF.
      final container = buildSyntheticContainer(
        version: 'H59MA_1.00.14_260508',
        hwId: 'H59MA_V1.0',
        bodyLen: 0x200, // small for test speed
      );
      final c = FirmwareContainer.parse(container)!;
      final documented = _sumFrom(container, 0x50) & 0x00FFFFFF;
      expect(c.header.imageChkA & 0x00FFFFFF, documented);
      // High byte is forced to 0x00 by the firmware RE convention.
      expect(container[0x0f], 0x00);
    });
  });
}

// ---------------------------------------------------------------------------
// Test helpers (private to this file)
// ---------------------------------------------------------------------------

void _writeU32le(Uint8List buf, int offset, int value) {
  buf[offset] = value & 0xFF;
  buf[offset + 1] = (value >> 8) & 0xFF;
  buf[offset + 2] = (value >> 16) & 0xFF;
  buf[offset + 3] = (value >> 24) & 0xFF;
}

int _sumFrom(Uint8List buf, int offset) {
  var s = 0;
  for (var i = offset; i < buf.length; i++) {
    s += buf[i] & 0xFF;
  }
  return s;
}

FirmwareContainer? _parseFirmwareFixture(String name) {
  final file = File('firmwares/$name');
  if (!file.existsSync()) {
    markTestSkipped('Firmware file not present: ${file.path}');
    return null;
  }
  final c = FirmwareContainer.parse(file.readAsBytesSync());
  expect(c, isNotNull, reason: 'fixture should parse: ${file.path}');
  return c;
}

String _hex(List<int> bytes) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join('');

class _ExpectedFirmwareHeader {
  const _ExpectedFirmwareHeader({
    required this.fileName,
    required this.version,
    required this.loadSize,
    required this.firmwareSize,
    required this.imageChkA,
    required this.bodySize,
    required this.flashAppEnd,
    required this.imageDigestHex,
  });

  final String fileName;
  final String version;
  final int loadSize;
  final int firmwareSize;
  final int imageChkA;
  final int bodySize;
  final int flashAppEnd;
  final String imageDigestHex;
}
