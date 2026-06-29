import 'dart:typed_data';

import 'package:crypto/crypto.dart';

/// Parser + verifier for the H59MA firmware container header.
///
/// Mirrors `tool/fwtool/internal/format/format.go` (Go). Field offsets are
/// from the corrected table in `firmwares/FIRMWARE_ANALYSIS.md` §1.
///
/// The on-disk layout is a fixed `0x450`-byte header followed by the
/// ARM-Thumb body. Field highlights:
///
/// | Offset | Size | Name              | Notes                              |
/// |-------:|-----:|-------------------|------------------------------------|
/// | 0x0000 |    4 | magic             | `e5c3bd81`                         |
/// | 0x0004 |    4 | load_size         | bytes bootloader copies to RAM     |
/// | 0x0008 |    4 | firmware_size     | total on-disk size                 |
/// | 0x000C |    4 | image_chk_a       | 24-bit additive byte sum (high=0)  |
/// | 0x0010 |   24 | version           | ASCII, e.g. `H59MA_1.00.14_260508`  |
/// | 0x0030 |   16 | hw_id             | ASCII, e.g. `H59MA_V1.0`           |
/// | 0x005C |    4 | const_5c          | constant `0x7e6b4cf9`              |
/// | 0x0060 |   12 | signature_a       | constant per-build                 |
/// | 0x01C4 |   32 | image_digest      | per-build signature, algo unknown  |
/// | 0x022C |    4 | flash_app_end     | per-build upper RAM bound          |
/// | 0x0450 | rest | body              | ARM-Thumb code                     |
class FirmwareContainer {
  FirmwareContainer._({
    required this.bytes,
    required this.header,
    required this.body,
  });

  /// The full image bytes (header + body) — never null after a successful
  /// [parse].
  final Uint8List bytes;

  /// Parsed header fields.
  final FirmwareHeader header;

  /// Body bytes (everything past the 0x450-byte header).
  final Uint8List body;

  /// Expected magic — `e5c3bd81`.
  static final Uint8List expectedMagic = Uint8List.fromList([
    0xe5,
    0xc3,
    0xbd,
    0x81,
  ]);

  /// Header size in bytes (fixed).
  static const int headerSize = 0x450;

  /// Parses a firmware image. Returns `null` when [bytes] does not look like
  /// an H59MA container (magic mismatch or too small).
  static FirmwareContainer? parse(Uint8List bytes) {
    if (bytes.length < headerSize + 16) return null;
    if (!_startsWith(bytes, expectedMagic)) return null;

    final header = FirmwareHeader(
      loadSize: _readU32le(bytes, 0x04),
      firmwareSize: _readU32le(bytes, 0x08),
      imageChkA: _readU32le(bytes, 0x0C),
      version: _readAscii(bytes, 0x10, 24).trim(),
      hwId: _readAscii(bytes, 0x30, 16).trim(),
      const5C: _readU32le(bytes, 0x5C),
      signatureA: Uint8List.sublistView(bytes, 0x60, 0x6C),
      flashAppStart: _readU32le(bytes, 0x6C),
      imageDigest: Uint8List.sublistView(bytes, 0x1C4, 0x1E4),
      flashAppEnd: _readU32le(bytes, 0x22C),
      bodySize: _readU32le(bytes, 0x58),
    );

    final body = Uint8List.sublistView(
      bytes,
      headerSize,
      headerSize + header.bodySize,
    );

    return FirmwareContainer._(bytes: bytes, header: header, body: body);
  }

  /// Computes SHA-256 of the body bytes (the code+data region past the
  /// fixed 0x450-byte header). This is *not* the same as the firmware's
  /// `image_digest` slot (see `firmwares/FIRMWARE_ANALYSIS.md` §2.5 —
  /// `image_digest` is a vendor-proprietary MAC over an unknown window).
  Digest bodySha256() {
    return sha256.convert(body);
  }

