import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:openwatch/core/protocol/codec.dart';
import 'package:openwatch/core/protocol/opcodes.dart';
import 'package:openwatch/core/services/watch_manager.dart';

import 'support/fake_ble_transport.dart';

/// Minimal DeviceSupport (0x3c) reply so handshake can finish.
Uint8List _supportReply() => Codec.buildChannelA(OpA.deviceSupport, [
  0x00,
  0x40,
  0x00,
  0x00,
  0x00,
  0x00,
  0xa0,
  0x00,
  0x00,
  0x00,
  0x20,
  0x00,
  0x00,
  0x00,
]);

Future<void> _completeHandshake(FakeBleTransport t) async {
  // Wait for the 0x3c request, then reply. Handshake also fires
  // todaySport + battery fire-and-forget which we leave unanswered
  // (timeout path is fine for this test).
  for (var i = 0; i < 50; i++) {
    final pending = t.sentA.where(
      (f) => f.isNotEmpty && f[0] == OpA.deviceSupport,
    );
    if (pending.isNotEmpty) {
      t.inA.add(_supportReply());
      return;
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  fail('handshake never sent DeviceSupport (0x3c)');
}

void main() {
  group('WatchManager sensor settings on connect', () {
    test('handshake pushes HR (0x16) and stress (0x38) settings', () async {
      final t = FakeBleTransport();
      final mgr = WatchManager(
        t,
        autoSyncTime: false,
        hrAutoMeasureEnabled: true,
        hrIntervalMinutes: 5,
        hrLowAlarm: 50,
        hrHighAlarm: 120,
        stressAutoMeasureEnabled: true,
      );
      addTearDown(mgr.dispose);

      unawaited(_completeHandshake(t));
      // Handshake waits up to 400ms for sport/battery replies.
      await Future<void>.delayed(const Duration(milliseconds: 600));

      expect(mgr.initialized, isTrue);

      final hrSettings = t.sentA
          .where(
            (f) => f.isNotEmpty && Codec.rxOpcode(f) == OpA.heartRateSetting,
          )
          .toList();
      expect(hrSettings, isNotEmpty, reason: '0x16 must be pushed on connect');
      final hrPl = Codec.rxPayload(hrSettings.first);
      // [mixWrite=0x02, en=1, interval=5, startInterval=0, tooLow=50, tooHigh=120]
      expect(hrPl[0], OpA.mixWrite);
      expect(hrPl[1], 1);
      expect(hrPl[2], 5);
      expect(hrPl[4], 50);
      expect(hrPl[5], 120);

      final stressSettings = t.sentA
          .where(
            (f) => f.isNotEmpty && Codec.rxOpcode(f) == OpA.pressureSetting,
          )
          .toList();
      expect(
        stressSettings,
        isNotEmpty,
        reason: '0x38 stress enable must be pushed on connect',
      );
      final stressPl = Codec.rxPayload(stressSettings.first);
      expect(stressPl[0], OpA.mixWrite);
      expect(stressPl[1], 1);
    });

    test('autoApplySensorSettings=false skips the push', () async {
      final t = FakeBleTransport();
      final mgr = WatchManager(
        t,
        autoSyncTime: false,
        autoApplySensorSettings: false,
      );
      addTearDown(mgr.dispose);

      unawaited(_completeHandshake(t));
      await Future<void>.delayed(const Duration(milliseconds: 600));

      expect(mgr.initialized, isTrue);
      expect(
        t.sentA.where(
          (f) => f.isNotEmpty && Codec.rxOpcode(f) == OpA.heartRateSetting,
        ),
        isEmpty,
      );
      expect(
        t.sentA.where(
          (f) => f.isNotEmpty && Codec.rxOpcode(f) == OpA.pressureSetting,
        ),
        isEmpty,
      );
    });
  });
}
