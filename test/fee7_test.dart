import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:openwatch/core/ble/fee7_service.dart';
import 'package:openwatch/core/protocol/codec.dart';
import 'package:openwatch/core/protocol/fee7_dispatcher.dart';
import 'package:openwatch/core/protocol/opcodes.dart';

/// Minimal in-memory host that satisfies the [Fee7Host] contract.
class _StubHost implements Fee7Host {
  final inbound = StreamController<Uint8List>.broadcast();
  final sent = <Uint8List>[];

  bool _hasWrite = true;
  bool _rejectWrites = false;

  void setHasWrite(bool v) => _hasWrite = v;
  void setRejectWrites(bool v) => _rejectWrites = v;

  @override
  Stream<Uint8List> get fee7Inbound => inbound.stream;

  @override
  bool get hasFee7Write => _hasWrite;

  @override
  Future<void> sendFee7(Uint8List frame) async {
    if (_rejectWrites || !_hasWrite) {
      throw StateError('fee7 write not available');
    }
    sent.add(frame);
  }
}

void main() {
  group('Fee7Service', () {
    test('sendCommand encodes a 16-byte frame with valid checksum', () async {
      final host = _StubHost();
      final svc = Fee7Service.attach(host);

      final frame = Codec.buildChannelA(Fee7.handshakeResponse, [
        0x11,
        0x22,
        0x33,
        0x44,
        0x55,
        0x66,
        0x77,
        0x88,
        0x99,
        0xAA,
        0xBB,
        0xCC,
        0xDD,
        0xEE,
      ]);
      expect(frame.length, 16);
      expect(Codec.isValidChannelA(frame), isTrue);

      await svc.sendCommand(frame);
      expect(host.sent, hasLength(1));
      expect(host.sent.first, frame);
      await svc.dispose();
    });

    test('sendCommand rejects wrong length', () async {
      final host = _StubHost();
      final svc = Fee7Service.attach(host);

      expect(() => svc.sendCommand(Uint8List(15)), throwsArgumentError);
      expect(() => svc.sendCommand(Uint8List(17)), throwsArgumentError);
      // No write should have been attempted.
      expect(host.sent, isEmpty);
      await svc.dispose();
    });

    test('sendCommand rejects frame with bad checksum', () async {
      final host = _StubHost();
      final svc = Fee7Service.attach(host);

      final frame = Codec.buildChannelA(Fee7.echoBase);
      frame[15] = (frame[15] + 1) & 0xFF;
      expect(() => svc.sendCommand(frame), throwsArgumentError);
      expect(host.sent, isEmpty);
      await svc.dispose();
    });
  });

  group('Fee7Dispatcher', () {
    test('routes 0x48 to HandshakeResponse stream', () async {
      final host = _StubHost();
      final svc = Fee7Service.attach(host);
      final d = Fee7Dispatcher(svc);
      d.bind();

      final got = d.onHandshake.first;
      // 15-byte device-info payload (the firmware sends 15 bytes; we surface
      // frame[0..14] = opcode + 14 payload bytes).
      final frame = Codec.buildChannelA(
        Fee7.handshakeResponse,
        List.filled(14, 0x42),
      );
      host.inbound.add(frame);

      final r = await got.timeout(const Duration(seconds: 1));
      expect(r.payload.length, 15);
      expect(r.payload[0], Fee7.handshakeResponse);
      expect(r.raw.length, 14);
      await svc.dispose();
    });

    test('routes 0x61 to StatusResponse stream with battery+steps', () async {
      final host = _StubHost();
      final svc = Fee7Service.attach(host);
      final d = Fee7Dispatcher(svc);
      d.bind();

      final got = d.onStatus.first;
      final frame = Codec.buildChannelA(Fee7.statusResponse, [85, 1234 & 0xFF]);
      host.inbound.add(frame);

      final s = await got.timeout(const Duration(seconds: 1));
      expect(s.battery, 85);
      expect(s.steps, 1234 & 0xFF);
      await svc.dispose();
    });

    test('Echo 0x90 emits UnaryOpcode(0x90)', () async {
      final host = _StubHost();
      final svc = Fee7Service.attach(host);
      final d = Fee7Dispatcher(svc);
      d.bind();

      final got = d.onUnary.first;
      final frame = Codec.buildChannelA(Fee7.echoBase);
      host.inbound.add(frame);

      final u = await got.timeout(const Duration(seconds: 1));
      expect(u.opcode, 0x90);
      await svc.dispose();
    });
  });
}
