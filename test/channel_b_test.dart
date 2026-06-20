import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:openwatch/core/ble/ble_transport.dart';
import 'package:openwatch/core/protocol/channel_b.dart';
import 'package:openwatch/core/protocol/codec.dart';

/// Minimal test double for [BleTransport]. Only the inbound-B stream and
/// sendA hook are exercised by the parser.
class _StubTransport implements BleTransport {
  final inB = StreamController<Uint8List>.broadcast();
  final sentA = <Uint8List>[];

  @override
  Stream<Uint8List> get inboundB => inB.stream;

  @override
  Future<void> sendA(Uint8List frame) async {
    sentA.add(frame);
  }

  @override
  Future<void> sendB(Uint8List framed) async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

void main() {
  group('ChannelBParser', () {
    test('empty-payload sentinel emits immediately', () async {
      final t = _StubTransport();
      final p = ChannelBParser(t);
      p.bind();

      final done = p.commands.first;
      t.inB.add(Uint8List.fromList([0xBC, 0x27, 0xFF, 0xFF, 0xFF, 0xFF]));
      final c = await done.timeout(const Duration(seconds: 2));
      expect(c.cmd, 0x27);
      expect(c.payload, isEmpty);

      // ACK was sent.
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(t.sentA, isNotEmpty);
      expect(t.sentA.last[0], 0xBC);
      expect(t.sentA.last[1], 0x27);
      expect(t.sentA.last[2], 0x00); // status = OK
    });

    test('CRC mismatch sends NAK (status=2) and skips emit', () async {
      final t = _StubTransport();
      final p = ChannelBParser(t);
      p.bind();
      final f = Codec.buildChannelB(0x32, [1, 2, 3, 4, 5]);
      f[6] ^= 0xFF;
      // Either we time out (no emit) or the parser crashes — neither is a
      // successful emit. Use a short timeout to keep the test fast.
      final got = p.commands.first.timeout(
        const Duration(milliseconds: 100),
        onTimeout: () => ChannelBCommand(-1, Uint8List(0)),
      );
      t.inB.add(f);
      final c = await got;
      expect(c.cmd, -1); // nothing emitted

      // NAK was sent (status=2).
      expect(t.sentA, isNotEmpty);
      expect(t.sentA.last[2], 0x02);
    });

    test('buildAck encodes status byte', () {
      final p = ChannelBParser(_StubTransport());
      final ack = p.buildAck(0x01, 0);
      expect(ack[0], 0xBC);
      expect(ack[1], 0x01);
      expect(ack[2], 0x00);
    });

    test('multi-chunk reassembly completes one command', () async {
      final t = _StubTransport();
      final p = ChannelBParser(t);
      p.bind();
      // Build a 25-byte payload; with the 6-byte header the frame is 31
      // bytes. The firmware slices on MTU=20, so the first chunk carries
      // 6 header + 14 payload bytes and the second carries 11 payload bytes.
      final payload = List<int>.generate(25, (i) => i);
      final f = Codec.buildChannelB(0x03, payload);
      final first = Uint8List.sublistView(f, 0, 6 + 14);
      final second = Uint8List.sublistView(f, 6 + 14);
      final done = p.commands.first;
      t.inB.add(first);
      t.inB.add(second);
      final c = await done.timeout(const Duration(seconds: 2));
      expect(c.cmd, 0x03);
      expect(c.payload, payload);
    });

    test('OTA direct commands do not auto-ACK', () async {
      final t = _StubTransport();
      final p = ChannelBParser(t);
      p.bind();
      final f = Uint8List.fromList([0xBC, 0x01, 0xFF, 0xFF, 0xFF, 0xFF]);
      final done = p.commands.first;
      t.inB.add(f);
      await done.timeout(const Duration(seconds: 2));
      expect(t.sentA, isEmpty);
    });
  });
}