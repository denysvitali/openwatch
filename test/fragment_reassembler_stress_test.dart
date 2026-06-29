import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:openwatch/core/ble/ble_transport.dart';
import 'package:openwatch/core/protocol/channel_b.dart';
import 'package:openwatch/core/protocol/codec.dart';

/// Stress-tests the H59MA Channel-B fragment reassembler under realistic
/// BLE conditions. Mirrors `FUN_0082efea`/`FUN_0082f098` (firmware refs in
/// `firmwares/GHIDRA_DECOMPILATION.md` §9.3 + `PROTOCOL.md` §3.2):
///
///   byte: 0       1    2..3     4..5     6..
///         magic   cmd  len LE   CRC LE   payload
///
/// where `magic=0xBC`, `len`, `CRC16/MODBUS(payload)`. Defaults:
/// `subLength=20` (PROTOCOL.md L235), `fragmentTimeout=2000ms`
/// (channel_b.dart:37), LRU dedup 64 (channel_b.dart:86).
///
/// Every test below uses a synthetic `inboundB` stream — no real GATT
/// transport — so the assertions isolate the reassembly state machine.
void main() {
  group('ChannelB reassembler — stress', () {
    test(
      'out-of-order arrival: stray non-magic chunk mid-reassembly is APPENDED '
      '(continuation slot does not enforce magic; channel_b.dart:152-175)',
      () async {
        // The firmware parser has one accumulator in `_state == 1`
        // continuation mode. Anything arriving without a leading 0xBC
        // header is accepted as raw payload bytes (unlike the first
        // fragment, which must carry the magic). This test pins that
        // behaviour so we notice if the layer ever adds strict slot
        // semantics.
        final t = _StubTransport();
        final p = ChannelBParser(t);
        p.bind();
        final emitted = <ChannelBCommand>[];
        final sub = p.commands.listen(emitted.add);

        const payloadLen = 30;
        final payload = List<int>.generate(payloadLen, (i) => i);
        final f = Codec.buildChannelB(0x42, payload);
        final first = Uint8List.sublistView(f, 0, 20);
        // 8 bytes of stray "continuation" content.
        final stray = Uint8List.fromList(
          List<int>.generate(8, (i) => 0xAA),
        );
        // Finish the buffer with the original 8 trailing bytes.
        final trailing = Uint8List.sublistView(f, 20, 28);

        t.inB.add(first);
        t.inB.add(stray);
        t.inB.add(trailing);

        final c = await p.commands.first.timeout(
          const Duration(seconds: 2),
        );
        expect(c.cmd, 0x42);
        expect(c.payload.length, payloadLen);
        expect(
          c.payload.sublist(14, 22),
          List<int>.filled(8, 0xAA),
          reason: 'stray bytes slot in at the accumulator cursor',
        );
        await sub.cancel();
        expect(emitted, hasLength(1));
      },
    );

    test(
      'missing chunk: reassembly exceeds fragmentTimeout, state resets silently '
      '— NO NAK on Channel B (channel_b.dart:218-228)',
      () async {
        final t = _StubTransport();
        final p = ChannelBParser(
          t,
          fragmentTimeout: const Duration(milliseconds: 50),
        );
        p.bind();
        final emitted = <ChannelBCommand>[];
        final sub = p.commands.listen(emitted.add);

        // 100-byte payload declared but only the first fragment arrives.
        const payloadLen = 100;
        final f = Codec.buildChannelB(
          0x42,
          List<int>.generate(payloadLen, (i) => i),
        );
        t.inB.add(Uint8List.sublistView(f, 0, 20));

        // Wait past the 50 ms timeout — `_armTimeout` fires `_reset()`.
        await Future<void>.delayed(const Duration(milliseconds: 120));
        await sub.cancel();
        expect(
          emitted,
          isEmpty,
          reason: 'timeout must discard, never emit',
        );
        expect(
          t.sentA,
          isEmpty,
          reason: 'firmware never NAKs frames it sent',
        );
      },
    );

    test(
      'head-of-line blocking: parser is single-state, so an interleaved '
      'second-frame first-fragment gets APPENDED to the wrong buffer '
      '(channel_b.dart:66 — one `_buf`)',
      () async {
        final t = _StubTransport();
        final p = ChannelBParser(t);
        p.bind();
        final emitted = <ChannelBCommand>[];
        final sub = p.commands.listen(emitted.add);

        final a = Codec.buildChannelB(
          0x03,
          List<int>.generate(30, (i) => i),
        );
        final b = Codec.buildChannelB(
          0x04,
          List<int>.generate(30, (i) => 0x40 + i),
        );

        t.inB.add(Uint8List.sublistView(a, 0, 20));
        // Second frame starts arriving before the first completes: parser
        // is in `_state == 1`, so its 0xBC header is appended like any
        // other continuation byte. This pins the "interleaving is unsafe"
        // firmware-imposed invariant.
        t.inB.add(Uint8List.sublistView(b, 0, 20));
        // Finish the first.
        t.inB.add(Uint8List.sublistView(a, 20));

        final c = await p.commands.first.timeout(
          const Duration(seconds: 1),
        );
        expect(c.cmd, 0x03);
        expect(c.payload.length, 30);
        expect(
          c.payload.sublist(14, 20),
          <int>[0x40, 0x41, 0x42, 0x43, 0x44, 0x45],
          reason: 'parser does not enforce per-message slot semantics',
        );
        await sub.cancel();
      },
    );

    test(
      'duplicate chunk (replay storm): same frame pushed 5× emits EXACTLY once '
      '(FNV-1a LRU dedup, channel_b.dart:86-89 + 273-289)',
      () async {
        final t = _StubTransport();
        final p = ChannelBParser(t);
        p.bind();
        final emitted = <ChannelBCommand>[];
        final sub = p.commands.listen(emitted.add);

        // 13-byte payload matching a typical 0x27 sleep push.
        final f = Codec.buildChannelB(
          0x27,
          <int>[
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
          ],
        );
        for (var i = 0; i < 5; i++) {
          t.inB.add(f);
        }
        await Future<void>.delayed(const Duration(milliseconds: 30));
        await sub.cancel();
        expect(
          emitted,
          hasLength(1),
          reason: '5× replay of an identical frame must dedup to 1 emit',
        );
      },
    );

    test(
      'partial last chunk with bad CRC is SILENTLY dropped — no emit, no NAK '
      '(channel_b.dart:240-253)',
      () async {
        final t = _StubTransport();
        final p = ChannelBParser(t);
        p.bind();
        final emitted = <ChannelBCommand>[];
        final sub = p.commands.listen(emitted.add);

        final f = Codec.buildChannelB(0x32, <int>[1, 2, 3, 4, 5]);
        final first = Uint8List.sublistView(f, 0, 9); // 6 hdr + 3 payload
        final trailing = Uint8List.sublistView(f, 9); // 2 payload bytes
        trailing[trailing.length - 1] ^= 0xFF; // flip last byte → CRC fails

        t.inB.add(first);
        t.inB.add(trailing);

        final got = p.commands.first.timeout(
          const Duration(milliseconds: 120),
          onTimeout: () => ChannelBCommand(-1, Uint8List(0)),
        );
        final c = await got;
        expect(c.cmd, -1, reason: 'CRC mismatch must NOT emit');
        expect(
          t.sentA,
          isEmpty,
          reason: 'firmware never NAKs unsolicited frames',
        );
        await sub.cancel();
        expect(emitted, isEmpty);
      },
    );

    test(
      'tiny payload (sub-MTU single chunk) emits in one frame; '
      'continuation state is never entered (channel_b.dart:210-211)',
      () async {
        // 4-byte payload → frame is 6 + 4 = 10 bytes, well under MTU=20.
        // `_onFirstFragment` populates accumulator=4=expectedLength and
        // dispatches immediately, skipping `_state = 1`.
        final t = _StubTransport();
        final p = ChannelBParser(t);
        p.bind();

        final done = p.commands.first;
        t.inB.add(
          Codec.buildChannelB(0x27, <int>[0xC2, 0x01, 0x01, 0x1E]),
        );
        final c = await done.timeout(const Duration(seconds: 1));
        expect(c.cmd, 0x27);
        expect(c.payload, <int>[0xC2, 0x01, 0x01, 0x1E]);
      },
    );

    test(
      'max-size payload spanning 53 chunks reassembles cleanly '
      '(1040-byte payload under the 0x450=1104-byte firmware buffer, '
      'channel_b.dart:66)',
      () async {
        final t = _StubTransport();
        final p = ChannelBParser(t);
        p.bind();

        const payloadLen = 1040;
        final payload = List<int>.generate(payloadLen, (i) => i & 0xFF);
        final f = Codec.buildChannelB(0x01, payload);
        const mtu = 20;
        var offset = 0;
        while (offset < f.length) {
          final end = (offset + mtu).clamp(0, f.length);
          t.inB.add(Uint8List.sublistView(f, offset, end));
          offset = end;
        }
        final c = await p.commands.first.timeout(
          const Duration(seconds: 2),
        );
        expect(c.cmd, 0x01);
        expect(c.payload.length, payloadLen);
        expect(
          c.payload,
          payload,
          reason: 'no bytes lost across 53 fragments',
        );
      },
    );

    test(
      'reassembly timeout race: a chunk arriving 75% through the timer '
      'window CANCELS the discard (channel_b.dart:138 + 218-228)',
      () async {
        // First line of `_onChunk` cancels the timeout BEFORE branching.
        // So a chunk even 1 µs before the deadline resets the timer.
        final t = _StubTransport();
        final p = ChannelBParser(
          t,
          fragmentTimeout: const Duration(milliseconds: 80),
        );
        p.bind();
        final emitted = <ChannelBCommand>[];
        final sub = p.commands.listen(emitted.add);

        const payloadLen = 100;
        final f = Codec.buildChannelB(
          0x33,
          List<int>.generate(payloadLen, (i) => i),
        );
        t.inB.add(Uint8List.sublistView(f, 0, 20));

        // At 60 ms (75% through the 80 ms timer) deliver the remainder.
        await Future<void>.delayed(const Duration(milliseconds: 60));
        t.inB.add(Uint8List.sublistView(f, 20));

        final c = await p.commands.first.timeout(
          const Duration(seconds: 1),
        );
        expect(c.cmd, 0x33);
        expect(c.payload.length, payloadLen);
        await sub.cancel();
        expect(emitted, hasLength(1));
      },
    );
  });
}

/// Minimal transport stub — exposes only the channels the parser uses.
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
