import 'dart:typed_data';

import '../ble/ble_constants.dart';

/// Low-level frame codecs for both BLE channels (see `PROTOCOL.md` §3).
///
/// These are pure functions over bytes — no BLE or async — so they are fully
/// unit-testable without a device.
class Codec {
  Codec._();

  static const int errorFlag = 0x80;

  // ---------------------------------------------------------------------------
  // Channel A — fixed 16-byte command frames + additive 8-bit checksum.
  // ---------------------------------------------------------------------------

  /// Builds a Channel-A frame: `[opcode][subData(≤14, zero-padded)][checksum]`.
  static Uint8List buildChannelA(int opcode, [List<int> subData = const []]) {
    final buf = Uint8List(BleUuids.channelAFrameLength);
    buf[0] = opcode & 0xFF;
    final n = subData.length > 14 ? 14 : subData.length;
    for (var i = 0; i < n; i++) {
      buf[1 + i] = subData[i] & 0xFF;
    }
    buf[15] = _sum8(buf, 0, 15);
    return buf;
  }

  /// Validates a received Channel-A frame: exactly 16 bytes and checksum matches.
  static bool isValidChannelA(Uint8List frame) {
    if (frame.length != BleUuids.channelAFrameLength) return false;
    return _sum8(frame, 0, 15) == frame[15];
  }

  /// The base opcode of a received frame, with the error flag stripped.
  ///
  /// Channel-A semantics: the top bit (`0x80`) is the device-side error
  /// flag; this method removes it before returning so callers see the
  /// base opcode (`0x00..0x7f`). For protocols where the top bit is part
  /// of the opcode namespace — the vendor `0xFEE7` channel is dense in
  /// `0x80..0xff`, see `GHIDRA_DECOMPILATION.md` §8 — use [rxOpcodeRaw].
  static int rxOpcode(Uint8List frame) => frame[0] & ~errorFlag;

  /// The raw opcode byte with no error-flag stripping. Use this for
  /// protocols where the top bit is part of the opcode namespace (the
  /// vendor `0xFEE7` channel's opcode table is dense in `0x80..0xff`,
  /// see `GHIDRA_DECOMPILATION.md` §8).
  static int rxOpcodeRaw(Uint8List frame) => frame[0] & 0xFF;

  /// Whether the device flagged an error on this response (top bit of opcode).
  static bool rxIsError(Uint8List frame) => (frame[0] & errorFlag) != 0;

  /// The payload of a received Channel-A frame: `bytes[1..14]`.
  /// `payload[0]` corresponds to frame `byte[1]` (first subData byte).
  static Uint8List rxPayload(Uint8List frame) =>
      Uint8List.sublistView(frame, 1, 15);

  static int _sum8(Uint8List b, int start, int end) {
    var sum = 0;
    for (var i = start; i < end; i++) {
      sum += b[i];
    }
    return sum & 0xFF;
  }

  // ---------------------------------------------------------------------------
  // Channel B — `0xBC` magic, u16 LE length, u16 LE CRC16 of payload only.
  // ---------------------------------------------------------------------------

  static const int channelBMagic = 0xBC;

  /// Builds an unsliced Channel-B frame. Empty payload uses the
  /// `FF FF FF FF` sentinel in place of the length+CRC fields.
  static Uint8List buildChannelB(int cmd, [List<int> payload = const []]) {
    final b = BytesBuilder();
    b.addByte(channelBMagic);
    b.addByte(cmd & 0xFF);
    if (payload.isEmpty) {
      b.add(const [0xFF, 0xFF, 0xFF, 0xFF]);
    } else {
      final len = payload.length;
      b.add([len & 0xFF, (len >> 8) & 0xFF]);
      final crc = crc16(payload);
      b.add([crc & 0xFF, (crc >> 8) & 0xFF]);
      b.add(payload);
    }
    return b.toBytes();
  }

  /// Validates the header of a received Channel-B frame and that the CRC16 over
  /// its payload matches. Returns the payload (`bytes[6..]`) or null if invalid.
  static Uint8List? rxChannelBPayload(Uint8List frame) {
    if (frame.length < 6 || frame[0] != channelBMagic) return null;
    final len = frame[2] | (frame[3] << 8);
    if (frame.length - 6 < len) return null;
    final payload = Uint8List.sublistView(frame, 6, 6 + len);
    final crc = frame[4] | (frame[5] << 8);
    if (crc16(payload) != crc) return null;
    return payload;
  }

  static int rxChannelBCmd(Uint8List frame) => frame[1];

  // ---------------------------------------------------------------------------
  // CRC-16/IBM (Modbus-style reflected, poly 0xA001) — used by Channel B.
  // ---------------------------------------------------------------------------

  static int crc16(List<int> data) {
    var crc = 0xFFFF;
    for (final byte in data) {
      crc ^= byte & 0xFF;
      for (var i = 0; i < 8; i++) {
        if ((crc & 1) != 0) {
          crc = (crc >> 1) ^ 0xA001;
        } else {
          crc >>= 1;
        }
      }
    }
    return crc & 0xFFFF;
  }

  // ---------------------------------------------------------------------------
  // BCD helpers — time fields use BCD; year = BCD + 2000.
  // ---------------------------------------------------------------------------

  static int toBcd(int value) => ((value ~/ 10) << 4) | (value % 10);

  static int fromBcd(int bcd) => ((bcd >> 4) & 0x0F) * 10 + (bcd & 0x0F);

  // ---------------------------------------------------------------------------
  // Little-endian integer helpers.
  // ---------------------------------------------------------------------------

  static List<int> u32le(int v) => [
        v & 0xFF,
        (v >> 8) & 0xFF,
        (v >> 16) & 0xFF,
        (v >> 24) & 0xFF,
      ];

  static List<int> u24le(int v) => [
        v & 0xFF,
        (v >> 8) & 0xFF,
        (v >> 16) & 0xFF,
      ];

  static List<int> u16le(int v) => [v & 0xFF, (v >> 8) & 0xFF];

  static int readU16le(List<int> b, int off) => b[off] | (b[off + 1] << 8);

  static int readU24le(List<int> b, int off) =>
      b[off] | (b[off + 1] << 8) | (b[off + 2] << 16);

  static int readU32le(List<int> b, int off) =>
      b[off] | (b[off + 1] << 8) | (b[off + 2] << 16) | (b[off + 3] << 24);

  static int readU24be(List<int> b, int off) =>
      (b[off] << 16) | (b[off + 1] << 8) | b[off + 2];

  static int readU32be(List<int> b, int off) =>
      (b[off] << 24) | (b[off + 1] << 16) | (b[off + 2] << 8) | b[off + 3];
}
