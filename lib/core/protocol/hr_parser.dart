import 'dart:typed_data';

/// Pure parsers for the HR-bearing Channel-A opcodes (see PROTOCOL.md §4.3).
///
/// Kept separate from [WatchManager] so the wire-format logic is unit-testable
/// without a live device.
class HrParser {
  HrParser._();

  /// Inclusive range shared by every HR-bearing opcode. Anything outside is
  /// treated as "not a bpm" — a warming sensor, an end-of-stream marker, or
  /// junk padding. This is intentionally tight: cheap H59MA-class firmwares
  /// leave the byte at 0x00 / 0xFF before the sensor locks.
  static bool isPlausibleBpm(int v) => v >= 30 && v <= 240;

  /// `RealTimeHeartRate` (0x1e): `pl[0]` is the instantaneous bpm.
  ///
  /// Returns `null` if the payload isn't a valid HR sample. Indices are
  /// 8-bit-unsigned — Dart treats [Uint8List] reads as signed ints by default,
  /// so we mask explicitly before the range check.
  static int? parseRealtime(Uint8List pl) {
    if (pl.isEmpty) return null;
    final bpm = pl[0] & 0xFF;
    return isPlausibleBpm(bpm) ? bpm : null;
  }

  /// `StartHeartRateRsp` (0x69): `[0]=type, [1]=errCode, [2]=value`.
  ///
  /// Per the smali (StartHeartRateRsp.acceptData), `value` is the 8-bit
  /// unsigned bpm read at `pl[2]`, but `0`/`1` mean "in progress" and
  /// `errCode != 0` means the session failed — neither is a real bpm.
  static HrStartMeasureResult? parseStartMeasureReply(Uint8List pl) {
    if (pl.length < 3) return null;
    final type = pl[0] & 0xFF;
    final err = pl[1] & 0xFF;
    final raw = pl[2] & 0xFF;
    final bpm = (err == 0 && isPlausibleBpm(raw)) ? raw : null;
    return HrStartMeasureResult(type: type, err: err, bpm: bpm);
  }

  /// `deviceNotify` (0x73) / `deviceSportNotify` (0x78) carry
  /// `dataType + loadData`. Some firmwares push live HR on these opcodes
  /// when the canonical 0x1e path is unsupported — try the two byte
  /// offsets where HR has been observed on H59MA-class firmwares and return
  /// the first plausible value.
  static int? parseDeviceNotify(Uint8List pl) {
    if (pl.length < 2) return null;
    for (final off in const [1, 2]) {
      if (pl.length <= off) continue;
      final bpm = pl[off] & 0xFF;
      if (isPlausibleBpm(bpm)) return bpm;
    }
    return null;
  }
}

/// Parsed shape of a `StartHeartRateRsp` (0x69) reply.
class HrStartMeasureResult {
  const HrStartMeasureResult({required this.type, required this.err, this.bpm});
  final int type;
  final int err;

  /// The bpm, or `null` when [err] != 0 or the value isn't a plausible HR.
  final int? bpm;
}
