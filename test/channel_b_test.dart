import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:openwatch/core/ble/ble_transport.dart';
import 'package:openwatch/core/protocol/channel_b.dart';
import 'package:openwatch/core/protocol/codec.dart';
import 'package:openwatch/core/protocol/opcodes.dart';

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

      // ACK was sent — using `OpA.channelBAck` (`0x7E`) to avoid the
      // 0x80-error-flag collision that aliases 0xBC → 0x3C deviceSupport.
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(t.sentA, isNotEmpty);
      expect(t.sentA.last[0], OpA.channelBAck);
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
      expect(ack[0], OpA.channelBAck);
      expect(ack[1], 0x01);
      expect(ack[2], 0x00);
    });

    test('buildAck never sets the Channel-A error-flag bit (0x80)', () {
      final p = ChannelBParser(_StubTransport());
      for (final cmd in [0x00, 0x01, 0x27, 0x2a, 0x3e, 0xFF]) {
        for (final status in [0x00, 0x01, 0x02, 0xee]) {
          final ack = p.buildAck(cmd, status);
          expect(
            ack[0] & 0x80,
            0x00,
            reason:
                'TX opcode 0x${ack[0].toRadixString(16)} would alias '
                'to a documented request after the firmware strips '
                'the error flag',
          );
        }
      }
    });

    test('auto-ACK on every TX frame has clear high bit', () async {
      final t = _StubTransport();
      final p = ChannelBParser(t);
      p.bind();
      // Empty-payload sentinel path (channel-b.dart:152).
      t.inB.add(Uint8List.fromList([0xBC, 0x27, 0xFF, 0xFF, 0xFF, 0xFF]));
      await Future<void>.delayed(const Duration(milliseconds: 20));
      // CRC-mismatch NAK path (channel-b.dart:214).
      final bad = Codec.buildChannelB(0x32, [1, 2, 3, 4, 5]);
      bad[6] ^= 0xFF;
      t.inB.add(bad);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(t.sentA, isNotEmpty);
      for (final f in t.sentA) {
        expect(
          f[0] & 0x80,
          0x00,
          reason:
              'auto-ACK 0x${f[0].toRadixString(16)} collides with '
              'Channel-A error-flag strip',
        );
      }
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

    test('replays of the same Channel-B frame emit once', () async {
      final t = _StubTransport();
      final p = ChannelBParser(t);
      p.bind();
      // 13-byte payload (matches a typical 0x27 sleep frame).
      final f = Codec.buildChannelB(0x27, [
        0xC2,
        0x01,
        0x01,
        0x1E,
        0x02,
        0x5A,
        0x03,
        0x3C,
        0x04,
        0x0F,
        0x05,
        0x29,
        0x06,
      ]);

      final emitted = <ChannelBCommand>[];
      final sub = p.commands.listen(emitted.add);
      // The watch replays identical 0xBC/0x27/len/crc/payload frames 5×
      // during a link glitch (observed in production logs).
      for (var i = 0; i < 5; i++) {
        t.inB.add(f);
      }
      await Future<void>.delayed(const Duration(milliseconds: 30));
      await sub.cancel();
      expect(
        emitted,
        hasLength(1),
        reason: '5 identical 0x27 frames must dedup to exactly 1 emit',
      );
    });

    test('distinct payloads with the same cmd are NOT deduped', () async {
      final t = _StubTransport();
      final p = ChannelBParser(t);
      p.bind();
      final emitted = <ChannelBCommand>[];
      final sub = p.commands.listen(emitted.add);

      t.inB.add(Codec.buildChannelB(0x27, [0xC2, 0x01, 0x01]));
      await Future<void>.delayed(const Duration(milliseconds: 10));
      t.inB.add(Codec.buildChannelB(0x27, [0xC2, 0x01, 0x02]));
      await Future<void>.delayed(const Duration(milliseconds: 30));
      await sub.cancel();
      expect(emitted, hasLength(2));
    });

    test('LRU evicts oldest entry beyond the bound', () async {
      final t = _StubTransport();
      final p = ChannelBParser(t);
      p.bind();
      final emitted = <ChannelBCommand>[];
      final sub = p.commands.listen(emitted.add);
      // Fill beyond the bound (64): 70 distinct frames ⇒ 70 emitted
      // (none deduped).
      for (var i = 0; i < 70; i++) {
        t.inB.add(Codec.buildChannelB(0x27, [i & 0xFF, (i >> 8) & 0xFF]));
        await Future<void>.delayed(const Duration(milliseconds: 1));
      }
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(emitted, hasLength(70));
      // The first frame was evicted — re-emitting it must succeed.
      t.inB.add(Codec.buildChannelB(0x27, [0x00, 0x00]));
      await Future<void>.delayed(const Duration(milliseconds: 20));
      await sub.cancel();
      expect(
        emitted,
        hasLength(71),
        reason: 'first frame should have been evicted; re-emit must succeed',
      );
    });

    test('different cmd with same payload is NOT deduped', () async {
      final t = _StubTransport();
      final p = ChannelBParser(t);
      p.bind();
      final emitted = <ChannelBCommand>[];
      final sub = p.commands.listen(emitted.add);
      t.inB.add(Codec.buildChannelB(0x27, [1, 2, 3]));
      await Future<void>.delayed(const Duration(milliseconds: 10));
      t.inB.add(Codec.buildChannelB(0x2a, [1, 2, 3]));
      await Future<void>.delayed(const Duration(milliseconds: 20));
      await sub.cancel();
      expect(
        emitted,
        hasLength(2),
        reason: 'cmd differs even though payload bytes match',
      );
    });
  });
}