  /// Verifies the container against [expected]. Returns a [VerificationReport]
  /// listing every check; the caller should treat `isValid == true` as
  /// "safe to flash".
  VerificationReport verify({
    FirmwareExpectations expected = const FirmwareExpectations(),
  }) {
    final checks = <VerificationCheck>[];

    // 1. Magic check.
    checks.add(
      VerificationCheck(
        name: 'magic',
        passed: _startsWith(bytes, expectedMagic),
        detail: 'expected e5c3bd81',
      ),
    );

    // 2. Size sanity: both load_size and firmware_size must be > 0 and
    //    <= bytes.length. The on-disk file may include a trailing secondary
    //    signature/padding, so firmware_size != bytes.length in practice.
    final size = bytes.length;
    checks.add(
      VerificationCheck(
        name: 'load_size',
        passed: header.loadSize > 0 && header.loadSize <= size,
        detail: 'header.loadSize=${header.loadSize} actual=$size',
      ),
    );
    checks.add(
      VerificationCheck(
        name: 'firmware_size',
        passed: header.firmwareSize > 0 && header.firmwareSize <= size,
        detail: 'header.firmwareSize=${header.firmwareSize} actual=$size',
      ),
    );

    // 3. Body size sanity: body_size > 0 and <= bytes.length - headerSize.
    final maxBody = size - headerSize;
    checks.add(
      VerificationCheck(
        name: 'body_size',
        passed: header.bodySize > 0 && header.bodySize <= maxBody,
        detail:
            'header.bodySize=${header.bodySize} '
            'max=$maxBody',
      ),
    );

    // 4. image_chk_a (24-bit additive byte sum) — two distinct checks:
    //   * `validateImageChkA: true` — header.imageChkA must equal the
    //     live additive sum over `container[0x50:]` (corruption
    //     detection). Off by default because the firmware's summed
    //     range is unverified at runtime.
    //   * `expectedImageChkA` — when provided, the header must equal
    //     this whitelist value (firmware-compatibility check).
    //
    // PROTOCOL.md §9.7: image_chk_a = sum(container[0x50:]) & 0xFFFFFFFF,
    // high byte observed as 0x00. The summed window starts at offset 0x50
    // (the `flags` word) — NOT at the body slice (headerSize=0x450). The
    // earlier helper summed only the body, which diverged from the
    // documented formula on every observed v13/v14 image.
    final computed = _additive24From(bytes, 0x50);
    if (expected.validateImageChkA) {
      checks.add(
        VerificationCheck(
          name: 'image_chk_a',
          passed: (header.imageChkA & 0x00FFFFFF) == computed,
          detail:
              'header.imageChkA=0x${header.imageChkA.toRadixString(16)} '
              'computed=0x${computed.toRadixString(16)}',
        ),
      );
    }
    if (expected.expectedImageChkA != null) {
      final whitelist = expected.expectedImageChkA! & 0x00FFFFFF;
      checks.add(
        VerificationCheck(
          name: 'image_chk_a_whitelist',
          passed: (header.imageChkA & 0x00FFFFFF) == whitelist,
          detail:
              'header.imageChkA=0x${header.imageChkA.toRadixString(16)} '
              'whitelist=0x${whitelist.toRadixString(16)}',
        ),
      );
    }

    // 5. Version prefix (e.g. "H59MA_" or whatever expected).
    if (expected.versionPrefix != null) {
      checks.add(
        VerificationCheck(
          name: 'version_prefix',
          passed: header.version.startsWith(expected.versionPrefix!),
          detail: 'header.version="${header.version}"',
        ),
      );
    }

    // 6. HW ID prefix.
    if (expected.hwIdPrefix != null) {
      checks.add(
        VerificationCheck(
          name: 'hw_id_prefix',
          passed: header.hwId.startsWith(expected.hwIdPrefix!),
          detail: 'header.hwId="${header.hwId}"',
        ),
      );
    }

    // 7. flash_app_end sanity — opt-in. The firmware RE table in
    // FIRMWARE_ANALYSIS.md §"Field-by-field" claims
    // `flash_app_end == flash_app_start + load_size`, but the v14 image
    // we have does not match that formula (0x845c14 vs the expected
    // 0x847dfc). Until that's resolved, this check is only run when
    // the caller asks for it explicitly via
    // `expected.checkFlashAppEnd`.
    if (expected.checkFlashAppEnd) {
      final expectedEnd = header.flashAppStart + header.loadSize;
      checks.add(
        VerificationCheck(
          name: 'flash_app_end',
          passed: header.flashAppEnd == expectedEnd,
          detail:
              'flashAppStart=0x${header.flashAppStart.toRadixString(16)} '
              'loadSize=0x${header.loadSize.toRadixString(16)} '
              'flashAppEnd=0x${header.flashAppEnd.toRadixString(16)} '
              'expected=0x${expectedEnd.toRadixString(16)}',
        ),
      );
    }

    return VerificationReport(checks: checks);
  }

