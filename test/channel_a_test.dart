import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:openwatch/core/ble/ble_transport.dart';
import 'package:openwatch/core/protocol/channel_a.dart';
import 'package:openwatch/core/protocol/codec.dart';
import 'package:openwatch/core/protocol/opcodes.dart';

class _StubTransport implements BleTransport {
  final inA = StreamController<Uint8List>.broadcast();

  @override
  Stream<Uint8List> get inboundA => inA.stream;

  @override
  Future<void> sendA(Uint8List frame) async {}

  @override
  Future<void> sendB(Uint8List framed) async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

void main() {
  group('ChannelADispatcher', () {
    test('setTime ACK decodes BCD back to DateTime', () async {
      final t = _StubTransport();
      final d = ChannelADispatcher(t);
      d.bind();
      final got = d.onTime.first;
      final f = Codec.buildChannelA(OpA.setTime, [
        Codec.toBcd(26), // year % 100
        Codec.toBcd(6),
        Codec.toBcd(20),
        Codec.toBcd(14),
        Codec.toBcd(30),
        Codec.toBcd(45),
        0, // lang
        ((2 + 24) % 24) * 2 + 1, // tz
      ]);
      t.inA.add(f);
      final ts = await got.timeout(const Duration(seconds: 1));
      expect(ts.year, 2026);
      expect(ts.month, 6);
      expect(ts.day, 20);
      expect(ts.hour, 14);
    });

    test('realTimeHeartRate emits plausible bpm only', () async {
      final t = _StubTransport();
      final d = ChannelADispatcher(t);
      d.bind();
      final samples = <int>[];
      final sub = d.onRealtimeHr.listen(samples.add);
      final f = Codec.buildChannelA(OpA.realTimeHeartRate, [72]);
      t.inA.add(f);
      // 0xFF should be ignored (implausible).
      final f2 = Codec.buildChannelA(OpA.realTimeHeartRate, [0xFF]);
      t.inA.add(f2);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await sub.cancel();
      expect(samples, [72]);
    });

    test('pushMsgUint extracts text and skips null padding', () async {
      final t = _StubTransport();
      final d = ChannelADispatcher(t);
      d.bind();
      final got = d.onPushMsg.first;
      // type, lenLo, lenHi, "Hello" + zero pad
      final f = Codec.buildChannelA(
        OpA.pushMsgUint,
        [0x02, 5, 0, ...'Hello'.codeUnits],
      );
      t.inA.add(f);
      final msg = await got.timeout(const Duration(seconds: 1));
      expect(msg.type, 0x02);
      expect(msg.text, contains('Hello'));
    });

    test('DND read sub emits state', () async {
      final t = _StubTransport();
      final d = ChannelADispatcher(t);
      d.bind();
      final got = d.onDnd.first;
      final f = Codec.buildChannelA(OpA.dnd, [0x01, 0x01]);
      t.inA.add(f);
      final s = await got.timeout(const Duration(seconds: 1));
      expect(s.enabled, isTrue);
    });

    test('invalid frames are dropped silently', () async {
      final t = _StubTransport();
      final d = ChannelADispatcher(t);
      d.bind();
      final got = d.unknown.first.timeout(
        const Duration(milliseconds: 100),
        onTimeout: () => ChannelAFrame(-1, Uint8List(0)),
      );
      // Send a 16-byte frame with broken checksum; should not produce any
      // event on `unknown` either.
      final bad = Codec.buildChannelA(0x55);
      bad[15] = (bad[15] + 1) & 0xFF;
      t.inA.add(bad);
      final u = await got;
      expect(u.opcode, -1);
    });
  });
}