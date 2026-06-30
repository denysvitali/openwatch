import 'dart:async';
import 'dart:typed_data';

import 'package:openwatch/core/ble/ble_transport.dart';

/// Shared [BleTransport] test double used across the protocol-layer test
/// suite (dispatchers, parsers, `HistorySync`, `ProtocolHub`, the DFU
/// flasher, …).
///
/// Exposes the inbound stream controllers and outbound recording lists
/// every test in `test/` needs, so each test file no longer has to
/// hand-roll its own `implements BleTransport` stub. Anything not
/// explicitly overridden below (e.g. `state`, `dispose()`, `connect()`)
/// falls through [noSuchMethod] and returns `null` — harmless for code
/// under test that never touches those members.
class FakeBleTransport implements BleTransport {
  final inA = StreamController<Uint8List>.broadcast();
  final inB = StreamController<Uint8List>.broadcast();
  final fee7In = StreamController<Uint8List>.broadcast();

  /// Every frame handed to [sendA], in order.
  final sentA = <Uint8List>[];

  /// Every frame handed to [sendB], in order.
  final sentB = <Uint8List>[];

  /// Every frame handed to [sendFee7], in order.
  final sentFee7 = <Uint8List>[];

  /// Whether the vendor `0xFEE7` write characteristic is "discovered" on
  /// this fake link. Defaults to `true`; flip to `false` to exercise the
  /// no-fee7 code path.
  @override
  bool hasFee7Write = true;

  @override
  Stream<Uint8List> get inboundA => inA.stream;

  @override
  Stream<Uint8List> get inboundB => inB.stream;

  @override
  Stream<Uint8List> get fee7Inbound => fee7In.stream;

  @override
  Future<void> sendA(Uint8List frame) async {
    sentA.add(frame);
  }

  @override
  Future<void> sendB(Uint8List framed) async {
    sentB.add(framed);
  }

  @override
  Future<void> sendFee7(Uint8List frame) async {
    sentFee7.add(frame);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}
