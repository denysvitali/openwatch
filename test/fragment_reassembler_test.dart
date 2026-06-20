import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:openwatch/core/protocol/fragment_reassembler.dart';

void main() {
  group('FragmentReassembler', () {
    test(
        'single header + 3 chunks emits 1 assembled record with '
        'concatenated payload', () async {
      final hCtrl = StreamController<int>.broadcast();
      final cCtrl = StreamController<_PayloadChunk>.broadcast();
      final out = <String>[];
      final r = FragmentReassembler<int, _PayloadChunk, String>(
        headers: hCtrl.stream,
        chunks: cCtrl.stream,
        build: (h, payload) => 'h=$h bytes=${payload.length} '
            'sum=${payload.fold<int>(0, (a, b) => a + b)}',
        quietWindow: const Duration(milliseconds: 30),
      );
      final sub = r.assembled.listen(out.add);

      hCtrl.add(1);
      cCtrl.add(_PayloadChunk(Uint8List.fromList([1, 2, 3])));
      cCtrl.add(_PayloadChunk(Uint8List.fromList([4, 5])));
      cCtrl.add(_PayloadChunk(Uint8List.fromList([6, 7, 8, 9])));
      await Future<void>.delayed(const Duration(milliseconds: 100));

      expect(out, hasLength(1));
      // 1+2+3+4+5+6+7+8+9 = 45
      expect(out.single, 'h=1 bytes=9 sum=45');
      await sub.cancel();
      r.dispose();
      await hCtrl.close();
      await cCtrl.close();
    });

    test('two back-to-back records emit 2 separate records', () async {
      final hCtrl = StreamController<int>.broadcast();
      final cCtrl = StreamController<_PayloadChunk>.broadcast();
      final out = <String>[];
      final r = FragmentReassembler<int, _PayloadChunk, String>(
        headers: hCtrl.stream,
        chunks: cCtrl.stream,
        build: (h, payload) => 'h=$h len=${payload.length}',
        quietWindow: const Duration(milliseconds: 30),
      );
      final sub = r.assembled.listen(out.add);

      // Record #1
      hCtrl.add(10);
      cCtrl.add(_PayloadChunk(Uint8List.fromList([1, 1])));
      cCtrl.add(_PayloadChunk(Uint8List.fromList([2])));
      await Future<void>.delayed(const Duration(milliseconds: 80));
      expect(out, ['h=10 len=3']);

      // Record #2 immediately after
      hCtrl.add(20);
      cCtrl.add(_PayloadChunk(Uint8List.fromList([9, 9, 9, 9])));
      await Future<void>.delayed(const Duration(milliseconds: 80));

      expect(out, ['h=10 len=3', 'h=20 len=4']);
      await sub.cancel();
      r.dispose();
      await hCtrl.close();
      await cCtrl.close();
    });

    test(
        'quiet window elapses with no further chunks → emits '
        'in-progress record', () async {
      final hCtrl = StreamController<int>.broadcast();
      final cCtrl = StreamController<_PayloadChunk>.broadcast();
      final out = <int>[];
      final r = FragmentReassembler<int, _PayloadChunk, int>(
        headers: hCtrl.stream,
        chunks: cCtrl.stream,
        build: (h, payload) => h + payload.length,
        quietWindow: const Duration(milliseconds: 40),
      );
      final sub = r.assembled.listen(out.add);

      hCtrl.add(100);
      cCtrl.add(_PayloadChunk(Uint8List.fromList([1, 2, 3])));
      // No more events — the reassembler should flush on the
      // quiet-window timer.
      await Future<void>.delayed(const Duration(milliseconds: 120));

      expect(out, [103]);
      await sub.cancel();
      r.dispose();
      await hCtrl.close();
      await cCtrl.close();
    });

    test(
        'build receives the correct header and assembled payload '
        'bytes (order preserved)', () async {
      final hCtrl = StreamController<String>.broadcast();
      final cCtrl = StreamController<_PayloadChunk>.broadcast();
      final calls = <_BuildCall>[];
      final r = FragmentReassembler<String, _PayloadChunk, int>(
        headers: hCtrl.stream,
        chunks: cCtrl.stream,
        build: (h, payload) {
          calls.add(_BuildCall(h, Uint8List.fromList(payload)));
          return payload.length;
        },
        quietWindow: const Duration(milliseconds: 30),
      );
      final sizes = <int>[];
      final sub = r.assembled.listen(sizes.add);

      hCtrl.add('A');
      cCtrl.add(_PayloadChunk(Uint8List.fromList([0xDE])));
      cCtrl.add(_PayloadChunk(Uint8List.fromList([0xAD, 0xBE])));
      cCtrl.add(_PayloadChunk(Uint8List.fromList([0xEF])));
      await Future<void>.delayed(const Duration(milliseconds: 80));

      expect(calls, hasLength(1));
      expect(calls.single.header, 'A');
      expect(calls.single.bytes, [0xDE, 0xAD, 0xBE, 0xEF]);
      expect(sizes, [4]);
      await sub.cancel();
      r.dispose();
      await hCtrl.close();
      await cCtrl.close();
    });

    test('dispose closes output stream and stops emitting', () async {
      final hCtrl = StreamController<int>.broadcast();
      final cCtrl = StreamController<_PayloadChunk>.broadcast();
      final out = <int>[];
      final r = FragmentReassembler<int, _PayloadChunk, int>(
        headers: hCtrl.stream,
        chunks: cCtrl.stream,
        build: (h, payload) => h + payload.length,
        quietWindow: const Duration(milliseconds: 30),
      );
      final sub = r.assembled.listen(out.add);

      hCtrl.add(1);
      r.dispose();

      // Adding chunks after dispose should not produce records and
      // should not throw.
      cCtrl.add(_PayloadChunk(Uint8List.fromList([1, 2, 3])));
      await Future<void>.delayed(const Duration(milliseconds: 80));

      expect(out, isEmpty);
      await sub.cancel();
      await hCtrl.close();
      await cCtrl.close();
    });
  });
}

class _PayloadChunk {
  const _PayloadChunk(this.payload);
  final Uint8List payload;
}

class _BuildCall {
  _BuildCall(this.header, this.bytes);
  final String header;
  final Uint8List bytes;
}
