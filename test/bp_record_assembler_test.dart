import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:openwatch/core/protocol/channel_a.dart';
import 'package:openwatch/core/services/history_sync.dart';

void main() {
  group('BpRecordAssembler', () {
    test(
      'preserves distinct raw records for consecutive bitmap slots',
      () async {
        final chunks = StreamController<BpRecordChunk>.broadcast();
        final assembler = BpRecordAssembler(
          chunks: chunks.stream,
          clock: () => DateTime(2026, 7, 4, 12),
          quietWindow: const Duration(seconds: 1),
        );
        addTearDown(() async {
          await assembler.dispose();
          await chunks.close();
        });

        final first = Uint8List.fromList(List<int>.generate(13, (i) => i + 1));
        final second = Uint8List.fromList(
          List<int>.generate(13, (i) => 0xa0 + i),
        );
        final emitted = assembler.assembled.first;

        chunks.add(
          BpRecordChunk(
            seq: 0,
            payload: Uint8List.fromList([
              0x00,
              26,
              7,
              4,
              2,
              0x03, // slots 0 and 1 present
              0x00,
              0x00,
              0x00,
              0x00,
              0x00,
            ]),
          ),
        );
        chunks.add(
          BpRecordChunk(seq: 1, payload: Uint8List.fromList([0x01, ...first])),
        );
        chunks.add(
          BpRecordChunk(seq: 2, payload: Uint8List.fromList([0x01, ...second])),
        );
        chunks.add(BpRecordChunk(seq: 3, payload: Uint8List.fromList([0xff])));

        final day = await emitted;
        expect(day.day, const DateOnly(2026, 7, 4));
        expect(day.slotDuration, const Duration(minutes: 30));
        expect(day.slots, hasLength(2));
        expect(day.slots[0], orderedEquals(first));
        expect(day.slots[1], orderedEquals(second));
      },
    );

    test(
      'keeps an all-zero raw record when the bitmap marks it present',
      () async {
        final chunks = StreamController<BpRecordChunk>.broadcast();
        final assembler = BpRecordAssembler(
          chunks: chunks.stream,
          clock: () => DateTime(2026, 7, 4, 12),
          quietWindow: const Duration(seconds: 1),
        );
        addTearDown(() async {
          await assembler.dispose();
          await chunks.close();
        });

        final zero = Uint8List(13);
        final nonzero = Uint8List.fromList(
          List<int>.generate(13, (i) => 0x20 + i),
        );
        final emitted = assembler.assembled.first;

        chunks.add(
          BpRecordChunk(
            seq: 0,
            payload: Uint8List.fromList([
              0x00,
              26,
              7,
              4,
              2,
              0x03, // slots 0 and 1 present
              0x00,
              0x00,
              0x00,
              0x00,
              0x00,
            ]),
          ),
        );
        chunks.add(
          BpRecordChunk(seq: 1, payload: Uint8List.fromList([0x01, ...zero])),
        );
        chunks.add(
          BpRecordChunk(
            seq: 2,
            payload: Uint8List.fromList([0x01, ...nonzero]),
          ),
        );
        chunks.add(BpRecordChunk(seq: 3, payload: Uint8List.fromList([0xff])));

        final day = await emitted;
        expect(day.slots, hasLength(2));
        expect(day.slots[0], orderedEquals(zero));
        expect(day.slots[1], orderedEquals(nonzero));
      },
    );
  });
}
