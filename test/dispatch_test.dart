import 'dart:io';

import 'package:test/test.dart';
import 'package:openwatch/core/protocol/dispatch.dart';

void main() {
  group('H59Dispatch', () {
    test('bucketFor matches firmware table bytes', () {
      final body = File('firmwares/_re/v13/body.bin').readAsBytesSync();
      const tableOffset = 0x22490;
      expect(body.length, greaterThan(tableOffset + 256));

      for (var opcode = 0; opcode < 256; opcode++) {
        final firmwareBucket = body[tableOffset + opcode];
        expect(
          H59Dispatch.bucketFor(opcode),
          firmwareBucket,
          reason: 'opcode 0x${opcode.toRadixString(16).padLeft(2, '0')}',
        );
      }
    });

    test('bucket constants match documented families', () {
      // Standard requests
      expect(H59Dispatch.bucketFor(0x01), H59Dispatch.bucketStandardReq);
      expect(H59Dispatch.bucketFor(0x15), H59Dispatch.bucketStandardReq);

      // Target setting
      expect(H59Dispatch.bucketFor(0x21), H59Dispatch.bucketTarget);

      // Mixture commands
      expect(H59Dispatch.bucketFor(0x0a), H59Dispatch.bucketMixture);
      expect(H59Dispatch.bucketFor(0x0e), H59Dispatch.bucketMixture);

      // Sub-opcode families
      expect(H59Dispatch.bucketFor(0x69), H59Dispatch.bucketSubCmd68);
      expect(H59Dispatch.bucketFor(0x43), H59Dispatch.bucketSubCmd42);
      expect(H59Dispatch.bucketFor(0x63), H59Dispatch.bucketSubCmd62);

      // Large-data sub / today sport
      expect(H59Dispatch.bucketFor(0x48), H59Dispatch.bucketLargeDataSub);
      expect(H59Dispatch.bucketFor(0x50), H59Dispatch.bucketLargeDataSub);

      // Notify/push (note: 0x73 falls in the 0x68..0x7b sub-opcode bucket)
      expect(H59Dispatch.bucketFor(0x23), H59Dispatch.bucketNotifyPush);
      expect(H59Dispatch.bucketFor(0x7c), H59Dispatch.bucketNotifyPush);

      // Notify class
      expect(H59Dispatch.bucketFor(0x31), H59Dispatch.bucketNotifyClass);

      // Reserved
      expect(H59Dispatch.bucketFor(0x00), H59Dispatch.bucketReserved);
      expect(H59Dispatch.bucketFor(0xff), H59Dispatch.bucketReserved);
    });

    test('opcodesForBucket returns contiguous ranges', () {
      final mixture = H59Dispatch.opcodesForBucket(H59Dispatch.bucketMixture);
      expect(mixture, [0x0a, 0x0b, 0x0c, 0x0d, 0x0e]);
    });
  });
}
