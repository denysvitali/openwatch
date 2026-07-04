import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:openwatch/core/protocol/channel_b.dart';
import 'package:openwatch/core/protocol/codec.dart';

import 'support/fake_ble_transport.dart';

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
    test('out-of-order arrival: stray non-magic chunk mid-reassembly '
        'is APPENDED then poisoned into a CRC mismatch — NO emit, NO NAK '
        '(continuation slot does not enforce magic; channel_b.dart:152-175 '
        '+ 240-253)', () async {
      // The firmware parser has one accumulator in `_state == 1`
      // continuation mode. Anything arriving without a leading 0xBC
      // header is accepted as raw payload bytes (unlike the first
      // fragment, which must carry the magic). This test pins that
      // behaviour: the assembled buffer is poisoned, the CRC fails, and
      // the frame is discarded silently — there is NO auto-NAK on
      // Channel B (no-auto-ack note). If anyone ever adds strict per-
      // slot validation, this test flips the assertion to expect an
      // emit and the failure will be obvious in CI.
      final t = FakeBleTransport();
      final p = ChannelBParser(t);
      p.bind();
      final emitted = <ChannelBCommand>[];
      final sub = p.commands.listen(emitted.add);

      const payloadLen = 30;
      final payload = List<int>.generate(payloadLen, (i) => i);
      final f = Codec.buildChannelB(0x42, payload);
      final first = Uint8List.sublistView(f, 0, 20);
      // 8 bytes of stray "continuation" content.
      final stray = Uint8List.fromList(List<int>.generate(8, (i) => 0xAA));
      // Finish the buffer with the original 8 trailing bytes.
      final trailing = Uint8List.sublistView(f, 20, 28);

      t.inB.add(first);
      t.inB.add(stray);
      t.inB.add(trailing);

      final got = p.commands.first.timeout(
        const Duration(milliseconds: 200),
        onTimeout: () => ChannelBCommand(-1, Uint8List(0)),
      );
      final c = await got;
      expect(c.cmd, -1, reason: 'poisoned buffer must fail CRC → no emit');
      expect(
        t.sentA,
        isEmpty,
        reason: 'firmware never NAKs unsolicited frames',
      );
      await sub.cancel();
      expect(emitted, isEmpty);
    });

    test(
      'missing chunk: reassembly exceeds fragmentTimeout, state '
      'resets silently — NO NAK on Channel B (channel_b.dart:218-228)',
      () async {
        final t = FakeBleTransport();
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
        expect(emitted, isEmpty, reason: 'timeout must discard, never emit');
        expect(t.sentA, isEmpty, reason: 'firmware never NAKs frames it sent');
      },
    );

    test('head-of-line blocking: parser is single-state, so an interleaved '
        'second-frame first-fragment gets APPENDED to the first frame\'s '
        'buffer, poisoning the CRC and silencing the emit '
        '(channel_b.dart:66 — one `_buf`)', () async {
      // The firmware parser has ONE accumulator. There is no message-id
      // routing — so anything arriving on the stream mid-reassembly is
      // appended to whichever frame is currently in `_state == 1`. In
      // practice this guarantees interleaving is unsafe: the bytes of
      // the second frame get physically copied into the first frame's
      // `_buf`, the CRC fails, and the first frame is silently dropped.
      // After `_reset()` the parser returns to `_state == 0` and any
      // subsequent non-magic lead byte is dropped with a `WARN`.
      final t = FakeBleTransport();
      final p = ChannelBParser(t);
      p.bind();
      final emitted = <ChannelBCommand>[];
      final sub = p.commands.listen(emitted.add);

      final a = Codec.buildChannelB(0x03, List<int>.generate(30, (i) => i));
      final b = Codec.buildChannelB(
        0x04,
        List<int>.generate(30, (i) => 0x40 + i),
      );

      t.inB.add(Uint8List.sublistView(a, 0, 20));
      // Second frame's first 20 bytes get appended wholesale — the parser
      // is in `_state == 1`, so the leading 0xBC is just another payload
      // byte. Crucially the slice exactly matches the remaining 16 bytes
      // (`30 - 14`), so `_dispatch()` runs and the CRC fails on the
      // poisoned buffer.
      t.inB.add(Uint8List.sublistView(b, 0, 20));
      // This tail of `a` is now arriving AFTER the CRC-fail `_reset`,
      // so the parser is back in `_state == 0` and the lack of a 0xBC
      // lead byte triggers "dropping chunk without 0xBC magic".
      t.inB.add(Uint8List.sublistView(a, 20));

      final got = p.commands.first.timeout(
        const Duration(milliseconds: 200),
        onTimeout: () => ChannelBCommand(-1, Uint8List(0)),
      );
      final c = await got;
      expect(c.cmd, -1, reason: 'interleaved poisoning → CRC fail → no emit');
      expect(
        t.sentA,
        isEmpty,
        reason: 'firmware never NAKs unsolicited frames',
      );
      await sub.cancel();
      expect(emitted, isEmpty);
    });

    test(
      'duplicate chunk (replay storm): same frame pushed 5× emits '
      'EXACTLY once (FNV-1a LRU dedup, channel_b.dart:86-89 + 273-289)',
      () async {
        final t = FakeBleTransport();
        final p = ChannelBParser(t);
        p.bind();
        final emitted = <ChannelBCommand>[];
        final sub = p.commands.listen(emitted.add);

        // 13-byte payload matching a typical 0x27 sleep push
        // (channel_b_test.dart replay scenario).
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

    test('partial last chunk with bad CRC is SILENTLY dropped — no emit, '
        'no NAK (channel_b.dart:240-253)', () async {
      final t = FakeBleTransport();
      final p = ChannelBParser(t);
      p.bind();
      final emitted = <ChannelBCommand>[];
      final sub = p.commands.listen(emitted.add);

      final f = Codec.buildChannelB(0x32, [1, 2, 3, 4, 5]);
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
    });

    test(
      'tiny payload (sub-MTU single chunk) emits in one frame; '
      'continuation state is never entered (channel_b.dart:210-211)',
      () async {
        // 4-byte payload → frame is 6 + 4 = 10 bytes, well under MTU=20.
        // `_onFirstFragment` populates accumulator=4=expectedLength and
        // dispatches immediately, skipping `_state = 1`.
        final t = FakeBleTransport();
        final p = ChannelBParser(t);
        p.bind();

        final done = p.commands.first;
        t.inB.add(Codec.buildChannelB(0x27, [0xC2, 0x01, 0x01, 0x1E]));
        final c = await done.timeout(const Duration(seconds: 1));
        expect(c.cmd, 0x27);
        expect(c.payload, [0xC2, 0x01, 0x01, 0x1E]);
      },
    );

    test('max-size payload spanning 53 chunks reassembles cleanly '
        '(1040-byte payload under the 0x450=1104-byte firmware buffer, '
        'channel_b.dart:66)', () async {
      final t = FakeBleTransport();
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
      final c = await p.commands.first.timeout(const Duration(seconds: 2));
      expect(c.cmd, 0x01);
      expect(c.payload.length, payloadLen);
      expect(c.payload, payload, reason: 'no bytes lost across 53 fragments');
    });

    test(
      'reassembly timeout race: a chunk arriving before the '
      'timer fires CANCELS the discard (channel_b.dart:138 + 218-228)',
      () async {
        // First line of `_onChunk` cancels the timeout BEFORE branching.
        // The margin is intentionally wider than the production race to
        // keep this stress test deterministic on loaded CI hosts.
        final t = FakeBleTransport();
        final p = ChannelBParser(
          t,
          fragmentTimeout: const Duration(milliseconds: 250),
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

        // Deliver the remainder before the timeout would discard the head.
        await Future<void>.delayed(const Duration(milliseconds: 60));
        t.inB.add(Uint8List.sublistView(f, 20));

        final c = await p.commands.first.timeout(const Duration(seconds: 1));
        expect(c.cmd, 0x33);
        expect(c.payload.length, payloadLen);
        await sub.cancel();
        expect(emitted, hasLength(1));
      },
    );
  });
}
