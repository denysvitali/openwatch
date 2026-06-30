import 'package:flutter_test/flutter_test.dart';
import 'package:openwatch/core/protocol/channel_a.dart';
import 'package:openwatch/core/protocol/codec.dart';
import 'package:openwatch/core/protocol/commands.dart';
import 'package:openwatch/core/protocol/opcodes.dart';

import 'support/fake_ble_transport.dart';

void main() {
  group('HeartRateSetting commands', () {
    test('readHeartRateSetting builds 0x16 with sub 0x01', () {
      final f = Commands.readHeartRateSetting();
      expect(f.length, 16);
      expect(Codec.rxOpcode(f), OpA.heartRateSetting);
      final pl = Codec.rxPayload(f);
      expect(pl[0], OpA.mixRead);
    });

    test('setHeartRateSetting builds 0x16 with sub 0x02 + all fields', () {
      final f = Commands.setHeartRateSetting(
        enabled: true,
        interval: 30,
        startInterval: 0,
        tooLow: 50,
        tooHigh: 180,
      );
      expect(f.length, 16);
      expect(Codec.rxOpcode(f), OpA.heartRateSetting);
      final pl = Codec.rxPayload(f);
      expect(pl[0], OpA.mixWrite);
      expect(pl[1], 1); // enabled = 1
      expect(pl[2], 30); // interval
      expect(pl[3], 0); // startInterval
      expect(pl[4], 50); // tooLow
      expect(pl[5], 180); // tooHigh
    });

    test('setHeartRateSetting disabled encodes enabled as 2', () {
      final f = Commands.setHeartRateSetting(enabled: false, interval: 60);
      final pl = Codec.rxPayload(f);
      expect(pl[1], 2); // disabled = 2
      expect(pl[2], 60); // interval
    });

    test('setHeartRateSetting masks values with & 0xFF', () {
      final f = Commands.setHeartRateSetting(
        enabled: true,
        interval: 300, // > 255, buildChannelA masks with & 0xFF
        tooLow: 300,
        tooHigh: 300,
      );
      final pl = Codec.rxPayload(f);
      expect(pl[2], 300 & 0xFF); // 44
      expect(pl[4], 300 & 0xFF); // 44
      expect(pl[5], 300 & 0xFF); // 44
    });

    test('setHeartRateSetting uses default alarm thresholds', () {
      final f = Commands.setHeartRateSetting(enabled: true, interval: 15);
      final pl = Codec.rxPayload(f);
      expect(pl[4], 50); // default tooLow
      expect(pl[5], 180); // default tooHigh
    });
  });

  group('HeartRateSetting decoder', () {
    test('read response decodes all fields', () async {
      final t = FakeBleTransport();
      final d = ChannelADispatcher(t);
      d.bind();
      final got = d.onHeartRateSetting.first;
      final f = Codec.buildChannelA(OpA.heartRateSetting, [
        0x01, // sub = read
        0x01, // enabled
        30, // interval
        0, // startInterval
        50, // tooLow
        180, // tooHigh
      ]);
      t.inA.add(f);
      final s = await got.timeout(const Duration(seconds: 1));
      expect(s.enabled, isTrue);
      expect(s.interval, 30);
      expect(s.startInterval, 0);
      expect(s.tooLow, 50);
      expect(s.tooHigh, 180);
    });

    test('read response disabled maps to enabled=false', () async {
      final t = FakeBleTransport();
      final d = ChannelADispatcher(t);
      d.bind();
      final got = d.onHeartRateSetting.first;
      final f = Codec.buildChannelA(OpA.heartRateSetting, [
        0x01,
        0x02, // disabled
        60,
        0,
        45,
        200,
      ]);
      t.inA.add(f);
      final s = await got.timeout(const Duration(seconds: 1));
      expect(s.enabled, isFalse);
      expect(s.interval, 60);
      expect(s.tooLow, 45);
      expect(s.tooHigh, 200);
    });

    test('write ack decodes from shifted layout', () async {
      final t = FakeBleTransport();
      final d = ChannelADispatcher(t);
      d.bind();
      final got = d.onHeartRateSetting.first;
      // Write ack: pl = [sub=0x02, _, enabled, interval, startInterval, tooLow, tooHigh]
      final f = Codec.buildChannelA(OpA.heartRateSetting, [
        0x02,
        0x00,
        0x01, // enabled at pl[2]
        15, // interval at pl[3]
        0, // startInterval at pl[4]
        55, // tooLow at pl[5]
        175, // tooHigh at pl[6]
      ]);
      t.inA.add(f);
      final s = await got.timeout(const Duration(seconds: 1));
      expect(s.enabled, isTrue);
      expect(s.interval, 15);
      expect(s.tooLow, 55);
      expect(s.tooHigh, 175);
    });

    test('write ack with tooHigh at pl[6] defaulting when absent', () async {
      final t = FakeBleTransport();
      final d = ChannelADispatcher(t);
      d.bind();
      final got = d.onHeartRateSetting.first;
      // Write ack with only 6 payload bytes: pl[6] would be 0 (zero-pad).
      final f = Codec.buildChannelA(OpA.heartRateSetting, [
        0x02,
        0x00,
        0x01, // enabled at pl[2]
        15, // interval at pl[3]
        0, // startInterval at pl[4]
        55, // tooLow at pl[5]
        // tooHigh at pl[6] is 0 from zero-pad
      ]);
      t.inA.add(f);
      final s = await got.timeout(const Duration(seconds: 1));
      expect(s.enabled, isTrue);
      expect(s.interval, 15);
      expect(s.tooLow, 55);
      expect(s.tooHigh, 0); // zero-pad value
    });
  });

  group('HeartRateSetting record', () {
    test('const construction with defaults', () {
      const s = HeartRateSetting(enabled: true, interval: 30);
      expect(s.enabled, isTrue);
      expect(s.interval, 30);
      expect(s.startInterval, 0);
      expect(s.tooLow, 50);
      expect(s.tooHigh, 180);
    });

    test('const construction with all fields', () {
      const s = HeartRateSetting(
        enabled: false,
        interval: 60,
        startInterval: 10,
        tooLow: 45,
        tooHigh: 200,
      );
      expect(s.enabled, isFalse);
      expect(s.interval, 60);
      expect(s.startInterval, 10);
      expect(s.tooLow, 45);
      expect(s.tooHigh, 200);
    });
  });
}
