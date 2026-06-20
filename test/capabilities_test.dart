import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:openwatch/core/protocol/capabilities.dart';

void main() {
  // Builds a 14-byte SetTimeRsp payload with the bits at the byte offsets
  // listed in PROTOCOL.md §4.2.1 set according to [byteValues].
  Uint8List setTimePayload(Map<int, int> byteValues) {
    final out = Uint8List(14);
    for (final entry in byteValues.entries) {
      if (entry.key >= 0 && entry.key < 14) {
        out[entry.key] = entry.value & 0xFF;
      }
    }
    return out;
  }

  group('DeviceCapabilities.fromSetTime', () {
    test('flags heart + sleep from pl[1]', () {
      // pl[1] = 0b1100_0000 = 0xC0.
      final caps = DeviceCapabilities.fromSetTime(setTimePayload({1: 0xC0}));
      expect(caps.heart, isTrue);
      expect(caps.sleep, isTrue);
    });

    test(
        'flags bloodOxygen + bloodPressure + weather + customWallpaper '
        'from pl[3]', () {
      // pl[3] = 0b0010_0111 = 0x27.
      final caps = DeviceCapabilities.fromSetTime(setTimePayload({3: 0x27}));
      expect(caps.customWallpaper, isTrue);
      expect(caps.bloodOxygen, isTrue);
      expect(caps.bloodPressure, isTrue);
      expect(caps.weather, isTrue);
    });

    test('wechat is inverted on pl[3] b6', () {
      // b6 == 0 ⇒ WeChat support.
      expect(
        DeviceCapabilities.fromSetTime(setTimePayload({3: 0x00})).wechat,
        isTrue,
      );
      // b6 == 1 ⇒ no WeChat support.
      expect(
        DeviceCapabilities.fromSetTime(setTimePayload({3: 0x40})).wechat,
        isFalse,
      );
    });

    test('avatar flag on pl[3] b7', () {
      expect(
        DeviceCapabilities.fromSetTime(setTimePayload({3: 0x80})).avatar,
        isTrue,
      );
    });

    test('newSleepProtocol is pl[8] == 1', () {
      expect(
        DeviceCapabilities.fromSetTime(setTimePayload({8: 0})).newSleepProtocol,
        isFalse,
      );
      expect(
        DeviceCapabilities.fromSetTime(setTimePayload({8: 1})).newSleepProtocol,
        isTrue,
      );
    });

    test('gps / jieLiMusic / album from pl[0xa]', () {
      // pl[0xa] = 0b0001_1100 = 0x1C.
      final caps = DeviceCapabilities.fromSetTime(setTimePayload({0x0a: 0x1C}));
      expect(caps.album, isTrue);
      expect(caps.gps, isTrue);
      expect(caps.jieLiMusic, isTrue);
    });

    test('bloodSugar on pl[0xb] b7', () {
      expect(
        DeviceCapabilities.fromSetTime(setTimePayload({0x0b: 0x80})).bloodSugar,
        isTrue,
      );
    });

    test('ecard / ebook / musicSupport / location on pl[0xb]', () {
      // pl[0xb] = 0b0101_0110 = 0x56 (ecard, location, musicSupport, ebook).
      final caps = DeviceCapabilities.fromSetTime(setTimePayload({0x0b: 0x56}));
      expect(caps.ecard, isTrue);
      expect(caps.location, isTrue);
      expect(caps.musicSupport, isTrue);
      expect(caps.ebook, isTrue);
    });

    test('stress / hrv / record / bpSetting / fourG on pl[0xd]', () {
      // pl[0xd] = 0b0011_0111 = 0x37 (record, bpSetting, 4G, stress, hrv).
      final caps = DeviceCapabilities.fromSetTime(setTimePayload({0x0d: 0x37}));
      expect(caps.record, isTrue);
      expect(caps.bpSetting, isTrue);
      expect(caps.fourG, isTrue);
      expect(caps.stress, isTrue);
      expect(caps.hrv, isTrue);
    });

    test('maxContacts == 20 when pl[0xc] == 0 else value * 8', () {
      expect(
        DeviceCapabilities.fromSetTime(setTimePayload({0x0c: 0})).maxContacts,
        20,
      );
      expect(
        DeviceCapabilities.fromSetTime(setTimePayload({0x0c: 4})).maxContacts,
        32,
      );
    });

    test('screen size encoded as little-endian u16', () {
      final caps = DeviceCapabilities.fromSetTime(
        setTimePayload({
          4: 0x40, // 64
          5: 0x01, // +256 = 320
          6: 0x40,
          7: 0x01,
        }),
      );
      expect(caps.screenWidth, 320);
      expect(caps.screenHeight, 320);
    });

    test('short payloads yield defaults', () {
      final caps = DeviceCapabilities.fromSetTime(Uint8List(5));
      expect(caps.heart, isFalse);
      expect(caps.screenWidth, 0);
    });
  });

  group('DeviceCapabilities.mergeSupport', () {
    Uint8List supportPayload(Map<int, int> byteValues) {
      final out = Uint8List(12);
      for (final entry in byteValues.entries) {
        if (entry.key >= 0 && entry.key < out.length) {
          out[entry.key] = entry.value & 0xFF;
        }
      }
      return out;
    }

    test('alarm + dnd on pl[6]', () {
      // pl[6] = 0b1100_0000 = 0xC0.
      final merged = DeviceCapabilities().mergeSupport(
        supportPayload({6: 0xC0}),
      );
      expect(merged.alarm, isTrue);
      expect(merged.dnd, isTrue);
    });

    test('ultraviolet + realTimeHr on pl[7]', () {
      // pl[7] = 0b0000_1001 = 0x09.
      final merged = DeviceCapabilities().mergeSupport(
        supportPayload({7: 0x09}),
      );
      expect(merged.ultraviolet, isTrue);
      expect(merged.realTimeHr, isTrue);
    });

    test('reduceFat + hideMessageNotification on pl[8]', () {
      // pl[8] = 0b0001_1000 = 0x18.
      final merged = DeviceCapabilities().mergeSupport(
        supportPayload({8: 0x18}),
      );
      expect(merged.reduceFat, isTrue);
      expect(merged.hideMessageNotification, isTrue);
    });

    test('wechatPay + menuWallpaper on pl[4]', () {
      // pl[4] = 0b0000_0101 = 0x05.
      final merged = DeviceCapabilities().mergeSupport(
        supportPayload({4: 0x05}),
      );
      expect(merged.wechatPay, isTrue);
      expect(merged.menuWallpaper, isTrue);
    });

    test('aiAnalyze on pl[3] b7', () {
      final merged = DeviceCapabilities().mergeSupport(
        supportPayload({3: 0x80}),
      );
      expect(merged.aiAnalyze, isTrue);
    });

    test('temperatureTwoHundred on pl[0xa] b1', () {
      final merged = DeviceCapabilities().mergeSupport(
        supportPayload({0x0a: 0x02}),
      );
      expect(merged.temperatureTwoHundred, isTrue);
    });

    test('takePhoto is inverted on pl[6] b2', () {
      expect(
        DeviceCapabilities().mergeSupport(supportPayload({6: 0x00})).takePhoto,
        isTrue,
      );
      expect(
        DeviceCapabilities().mergeSupport(supportPayload({6: 0x04})).takePhoto,
        isFalse,
      );
    });

    test('muslim flag honors either pl[1] b1 or pl[5] b7', () {
      expect(
        DeviceCapabilities().mergeSupport(supportPayload({1: 0x02})).muslim,
        isTrue,
      );
      expect(
        DeviceCapabilities().mergeSupport(supportPayload({5: 0x80})).muslim,
        isTrue,
      );
      expect(
        DeviceCapabilities().mergeSupport(supportPayload({})).muslim,
        isFalse,
      );
    });

    test('preserves screen / heart / sleep from the SetTime manifest', () {
      final base = DeviceCapabilities.fromSetTime(
        setTimePayload({
          1: 0xC0, // heart + sleep
          4: 240,
          5: 0x00,
          6: 240,
          7: 0x00,
        }),
      );
      final merged = base.mergeSupport(supportPayload({}));
      expect(merged.heart, isTrue);
      expect(merged.sleep, isTrue);
      expect(merged.screenWidth, 240);
      expect(merged.screenHeight, 240);
    });
  });
}
