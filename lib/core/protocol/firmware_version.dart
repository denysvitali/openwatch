import 'dart:typed_data';

/// Parser for the firmware revision string returned by the BLE Device
/// Information characteristic `0x2A26`.
///
/// The on-wire value is a short ASCII string such as `H59MA_1.00.13`. The full
/// filename in the local firmware cache (see `firmware_service.dart`) follows
/// the wider convention `<hw>_<ver>_<build>`, e.g. `H59MA_1.00.13_251230`.
///
/// Use [parse] to get a structured view, or [pretty] for a short display
/// string with the hardware prefix stripped (e.g. `1.00.13`).
class FirmwareVersion {
  const FirmwareVersion({
    required this.raw,
    required this.hardwareId,
    required this.version,
  });

  /// The original revision string, trimmed.
  final String raw;

  /// Hardware identifier prefix (everything before the first `_`).
  /// Empty when the string does not follow the `<hw>_<ver>` convention.
  final String hardwareId;

  /// The semantic version portion (e.g. `1.00.13`), or `null` when the string
  /// does not contain a recognisable `digits[.digits…]` segment.
  final String? version;

  /// Short display string: version when known, otherwise the raw value.
  String get pretty => version ?? raw;

  /// True when both the hardware prefix and the semantic version are present.
  bool get isStructured => hardwareId.isNotEmpty && version != null;

  /// Parses a UTF-8 / ASCII firmware revision string.
  ///
  /// Accepts:
  ///   `H59MA_1.00.13`
  ///   `H59MA_1.00.13_251230` (extra `_`-separated tail is tolerated)
  ///   `1.00.13`             (no hardware prefix)
  ///   `""`                  (returns the empty raw value)
  static FirmwareVersion parse(String raw) {
    final trimmed = raw.trim();
    if (trimmed.isEmpty) {
      return const FirmwareVersion(
        raw: '',
        hardwareId: '',
        version: null,
      );
    }

    final parts = trimmed.split('_');
    String hardwareId = '';
    String? version;

    for (final part in parts) {
      final candidate = _extractVersion(part);
      if (candidate != null) {
        version = candidate;
        break;
      }
      // First non-version segment before a version becomes the hardware id.
      if (hardwareId.isEmpty) hardwareId = part;
    }

    return FirmwareVersion(
      raw: trimmed,
      hardwareId: hardwareId,
      version: version,
    );
  }

  /// Convenience: parse a `Uint8List` (BLE characteristic value).
  static FirmwareVersion fromBytes(Uint8List bytes) =>
      parse(String.fromCharCodes(bytes).trim());

  static String? _extractVersion(String segment) {
    if (segment.isEmpty) return null;
    // Match one or more digits optionally followed by ".digits" groups.
    final re = RegExp(r'^\d+(?:\.\d+)*$');
    return re.hasMatch(segment) ? segment : null;
  }
}
