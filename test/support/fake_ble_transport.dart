import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:openwatch/core/ble/ble_transport.dart';
import 'package:openwatch/core/ble/ble_constants.dart';
import 'package:openwatch/core/protocol/codec.dart';

/// Shared [WatchLink] test double used across the protocol-layer test
/// suite (dispatchers, parsers, `HistorySync`, `ProtocolHub`, the DFU
/// flasher, …).
///
/// Exposes the inbound stream controllers and outbound recording lists
/// every test in `test/` needs, so each test file no longer has to
/// hand-roll its own transport stub. Because [WatchLink] is the narrow
/// frame-level interface (rather than the concrete GATT transport), every
/// member is implemented explicitly — no `noSuchMethod` fall-through.
class FakeBleTransport implements WatchLink {
  final inA = StreamController<Uint8List>.broadcast();
  final inB = StreamController<Uint8List>.broadcast();
  final fee7In = StreamController<Uint8List>.broadcast();
  final standardHeartRateIn = StreamController<int>.broadcast();
  @override
  WatchProfile profile = WatchProfile.oudmon;

  /// Link state; starts (and normally stays) `ready` so code under test
  /// can send immediately. Flip to simulate disconnects.
  final linkState = ValueNotifier<LinkState>(LinkState.ready);

  /// Every frame handed to [sendA] or [requestA], in order.
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
  String hardwareRevision = '';

  @override
  String firmwareRevision = '';

  @override
  ValueListenable<LinkState> get state => linkState;

  @override
  bool get isReady => linkState.value == LinkState.ready;

  @override
  Stream<Uint8List> get inboundA => inA.stream;

  @override
  Stream<Uint8List> get inboundB => inB.stream;

  @override
  Stream<int> get standardHeartRate => standardHeartRateIn.stream;

  @override
  Stream<Uint8List> get fee7Inbound => fee7In.stream;

  @override
  Future<void> sendA(Uint8List frame) async {
    sentA.add(frame);
  }

  /// Records the frame and completes with the next inbound Channel-A frame
  /// whose (error-flag-stripped) opcode matches — mirroring the real
  /// transport's opcode-correlated waiter.
  @override
  Future<Uint8List> requestA(
    Uint8List frame, {
    Duration timeout = const Duration(seconds: 5),
  }) {
    sentA.add(frame);
    final opcode = frame[0] & ~Codec.errorFlag;
    return inA.stream
        .firstWhere((f) => Codec.rxOpcode(f) == opcode)
        .timeout(timeout);
  }

  @override
  Future<void> sendB(Uint8List framed) async {
    sentB.add(framed);
  }

  @override
  Future<void> sendFee7(Uint8List frame) async {
    sentFee7.add(frame);
  }
}
