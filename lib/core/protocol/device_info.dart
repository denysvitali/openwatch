import 'dart:typed_data';

/// Parser for the H59MA v14 Channel-B `0x5a` device-info / config TLV block.
///
/// Response payload shape (`PROTOCOL.md` §4.8,
/// `GHIDRA_DECOMPILATION.md` §2.7 `FUN_0082f6ec`):
///
/// ```
///   payload[0]    sub-cmd echo (0x01 for query)
///   payload[1]    marker (0x01)
///   payload[2]    TLV count
///   payload[3..]  N × { id u8, len u8, data[len] }
/// ```
///
/// Unknown sub-cmds return the 3-byte generic status
/// `[0x5A, 0x00, 0x00]`; [DeviceInfoConfig.tryParse] returns `null` for
/// that shape so callers can fall back to a status-only path.
class DeviceInfoConfig {
  DeviceInfoConfig._(this.tlvs) : _byId = {for (final t in tlvs) t.id: t.data};

  final List<DeviceInfoTlv> tlvs;
  final Map<int, List<int>> _byId;

  /// Number of TLV entries reported by the watch.
  int get count => tlvs.length;

  /// Decodes a query-response payload.
  ///
  /// Returns `null` if [body] is not the query shape (e.g. the watch
  /// returned the 3-byte `[0x5A, 0x00, 0x00]` generic status, or any
  /// frame whose body is shorter than 3 bytes).
  static DeviceInfoConfig? tryParse(Uint8List body) {
    // Generic status fallback — the firmware emits this 3-byte shape
    // for unknown sub-cmds. Anything starting with `payload[0] != 0x01`
    // or with fewer than 3 bytes cannot be a query response.
    if (body.length < 3) return null;
    if (body[0] != 0x01) return null;
    if (body[1] != 0x01) return null;

    final count = body[2];
    final out = <DeviceInfoTlv>[];
    var i = 3;
    for (var n = 0; n < count; n++) {
      if (i + 2 > body.length) return null; // truncated
      final id = body[i];
      final len = body[i + 1];
      if (i + 2 + len > body.length) return null; // truncated
      final data = Uint8List.sublistView(body, i + 2, i + 2 + len);
      out.add(DeviceInfoTlv(id, data));
      i += 2 + len;
    }
    return DeviceInfoConfig._(out);
  }

  // ---------------------------------------------------------------------------
  // Typed field accessors — one per writable TLV id (PROTOCOL.md §4.8).
  // Each returns `null` when the slot is not present in the query response.
  // ---------------------------------------------------------------------------

  /// TLV id 1 — custom advertised name prefix (max 0x18 B).
  List<int>? get customNamePrefix => _byId[1];

  /// TLV id 2 — BLE address override (max 6 B).
  List<int>? get bleAddress => _byId[2];

  /// TLV id 3 — device-info string slot (max 0x14 B).
  List<int>? get infoSlot3 => _byId[3];

  /// TLV id 4 — device-info string slot (max 0x10 B).
  List<int>? get infoSlot4 => _byId[4];

  /// TLV id 5 — device-info string slot (max 0x10 B).
  List<int>? get infoSlot5 => _byId[5];

  /// TLV id 6 — device-info string slot (max 0x08 B).
  List<int>? get infoSlot6 => _byId[6];

  /// TLV id 7 — name-format control byte (1 B).
  int? get nameFormat {
    final v = _byId[7];
    if (v == null || v.isEmpty) return null;
    return v.first & 0xFF;
  }
}

/// Single TLV entry inside a [DeviceInfoConfig] block.
class DeviceInfoTlv {
  DeviceInfoTlv(this.id, this.data);

  final int id;
  final Uint8List data;
}
