import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:openwatch/core/ble/ble_transport.dart';
import 'package:openwatch/core/protocol/codec.dart';
import 'package:openwatch/core/protocol/opcodes.dart';
import 'package:openwatch/core/protocol/ota_state.dart';
import 'package:openwatch/core/services/protocol_hub.dart';

class _StubTransport implements BleTransport {
  final inA = StreamController<Uint8List>.broadcast();
  final inB = StreamController<Uint8List>.broadcast();

  @override
  Stream<Uint8List> get inboundA => inA.stream;

  @override
  Stream<Uint8List> get inboundB => inB.stream;

  @override
  Future<void> sendA(Uint8List frame) async {}

  @override
  Future<void> sendB(Uint8List framed) async {}

  // fee7 is optional — keep it disabled so the hub skips fee7 wiring.
  @override
  bool get hasFee7Write => false;

  @override
  Stream<Uint8List> get fee7Inbound => const Stream.empty();

  @override
  Future<void> sendFee7(Uint8List frame) async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

void main() {
  group('ProtocolHub', () {
    test('0x72 push frame is forwarded to AncsClient stream', () async {
      final t = _StubTransport();
      final hub = ProtocolHub(t);

      final events = <String>[];
      final sub = hub.ancs.events.listen((e) {
        events.add(e.runtimeType.toString());
      });

      // Build a 16-byte Channel-A push frame: opcode 0x72 + 14 payload bytes
      // (text "hi" encoded as ASCII) + checksum.
      final payload = [0x68, 0x69]; // 'h','i'
      final frame = Codec.buildChannelA(OpA.pushMsgUint, payload);
      t.inA.add(frame);
      await Future<void>.delayed(const Duration(milliseconds: 10));

      expect(events, contains('AncsNotification'));
      await sub.cancel();
      hub.dispose();
    });

    test('OTA state machine builds with computed checksums', () async {
      final t = _StubTransport();
      final hub = ProtocolHub(t);
      final image = Uint8List.fromList(List<int>.generate(32, (i) => i));
      final sm = hub.startOta(image: image, sizeBytes: image.length);
      sm.computeChecksums();

      expect(sm.session.crc16, Codec.crc16(image));
      expect(sm.session.additive, isNot(equals(0)));
      expect(sm.session.phase, OtaPhase.idle);
      expect(sm.transition(OtaPhase.started), isTrue);
      expect(sm.session.phase, OtaPhase.started);
      hub.dispose();
    });

    test('hub exposes hasFee7 accessor and tolerates absence', () async {
      final t = _StubTransport();
      final hub = ProtocolHub(t);
      // _StubTransport.noSuchMethod returns null for every getter; that
      // collapses `hasFee7Write` to null/false so the hub must skip fee7
      // wiring rather than crash.
      expect(hub.hasFee7, isFalse);
      expect(hub.fee7, isNull);
      hub.dispose();
    });
  });
}
