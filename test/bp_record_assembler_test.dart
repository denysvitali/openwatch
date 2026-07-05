import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:openwatch/core/protocol/channel_a.dart';
import 'package:openwatch/core/services/history_sync.dart';

void main() {
  group('BpRecordAssembler', () {
    test('preserves compact raw bytes by bitmap slot index', () async {
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

      final emitted = assembler.assembled.first;

      chunks.add(
        BpRecordChunk(
          seq: 0,
          payload: Uint8List.fromList([
            0x00,
            26,
            7,
            4,
            0x3c,
            0x05, // slots 0 and 2 present
            0x00,
            0x00,
            0x00,
            0x00,
            0x00,
          ]),
        ),
      );
      chunks.add(
        BpRecordChunk(seq: 1, payload: Uint8List.fromList([0x01, 0x78, 0x82])),
      );
      chunks.add(BpRecordChunk(seq: 2, payload: Uint8List.fromList([0xff])));

      final day = await emitted;
      expect(day.day, const DateOnly(2026, 7, 4));
      expect(day.slotDuration, const Duration(minutes: 60));
      expect(day.slots, hasLength(2));
      expect(day.slotIndexes, [0, 2]);
      expect(day.slots[0], orderedEquals([0x78]));
      expect(day.slots[1], orderedEquals([0x82]));
    });

    test(
      'keeps an all-zero raw byte when the bitmap marks it present',
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

        final emitted = assembler.assembled.first;

        chunks.add(
          BpRecordChunk(
            seq: 0,
            payload: Uint8List.fromList([
              0x00,
              26,
              7,
              4,
              30,
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
          BpRecordChunk(
            seq: 1,
            payload: Uint8List.fromList([0x01, 0x00, 0x66]),
          ),
        );
        chunks.add(BpRecordChunk(seq: 2, payload: Uint8List.fromList([0xff])));

        final day = await emitted;
        expect(day.slotDuration, const Duration(minutes: 30));
        expect(day.slots, hasLength(2));
        expect(day.slots[0], orderedEquals([0x00]));
        expect(day.slots[1], orderedEquals([0x66]));
      },
    );

    test('preserves valid intervals above the hourly default', () async {
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

      final emitted = assembler.assembled.first;

      chunks.add(
        BpRecordChunk(
          seq: 0,
          payload: Uint8List.fromList([
            0x00,
            26,
            7,
            4,
            90,
            0x01,
            0x00,
            0x00,
            0x00,
            0x00,
            0x00,
          ]),
        ),
      );
      chunks.add(BpRecordChunk(seq: 1, payload: Uint8List.fromList([0xff])));

      final day = await emitted;
      expect(day.slotDuration, const Duration(minutes: 90));
    });

    test(
      'continues compact bytes across tagged 14-byte stream chunks',
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

        final emitted = assembler.assembled.first;
        chunks.add(
          BpRecordChunk(
            seq: 0,
            payload: Uint8List.fromList([
              0x00,
              26,
              7,
              4,
              0x3c,
              0xff,
              0x3f,
              0x00,
              0x00,
              0x00,
              0x00,
            ]),
          ),
        );
        chunks.add(
          BpRecordChunk(
            seq: 1,
            payload: Uint8List.fromList([
              0x01,
              0x41,
              0x42,
              0x43,
              0x44,
              0x45,
              0x46,
              0x47,
              0x48,
              0x49,
              0x4a,
              0x4b,
              0x4c,
              0x4d,
            ]),
          ),
        );
        chunks.add(
          BpRecordChunk(
            seq: 2,
            payload: Uint8List.fromList([
              0x01,
              0x4e,
              ...List<int>.filled(12, 0),
            ]),
          ),
        );
        chunks.add(BpRecordChunk(seq: 3, payload: Uint8List.fromList([0xff])));

        final day = await emitted;
        expect(day.slots, hasLength(14));
        expect(day.slotIndexes, List<int>.generate(14, (i) => i));
        expect(day.slots.map((s) => s.single), [
          0x41,
          0x42,
          0x43,
          0x44,
          0x45,
          0x46,
          0x47,
          0x48,
          0x49,
          0x4a,
          0x4b,
          0x4c,
          0x4d,
          0x4e,
        ]);
      },
    );
  });
}
