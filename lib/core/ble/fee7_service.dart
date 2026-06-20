import 'dart:async';
import 'dart:typed_data';

import '../protocol/codec.dart';
import '../services/app_log.dart';
import 'ble_transport.dart';

final _log = AppLog.instance;

/// Thin wrapper around the vendor `0xFEE7` GATT service that exposes a
/// forward-only 16-byte command channel parallel to Channel A
/// (see `GHIDRA_DECOMPILATION.md` §8 and `firmwares/R2_ANALYSIS.md` §7).
///
/// Wire format is identical to Channel A: a fixed 16-byte frame whose last
/// byte is the additive 8-bit checksum of bytes `0..14` (use
/// [Codec.buildChannelA] to construct frames). Unlike Channel A, the fee7
/// service does not gate writes on a "link ready" handshake; the device's
/// GATT write handler is always live once the characteristic is discovered.
///
/// The class is intentionally narrow — it only validates frame shape and
/// funnels traffic through the transport's existing `_fee7Write` /
/// `_fee7Notify` characteristics. Higher-level semantics (opcode dispatch,
/// response decoding) live in [Fee7Dispatcher].
class Fee7Service {
  Fee7Service._(this._transport);

  /// Factory: wraps an already-connected [Fee7Host]. The caller must
  /// have completed `connect()` so the underlying write/notify
  /// characteristics are populated.
  factory Fee7Service.attach(Fee7Host host) {
    final s = Fee7Service._(host);
    s._sub = host.fee7Inbound.listen(
      s._inbound.add,
      onError: (Object e, StackTrace _) {
        _log.error('fee7', 'inbound error: $e');
      },
    );
    return s;
  }

  final Fee7Host _transport;
  late final StreamSubscription<Uint8List> _sub;

  final _inbound = StreamController<Uint8List>.broadcast();

  /// All 16-byte inbound frames received from the device. Consumers should
  /// also use [Fee7Dispatcher] for typed opcode routing; this stream is
  /// useful for raw observability.
  Stream<Uint8List> get inboundStream => _inbound.stream;

  /// Whether the underlying transport has a usable `0xFEE7` write char.
  bool get isAvailable => _transport.hasFee7Write;

  /// Send a 16-byte frame to the device.
  ///
  /// The frame MUST:
  ///   * be exactly 16 bytes;
  ///   * have byte `15` equal to `sum(bytes[0..14]) & 0xFF`.
  ///
  /// Invalid frames raise [ArgumentError] before any BLE write is attempted.
  Future<void> sendCommand(Uint8List frame) {
    if (frame.length != Codec.buildChannelA(0).length) {
      throw ArgumentError(
        'Fee7Service.sendCommand requires a 16-byte frame (got ${frame.length})',
      );
    }
    if (!Codec.isValidChannelA(frame)) {
      throw ArgumentError('Fee7Service.sendCommand: frame checksum invalid');
    }
    return _transport.sendFee7(frame);
  }

  /// Detach the inbound subscription. Call once when tearing the link down.
  Future<void> dispose() async {
    await _sub.cancel();
    if (!_inbound.isClosed) await _inbound.close();
  }
}

/// Minimal host surface needed by [Fee7Service].
///
/// [BleTransport] implements this implicitly (it declares the matching
/// getters/method). Test stubs can implement this directly without pulling
/// in the entire BLE transport surface.
abstract class Fee7Host {
  Stream<Uint8List> get fee7Inbound;
  bool get hasFee7Write;
  Future<void> sendFee7(Uint8List frame);
}