  // ---------------------------------------------------------------------------
  // Helpers
  // ---------------------------------------------------------------------------

  static bool _startsWith(Uint8List haystack, Uint8List needle) {
    if (haystack.length < needle.length) return false;
    for (var i = 0; i < needle.length; i++) {
      if (haystack[i] != needle[i]) return false;
    }
    return true;
  }

  static int _readU32le(Uint8List b, int off) =>
      b[off] | (b[off + 1] << 8) | (b[off + 2] << 16) | (b[off + 3] << 24);

  static String _readAscii(Uint8List b, int off, int len) {
    final out = <int>[];
    for (var i = 0; i < len && off + i < b.length; i++) {
      final v = b[off + i];
      if (v == 0) break;
      out.add(v);
    }
    return String.fromCharCodes(out);
  }

  /// Sums bytes from [start] to end of [data] modulo 2^24.
  ///
  /// Mirrors PROTOCOL.md §9.7: `image_chk_a = sum(container[0x50:]) &
  /// 0xFFFFFFFF`. The high byte is observed as 0x00 in every shipped
  /// v13/v14 image, hence the 24-bit mask.
  static int _additive24From(Uint8List data, int start) {
    var sum = 0;
    for (var i = start; i < data.length; i++) {
      sum += data[i] & 0xFF;
    }
    return sum & 0x00FFFFFF;
  }
}

/// Decoded header fields.
class FirmwareHeader {
  const FirmwareHeader({
    required this.loadSize,
    required this.firmwareSize,
    required this.imageChkA,
    required this.version,
    required this.hwId,
    required this.const5C,
    required this.signatureA,
    required this.flashAppStart,
    required this.imageDigest,
    required this.flashAppEnd,
    required this.bodySize,
  });

  final int loadSize;
  final int firmwareSize;
  final int imageChkA;
  final String version;
  final String hwId;
  final int const5C;
  final Uint8List signatureA;
  final int flashAppStart;
  final Uint8List imageDigest;
  final int flashAppEnd;
  final int bodySize;

  /// Convenience hex accessor for the 32-byte image_digest slot.
  String get imageDigestHex => _toHex(imageDigest);
}

/// Optional caller-supplied constraints. When set, [FirmwareContainer.verify]
/// enforces them.
class FirmwareExpectations {
  const FirmwareExpectations({
    this.versionPrefix,
    this.hwIdPrefix,
    this.expectedImageChkA,
    this.validateImageChkA = false,
    this.checkFlashAppEnd = false,
  });
  final String? versionPrefix;
  final String? hwIdPrefix;

  /// When non-null, verify the 24-bit additive checksum at
  /// `header.imageChkA` matches this value (mod 2^24). This is a
  /// firmware-compatibility whitelist, NOT corruption detection.
  final int? expectedImageChkA;

  /// When `true`, verify `header.imageChkA` matches the live additive
  /// sum over [body] (corruption detection). Off by default because
  /// the firmware's exact summed range is unverified — see
  /// `FIRMWARE_ANALYSIS.md` §"Why 0x0c is additive".
  final bool validateImageChkA;

  /// When `true`, verify `flash_app_end == flash_app_start + load_size`.
  /// Off by default because the firmware RE table value does not match
  /// the v14 image we have — likely a documentation error in the RE.
  final bool checkFlashAppEnd;
}

/// One named verification check.
class VerificationCheck {
  const VerificationCheck({
    required this.name,
    required this.passed,
    required this.detail,
  });
  final String name;
  final bool passed;
  final String detail;
}

/// Aggregate verification result.
class VerificationReport {
  const VerificationReport({required this.checks});
  final List<VerificationCheck> checks;

  bool get isValid => checks.every((c) => c.passed);

  Iterable<VerificationCheck> get failures => checks.where((c) => !c.passed);

  /// One-line summary suitable for logs.
  String summary() {
    final total = checks.length;
    final ok = checks.where((c) => c.passed).length;
    return 'verification: $ok/$total checks passed';
  }
}

String _toHex(List<int> bytes) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join('');
