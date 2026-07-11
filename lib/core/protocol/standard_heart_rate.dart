/// Decoder for the Bluetooth SIG Heart Rate Measurement characteristic
/// (`0x2A37`).
///
/// The first flag bit selects UINT8 or UINT16 little-endian heart-rate data.
/// Energy-expended and RR-interval fields follow the value and are not needed
/// for the live reading surfaced by OpenWatch.
class StandardHeartRate {
  StandardHeartRate._();

  static int? parse(List<int> data) {
    if (data.length < 2) return null;
    final isUint16 = (data[0] & 0x01) != 0;
    if (isUint16 && data.length < 3) return null;
    final bpm = isUint16 ? data[1] | (data[2] << 8) : data[1];
    return bpm >= 30 && bpm <= 240 ? bpm : null;
  }
}
