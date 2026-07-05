import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:openwatch/core/services/bp_raw_store.dart';
import 'package:openwatch/core/services/history_store.dart';
import 'package:openwatch/core/services/history_sync.dart' show BpRecordDay;

void main() {
  group('BpRawStore', () {
    late Directory tmp;

    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('bp_raw_test_');
    });

    tearDown(() async {
      if (await tmp.exists()) await tmp.delete(recursive: true);
    });

    test('RawBpSlot.toJson / fromJson round-trips bytes intact', () {
      final original = Uint8List.fromList(const [
        0x00,
        0x01,
        0x7f,
        0x80,
        0xab,
        0xcd,
        0xef,
        0x10,
        0x20,
        0x30,
        0x40,
        0x50,
        0x60,
      ]);
      final slot = RawBpSlot(
        timestamp: DateTime.utc(2026, 7, 3, 9, 30),
        slotIndex: 19,
        bytes: original,
      );
      final round = RawBpSlot.fromJson(slot.toJson());
      expect(round.timestamp.toUtc(), slot.timestamp.toUtc());
      expect(round.slotIndex, slot.slotIndex);
      expect(round.bytes.length, original.length);
      for (var i = 0; i < original.length; i++) {
        expect(round.bytes[i], original[i], reason: 'byte $i mismatch');
      }
    });

    test('RawBpSlot hex encoding is lowercase, no separator, fixed width', () {
      final slot = RawBpSlot(
        timestamp: DateTime.utc(2026, 7, 3),
        slotIndex: 0,
        bytes: Uint8List.fromList(const [0x00, 0x0a, 0xff, 0xab]),
      );
      // hex: 000a00ff00ab would be 12 chars for 6 bytes; ours is 4 bytes
      expect(slot.toJson()['hex'], '000affab');
    });

    test('RawBpDay.fromJson rejects malformed day string', () {
      expect(
        () => RawBpDay.fromJson({
          'day': 'not-a-date',
          'slotMinutes': 30,
          'slots': <Map<String, dynamic>>[],
        }),
        throwsA(isA<FormatException>()),
      );
    });

    test('RawBpDay.empty returns a no-slots day for any DateOnly', () {
      final day = DateOnly(2026, 7, 3);
      final empty = RawBpDay.empty(day);
      expect(empty.day, day);
      expect(empty.slots, isEmpty);
      expect(empty.isEmpty, isTrue);
      expect(empty.slotMinutes, 0);
    });

    test('putDay persists and reads compact raw BP bytes', () async {
      final store = await BpRawStore.openIn(tmp);
      final record = BpRecordDay(
        day: DateOnly(2026, 7, 3),
        slotDuration: const Duration(minutes: 60),
        slotIndexes: const [0, 2],
        slots: [
          Uint8List.fromList([0x78]),
          Uint8List.fromList([0x82]),
        ],
      );
      await store.putDay(record.day, record);

      final days = await store.persistedDays();
      expect(days, [record.day]);
      final rehydrated = await store.readDay(record.day);
      expect(rehydrated.day, record.day);
      expect(rehydrated.slotMinutes, 60);
      expect(rehydrated.slots.length, 2);
      expect(rehydrated.slots.first.slotIndex, 0);
      expect(rehydrated.slots.last.slotIndex, 2);
      expect(rehydrated.slots.first.timestamp, DateTime(2026, 7, 3));
      expect(rehydrated.slots.last.timestamp, DateTime(2026, 7, 3, 2));
      expect(rehydrated.slots.first.bytes, [0x78]);
      expect(rehydrated.slots.last.bytes, [0x82]);
    });
  });
}
