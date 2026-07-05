import 'dart:async';
import 'dart:typed_data';

import 'package:flutterrific_opentelemetry/flutterrific_opentelemetry.dart'
    hide Logger;

import '../protocol/codec.dart';
import '../services/app_log.dart';
import '../services/opentelemetry_service.dart';
import 'ble_transport.dart';

final _log = AppLog.instance;

/// Thin wrapper around the vendor `0xFEE7` GATT service's notify/write
/// characteristics.
///
/// Wire format is identical to Channel A: a fixed 16-byte frame whose last
/// byte is the additive 8-bit checksum of bytes `0..14` (use
/// [Codec.buildChannelA] to construct frames). Static H59MA v14 routing shows
/// the published FEE7 write callback packages generic Realtek service events
/// and does not branch to the 16-byte opcode dispatcher; app flows should
/// prefer Channel A unless live captures prove a specific FEE7 write contract.
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
      s._inboundHandler,
      onError: (Object e, StackTrace _) {
        _log.error('fee7', 'inbound error: $e');
      },
    );
    return s;
  }

  // Per-frame consumer span for the 0xFEE7 notify stream. Mirrors the
  // ble.rx span on Channel A/B but tagged with the fee7 channel name so
  // the dispatcher can be analyzed independently.
  void _inboundHandler(Uint8List frame) {
    final span = OpenTelemetryService().startTrace(
      'ble.fee7.rx',
      kind: SpanKind.consumer,
      attributes: {'ble.frame.length': frame.length},
    );
    try {
      _inbound.add(frame);
    } finally {
      span?.end();
    }
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

  /// Send a raw 16-byte frame to the FEE7 write characteristic.
  ///
  /// This is intended for live-capture/probe tooling. Normal app commands use
  /// Channel A because the firmware's FEE7 write callback is not statically
  /// wired to the 16-byte command dispatcher.
  ///
  /// The frame MUST:
  ///   * be exactly 16 bytes;
  ///   * have byte `15` equal to `sum(bytes[0..14]) & 0xFF`.
  ///
  /// Invalid frames raise [ArgumentError] before any BLE write is attempted.
  Future<void> sendCommand(Uint8List frame) {
    // Outbound fee7 command: client span so we can correlate vendor
    // opcodes (SpO2, find-phone, etc.) with any fee7 transport errors.
    final span = OpenTelemetryService().startTrace(
      'ble.fee7.send',
      kind: SpanKind.client,
      attributes: {'ble.opcode': (frame[0] & 0xFF).toRadixString(16)},
    );
    var ok = false;
    try {
      if (!Codec.isValidChannelA(frame)) {
        throw ArgumentError(
          'Fee7Service.sendCommand requires a valid 16-byte frame '
          '(len=${frame.length})',
        );
      }
      final future = _transport.sendFee7(frame);
      ok = true;
      return future;
    } catch (e, stack) {
      span?.recordError(e, stack);
      rethrow;
    } finally {
      span?.end(ok: ok);
    }
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
