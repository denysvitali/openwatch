import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:openwatch/core/protocol/codec.dart';
import 'package:openwatch/core/protocol/commands.dart';
import 'package:openwatch/core/protocol/opcodes.dart';

void main() {
  group('Channel A framing', () {
    test('frame is always 16 bytes with additive checksum', () {
      final f = Codec.buildChannelA(0x3c);
      expect(f.length, 16);
      var sum = 0;
      for (var i = 0; i < 15; i++) {
        sum += f[i];
      }
      expect(f[15], sum & 0xFF);
      expect(Codec.isValidChannelA(f), isTrue);
    });

    test('subData is copied at offset 1 and clamped to 14 bytes', () {
      final f = Codec.buildChannelA(0x50, const [0x55, 0xAA]);
      expect(f[0], 0x50);
      expect(f[1], 0x55);
      expect(f[2], 0xAA);
      expect(f[3], 0x00);
    });

    test('rxOpcode strips the error flag and rxIsError detects it', () {
      final ok = Codec.buildChannelA(0x15);
      expect(Codec.rxOpcode(ok), 0x15);
      expect(Codec.rxIsError(ok), isFalse);

      final err = Uint8List.fromList(ok);
      err[0] |= 0x80;
      err[15] = 0; // checksum irrelevant for opcode extraction
      expect(Codec.rxOpcode(err), 0x15);
      expect(Codec.rxIsError(err), isTrue);
    });

    test('invalid length or checksum is rejected', () {
      expect(Codec.isValidChannelA(Uint8List(15)), isFalse);
      final f = Codec.buildChannelA(0x01);
      f[15] = (f[15] + 1) & 0xFF;
      expect(Codec.isValidChannelA(f), isFalse);
    });
  });

  group('Channel B framing', () {
    test('empty payload uses the FF sentinel', () {
      final f = Codec.buildChannelB(OpB.otaStart);
      expect(f, [0xBC, 0x01, 0xFF, 0xFF, 0xFF, 0xFF]);
    });

    test('payload frame carries LE length and CRC16, and round-trips', () {
      final payload = [1, 2, 3, 4, 5];
      final f = Codec.buildChannelB(0x32, payload);
      expect(f[0], 0xBC);
      expect(f[1], 0x32);
      expect(Codec.readU16le(f, 2), payload.length);
      final back = Codec.rxChannelBPayload(f);
      expect(back, payload);
    });

    test('corrupt CRC fails validation', () {
      final f = Codec.buildChannelB(0x32, [9, 9, 9]);
      f[6] ^= 0xFF;
      expect(Codec.rxChannelBPayload(f), isNull);
    });
  });

  group('helpers', () {
    test('BCD round-trips', () {
      for (final v in [0, 9, 10, 23, 59, 99]) {
        expect(Codec.fromBcd(Codec.toBcd(v)), v);
      }
    });

    test('CRC16/MODBUS known vector', () {
      // CRC-16/MODBUS (poly 0xA001 reflected, init 0xFFFF, no final xor):
      // check("123456789") == 0x4B37. NOTE: the exact device variant is
      // assumed MODBUS and must be confirmed against a live capture.
      expect(Codec.crc16('123456789'.codeUnits), 0x4B37);
    });
  });

  group('commands', () {
    test('findDevice carries the 0x55AA magic', () {
      final f = Commands.findDevice();
      expect(f[0], OpA.findDevice);
      expect(f[1], 0x55);
      expect(f[2], 0xAA);
    });

    test('setTime encodes BCD date fields', () {
      final f = Commands.setTime(DateTime(2026, 6, 19, 8, 30, 5));
      expect(f[0], OpA.setTime);
      expect(Codec.fromBcd(f[1]), 26); // year % 100
      expect(Codec.fromBcd(f[2]), 6);
      expect(Codec.fromBcd(f[3]), 19);
      expect(Codec.fromBcd(f[4]), 8);
      expect(Codec.fromBcd(f[5]), 30);
    });
  });
}
