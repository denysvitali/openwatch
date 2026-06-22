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

    test('deviceFind defaults to 0x08 with sub 0x01 (start find)', () {
      final f = Commands.deviceFind();
      expect(f[0], OpA.deviceFind);
      expect(f[1], 0x01);
    });

    test('deviceFind cancel uses sub 0x00', () {
      final f = Commands.deviceFind(sub: 0x00);
      expect(f[0], OpA.deviceFind);
      expect(f[1], 0x00);
    });

    test('deviceFind long-press magic encodes 0xAB 0xDC', () {
      final f = Commands.deviceFind(sub: 0xab);
      expect(f[0], OpA.deviceFind);
      expect(f[1], 0xab);
      expect(f[2], 0xdc);
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

    test('setTime defaults flags byte to 0xFF (skip tick re-init)', () {
      final f = Commands.setTime(DateTime(2026, 6, 19, 8, 30, 5));
      expect(f[7], 0xff);
    });

    test('setTime honours caller-supplied flags', () {
      final f = Commands.setTime(DateTime(2026, 6, 19, 8, 30, 5), flags: 0x00);
      expect(f[7], 0x00);
    });

    test('factoryReset sends 0xff with the "fff" magic payload', () {
      final f = Commands.factoryReset();
      expect(f[0], OpA.factoryReset);
      // "fff" = 0x66 0x66 0x66 — the magic the firmware gates on.
      expect(f[1], 0x66);
      expect(f[2], 0x66);
      expect(f[3], 0x66);
    });

    test('restoreKey uses 0x66 (separate from factoryReset)', () {
      final f = Commands.restoreKey();
      expect(f[0], OpA.restoreKey);
      expect(f[0], isNot(equals(OpA.factoryReset)));
    });

    test('deviceReboot defaults to 0xc6 with sub 0x6C (full reboot)', () {
      final f = Commands.deviceReboot();
      expect(f[0], OpA.deviceReboot);
      expect(f[1], 0x6c);
    });

    test('deviceReboot honours caller-supplied sub', () {
      final f = Commands.deviceReboot(sub: 0x02);
      expect(f[0], OpA.deviceReboot);
      expect(f[1], 0x02);
    });

    test('advanceBpRecord defaults to 0x0e with sub 0 (advance + read)', () {
      final f = Commands.advanceBpRecord();
      expect(f[0], OpA.bpReadConform);
      expect(f[1], 0x00);
    });

    test('readDetailSport encodes v14 day/hour/unit request', () {
      final f = Commands.readDetailSport(
        dayOffset: 2,
        startHour: 3,
        endHour: 9,
        oneSecondUnits: true,
      );
      expect(f[0], OpA.readDetailSport);
      expect(f.sublist(1, 6), [0x02, 0x00, 0x03, 0x09, 0x01]);
    });

    test(
      'readSleepNewProtocol uses Channel-B 0x27 with day offset + record type 0x00',
      () {
        final f = Commands.readSleepNewProtocol(dayOffset: 3);
        expect(Codec.rxChannelBCmd(f), OpB.sleepNew);
        expect(Codec.rxChannelBPayload(f), [0x03, 0x00]);
      },
    );

    test(
      'readSleepLunchProtocol uses Channel-B 0x3e with day offset + record type 0x01',
      () {
        final f = Commands.readSleepLunchProtocol(dayOffset: 2);
        expect(Codec.rxChannelBCmd(f), OpB.sleepLunchNew);
        expect(Codec.rxChannelBPayload(f), [0x02, 0x01]);
      },
    );

    test('readActivitySummary uses Channel-B 0x2a and clamps day offset', () {
      final f = Commands.readActivitySummary(dayOffset: 9);
      expect(Codec.rxChannelBCmd(f), OpB.activitySummary);
      expect(Codec.rxChannelBPayload(f), [0x02]);
    });

    test('start/stop measurement encode documented action bytes', () {
      final start = Commands.startMeasure(MeasureType.pressure);
      final stop = Commands.stopMeasure(MeasureType.pressure);
      expect(start[0], OpA.startMeasure);
      expect(start.sublist(1, 3), [MeasureType.pressure.id, 0x01]);
      expect(stop[0], OpA.stopMeasure);
      expect(stop.sublist(1, 4), [MeasureType.pressure.id, 0x04, 0x00]);
    });

    test('realtime HR uses 0x1e action bytes from firmware', () {
      final start = Commands.startContinuousHr();
      final reset = Commands.resetContinuousHrWindow();
      final stop = Commands.stopContinuousHr();
      expect(start[0], OpA.realTimeHeartRate);
      expect(start[1], 0x01);
      expect(reset[0], OpA.realTimeHeartRate);
      expect(reset[1], 0x03);
      expect(stop[0], OpA.realTimeHeartRate);
      expect(stop[1], 0x02);
    });

    test('readSugarLipids defaults to sub 0x03 sugar read', () {
      final f = Commands.readSugarLipids();
      expect(f[0], OpA.sugarLipidsSetting);
      expect(f[1], 0x03);
      expect(f[2], 0x01);
    });

    test('readSugarLipids(isLipids:true) emits lipids sub 0x04 read', () {
      final f = Commands.readSugarLipids(isLipids: true);
      expect(f[0], OpA.sugarLipidsSetting);
      expect(f[1], 0x04);
      expect(f[2], 0x01);
    });

    test('setSugarEnabled sugar enabled encodes [0x3A, 0x03, 0x02, 0x01]', () {
      final f = Commands.setSugarEnabled(enabled: true, isLipids: false);
      expect(f[0], OpA.sugarLipidsSetting);
      expect(f[1], 0x03);
      expect(f[2], 0x02);
      expect(f[3], 0x01);
    });

    test(
      'setSugarEnabled lipids disabled encodes [0x3A, 0x04, 0x02, 0x00]',
      () {
        final f = Commands.setSugarEnabled(enabled: false, isLipids: true);
        expect(f[0], OpA.sugarLipidsSetting);
        expect(f[1], 0x04);
        expect(f[2], 0x02);
        expect(f[3], 0x00);
      },
    );
  });

  group('commands: settings (display / theme / wallpaper / unit)', () {
    test('read/set theme carry the Mixture sub-opcodes', () {
      final r = Commands.readTheme();
      final w = Commands.setTheme(2);
      expect(r[0], OpA.deviceTheme);
      expect(r[1], OpA.mixRead);
      expect(w[0], OpA.deviceTheme);
      expect(w[1], OpA.mixWrite);
      expect(w[2], 0x02);
    });

    test('read/set wallpaper share the same envelope as theme', () {
      final r = Commands.readWallpaper();
      final w = Commands.setWallpaper(7);
      expect(r[0], OpA.deviceWallpaper);
      expect(r[1], OpA.mixRead);
      expect(w[0], OpA.deviceWallpaper);
      expect(w[1], OpA.mixWrite);
      expect(w[2], 0x07);
    });

    test('readAvatar is a bare 0x32 opcode with no payload', () {
      final f = Commands.readAvatar();
      expect(f[0], OpA.deviceAvatar);
      expect(f.sublist(1, 15).every((b) => b == 0), isTrue);
    });

    test('setDisplayClock emits enabled as 1 (on) / 2 (off)', () {
      final on = Commands.setDisplayClock(enabled: true);
      final off = Commands.setDisplayClock(enabled: false);
      expect(on[0], OpA.displayClock);
      expect(on[1], OpA.mixWrite);
      expect(on[2], 0x01);
      expect(off[2], 0x02);
    });

    test('setDisplayOrientation encodes auto-rotate + landscape', () {
      final auto = Commands.setDisplayOrientation(autoRotate: true);
      final fixed = Commands.setDisplayOrientation(
        autoRotate: false,
        landscape: true,
      );
      expect(auto[0], OpA.displayOrientation);
      expect(auto[2], 0x01); // autoRotate on
      expect(auto[3], 0x02); // landscape off
      expect(fixed[2], 0x02); // autoRotate off
      expect(fixed[3], 0x01); // landscape on
    });

    test('setDegreeSwitch emits enabled + C/F toggle', () {
      final c = Commands.setDegreeSwitch(enabled: true, isCelsius: true);
      final f = Commands.setDegreeSwitch(enabled: true, isCelsius: false);
      expect(c[0], OpA.degreeSwitch);
      expect(c[2], 0x01);
      expect(c[3], 0x01); // C
      expect(f[3], 0x02); // F
    });

    test('setTimeFormat XOR-1 inverts the is24 / metric booleans', () {
      // Per PROTOCOL.md §3.1 the on-wire byte is `bool XOR 1`, so
      // `is24: true` packs as 0 and `is24: false` packs as 1.
      final f = Commands.setTimeFormat(is24: true, metric: false);
      expect(f[0], OpA.timeFormat);
      expect(f[1], OpA.mixWrite);
      expect(f[2], 0x00); // !is24
      expect(f[3], 0x01); // !metric

      final f2 = Commands.setTimeFormat(is24: false, metric: true);
      expect(f2[2], 0x01); // !is24
      expect(f2[3], 0x00); // !metric
    });

    test('setPalmScreen packs two booleans into the third byte', () {
      final f = Commands.setPalmScreen(enabled: true, p2: true, p3: true);
      expect(f[0], OpA.palmScreen);
      expect(f[2], 0x01);
      expect(f[3], 0x01);
      expect(f[4], 0x05); // (1 | 4)
    });

    test('setIntell writes enabled + delay', () {
      final f = Commands.setIntell(enabled: true, delaySeconds: 12);
      expect(f[0], OpA.intell);
      expect(f[2], 0x01);
      expect(f[3], 12);
    });
  });

  group('commands: DND / targets / alarms', () {
    test('setDnd packs hour/minute endpoints in BCD-free form', () {
      final f = Commands.setDnd(
        enabled: true,
        startHour: 22,
        startMinute: 0,
        endHour: 7,
        endMinute: 30,
      );
      expect(f[0], OpA.dnd);
      expect(f[1], OpA.mixWrite);
      expect(f[2], 0x01);
      expect(f[3], 22);
      expect(f[4], 0);
      expect(f[5], 7);
      expect(f[6], 30);
    });

    test('setTarget encodes 24-bit LE for steps/calories/distance', () {
      final f = Commands.setTarget(
        steps: 0x010203,
        calories: 0xabcdef,
        distanceMeters: 0x123456,
      );
      expect(f[0], OpA.targetSetting);
      expect(f[1], OpA.mixWrite);
      expect(f.sublist(2, 5), [0x03, 0x02, 0x01]); // LE 0x010203
      expect(f.sublist(5, 8), [0xEF, 0xCD, 0xAB]); // LE 0xABCDEF
      expect(f.sublist(8, 11), [0x56, 0x34, 0x12]); // LE 0x123456
    });

    test('setSitLong emits BCD time + 7-bit weekday mask + cycle', () {
      final f = Commands.setSitLong(
        enabled: true,
        startHour: 9,
        startMinute: 30,
        endHour: 18,
        endMinute: 0,
        weekMask: 0x1F, // weekdays only
        cycleSeconds: 60,
      );
      expect(f[0], OpA.setSitLong);
      expect(Codec.fromBcd(f[1]), 9);
      expect(Codec.fromBcd(f[2]), 30);
      expect(Codec.fromBcd(f[3]), 18);
      expect(Codec.fromBcd(f[4]), 0);
      expect(f[5], 0x1F);
      expect(f[6], 60);
    });

    test('setSitLong clamps unsupported cycle values to 30s', () {
      final f = Commands.setSitLong(
        enabled: true,
        startHour: 9,
        startMinute: 0,
        endHour: 18,
        endMinute: 0,
        cycleSeconds: 45,
      );
      expect(f[6], 30);
    });

    test('setDrinkAlarm indexes from 0..7 with weekday bitmap', () {
      final f = Commands.setDrinkAlarm(
        index: 3,
        enabled: true,
        hour: 14,
        minute: 25,
        weekdays: const [true, false, true, false, true, false, true],
      );
      expect(f[0], OpA.setDrinkAlarm);
      expect(f[1], 3); // index
      expect(f[2], 0x01); // enabled
      expect(Codec.fromBcd(f[3]), 14);
      expect(Codec.fromBcd(f[4]), 25);
      expect(f.sublist(5, 12), [1, 0, 1, 0, 1, 0, 1]);
    });

    test('readDrinkAlarm carries the requested index', () {
      final f = Commands.readDrinkAlarm(5);
      expect(f[0], OpA.readDrinkAlarm);
      expect(f[1], 5);
    });
  });

  group('commands: phone-side sport / GPS', () {
    test('phoneSport carries status + sportType', () {
      final f = Commands.phoneSport(status: 0x01, sportType: 0x02);
      expect(f[0], OpA.phoneSport);
      expect(f[1], 0x01);
      expect(f[2], 0x02);
    });

    test('phoneGpsStatus writes [status, 0x00]', () {
      final f = Commands.phoneGpsStatus(0x03);
      expect(f[0], OpA.phoneGps);
      expect(f[1], 0x03);
      expect(f[2], 0x00);
    });

    test('phoneGpsData packs distance + calories as u32 LE', () {
      final f = Commands.phoneGpsData(
        distanceMeters: 0x12345678,
        calories: 0xAABBCCDD,
      );
      expect(f[0], OpA.phoneGps);
      expect(f[1], 0x05);
      expect(f[2], 0x00);
      expect(f.sublist(3, 7), [0x78, 0x56, 0x34, 0x12]);
      expect(f.sublist(7, 11), [0xDD, 0xCC, 0xBB, 0xAA]);
    });
  });

  group('commands: Channel-B custom watch face', () {
    test('readCustomWatchFace uses 0x3a with action 0x01', () {
      final f = Commands.readCustomWatchFace();
      expect(Codec.rxChannelBCmd(f), OpB.customWatchFace);
      expect(Codec.rxChannelBPayload(f), [0x01]);
    });

    test('writeCustomWatchFace packs 8-byte elements after action 0x02', () {
      final f = Commands.writeCustomWatchFace([
        (type: 1, x: 0x12, y: 0x34, r: 0xAA, g: 0xBB, b: 0xCC),
        (type: 2, x: 0x0040, y: 0x0080, r: 0x11, g: 0x22, b: 0x33),
      ]);
      expect(Codec.rxChannelBCmd(f), OpB.customWatchFace);
      final payload = Codec.rxChannelBPayload(f)!;
      expect(payload[0], 0x02);
      // Element 1
      expect(payload[1], 1);
      expect(payload.sublist(2, 4), [0x12, 0x00]); // x LE
      expect(payload.sublist(4, 6), [0x34, 0x00]); // y LE
      expect(payload[6], 0xAA);
      expect(payload[7], 0xBB);
      expect(payload[8], 0xCC);
      // Element 2 (offset 9)
      expect(payload[9], 2);
      expect(payload.sublist(10, 12), [0x40, 0x00]);
      expect(payload.sublist(12, 14), [0x80, 0x00]);
      expect(payload[14], 0x11);
      expect(payload[15], 0x22);
      expect(payload[16], 0x33);
    });

    test('writeCustomWatchFace truncates to 32 elements', () {
      final elements = List.generate(
        50,
        (i) => (type: 1, x: i, y: 0, r: 0xFF, g: 0xFF, b: 0xFF),
      );
      final f = Commands.writeCustomWatchFace(elements);
      final payload = Codec.rxChannelBPayload(f)!;
      // 1 action byte + 32 × 8 element bytes = 257
      expect(payload.length, 1 + 32 * 8);
    });
  });
}
