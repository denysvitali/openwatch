import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:openwatch/core/ble/ble_transport.dart';
import 'package:openwatch/core/protocol/channel_a.dart';
import 'package:openwatch/core/protocol/codec.dart';
import 'package:openwatch/core/protocol/commands.dart';
import 'package:openwatch/core/protocol/opcodes.dart';
import 'package:openwatch/core/services/watch_manager.dart';

import 'support/fake_ble_transport.dart';

/// Helper: build a `0x24` readAlarm reply with the given decoded
/// fields. Mirrors the wire layout documented in PROTOCOL.md §4.3.
Uint8List _alarmReply({
  required int slot,
  required bool enabled,
  required int hour,
  required int minute,
  List<bool> weekdays = const [false, false, false, false, false, false, false],
}) {
  final days = List<int>.generate(7, (i) => weekdays[i] ? 1 : 0);
  return Codec.buildChannelA(OpA.readAlarm, [
    slot & 0xFF,
    enabled ? 1 : 2,
    Codec.toBcd(hour),
    Codec.toBcd(minute),
    ...days,
  ]);
}

void main() {
  group('Alarm record', () {
    test('weekMask packs Sun..Sat as bits 0..6', () {
      const a = Alarm(
        slot: 0,
        enabled: true,
        hour: 7,
        minute: 0,
        weekdays: [
          true, // Su -> bit 0
          false,
          true, // Tu -> bit 2
          true, // We -> bit 3
          false,
          true, // Fr -> bit 5
          false,
        ],
      );
      // 0b0010_1101 = 0x2D
      expect(a.weekMask, 0x2D);
    });

    test('labelTime formats as 2-digit HH:MM', () {
      const a = Alarm(slot: 0, enabled: true, hour: 9, minute: 5);
      expect(a.labelTime, '09:05');
    });

    test('repeats false when no weekday is selected', () {
      const a = Alarm(slot: 0, enabled: true, hour: 7, minute: 0);
      expect(a.repeats, isFalse);
    });

    test('repeats true when any weekday is selected', () {
      const a = Alarm(
        slot: 0,
        enabled: true,
        hour: 7,
        minute: 0,
        weekdays: [true, false, false, false, false, false, false],
      );
      expect(a.repeats, isTrue);
    });

    test('copyWith returns a modified clone', () {
      const a = Alarm(slot: 0, enabled: true, hour: 7, minute: 0);
      final c = a.copyWith(minute: 30);
      expect(c.slot, 0);
      expect(c.minute, 30);
      expect(c.enabled, isTrue);
      expect(a.minute, 0); // original untouched
    });
  });

  group('Alarm commands', () {
    test('readAlarm builds 0x24 [slot] frame', () {
      final f = Commands.readAlarm(3);
      expect(f.length, 16);
      expect(Codec.rxOpcode(f), OpA.readAlarm);
      expect(Codec.rxPayload(f)[0], 3);
    });

    test(
      'setAlarm builds 0x23 11B frame with BCD hour/min and weekday bits',
      () {
        final f = Commands.setAlarm(
          index: 2,
          enabled: true,
          hour: 7,
          minute: 5,
          weekdays: const [true, false, false, false, false, false, true],
        );
        expect(f.length, 16);
        expect(Codec.rxOpcode(f), OpA.setAlarm);
        final pl = Codec.rxPayload(f);
        expect(pl[0], 2); // slot
        expect(pl[1], 1); // enabled = 1
        expect(pl[2], 0x07); // hour 7 BCD
        expect(pl[3], 0x05); // min 5 BCD
        expect(pl[4], 1); // Su
        expect(pl[10], 1); // Sa
        expect(pl[5], 0); // Mo
      },
    );
  });

  group('Alarm dispatcher', () {
    test('read reply decodes every field', () async {
      final t = FakeBleTransport();
      final d = ChannelADispatcher(t);
      d.bind();
      final got = d.onAlarm.first;
      final f = _alarmReply(
        slot: 1,
        enabled: true,
        hour: 6,
        minute: 30,
        weekdays: const [
          false,
          true,
          true,
          true,
          true,
          true,
          false,
        ], // weekdays Mon..Fri
      );
      t.inA.add(f);
      final a = await got.timeout(const Duration(seconds: 1));
      expect(a.slot, 1);
      expect(a.enabled, isTrue);
      expect(a.hour, 6);
      expect(a.minute, 30);
      expect(a.weekMask, 0x3E); // Mon..Fri
    });

    test('en == 0 is treated as disabled', () async {
      final t = FakeBleTransport();
      final d = ChannelADispatcher(t);
      d.bind();
      final got = d.onAlarm.first;
      final f = _alarmReply(slot: 0, enabled: false, hour: 7, minute: 0);
      t.inA.add(f);
      final a = await got.timeout(const Duration(seconds: 1));
      expect(a.enabled, isFalse);
      // preserved as a record — the UI checks `enabled` not `hour`,
      // so the placeholder hour is fine.
      expect(a.hour, 7);
    });

    test('padded short subData decodes with default zero fields', () async {
      final t = FakeBleTransport();
      final d = ChannelADispatcher(t);
      d.bind();
      final got = d.onAlarm.first;
      // buildChannelA pads subData to a 14-byte Channel-A payload, so
      // this public path still carries enough bytes for the decoder.
      final f = Codec.buildChannelA(OpA.readAlarm, [0x01, 0x01]);
      t.inA.add(f);
      final a = await got.timeout(const Duration(seconds: 1));
      expect(a.slot, 1);
      expect(a.enabled, isTrue);
      expect(a.hour, 0);
      expect(a.minute, 0);
      expect(a.weekdays, List<bool>.filled(7, false));
    });
  });

  group('WatchManager.alarms round-trip', () {
    test('refreshAlarms captures every slot reply in order', () async {
      final t = FakeBleTransport();
      final mgr = WatchManager(t, autoSyncTime: false);
      // Drain the handshake — we only care about alarm traffic.
      await Future<void>.delayed(const Duration(milliseconds: 20));

      // Kick the refresh first; replies can arrive immediately after
      // the read requests, so refreshAlarms must subscribe before it
      // sends the first 0x24 frame.
      final future = mgr.refreshAlarms(
        timeout: const Duration(milliseconds: 80),
      );
      await Future<void>.delayed(Duration.zero);

      // Feed 3 of 5 slot replies back-to-back. The slot map should
      // still contain the slots we did receive after the timeout.
      t.inA.add(
        _alarmReply(
          slot: 0,
          enabled: true,
          hour: 7,
          minute: 0,
          weekdays: const [true, true, true, true, true, true, true],
        ),
      );
      t.inA.add(_alarmReply(slot: 1, enabled: false, hour: 8, minute: 0));
      t.inA.add(
        _alarmReply(
          slot: 2,
          enabled: true,
          hour: 21,
          minute: 30,
          weekdays: const [false, false, false, false, false, true, false],
        ),
      );

      final result = await future.timeout(const Duration(seconds: 1));

      // 3 of 5 replies delivered; the slot map should still be
      // populated for the slots we did receive, even though the
      // wait-for-all timeout fired.
      expect(result.length, 3);
      expect(mgr.alarms.length, 3);
      expect(mgr.alarms.first.slot, 0);
      expect(mgr.alarms.first.enabled, isTrue);
      expect(mgr.alarms[2].weekMask & (1 << 5), isNonZero);

      // Outbound: 5 readAlarm frames (0x24).
      expect(t.sentA.length, greaterThanOrEqualTo(5));
      // The last 5 outbound frames should all be 0x24.
      for (var i = t.sentA.length - 5; i < t.sentA.length; i++) {
        expect(Codec.rxOpcode(t.sentA[i]), OpA.readAlarm);
      }
      mgr.dispose();
    });

    test('setAlarm sends 0x23 with the wire layout', () async {
      final t = FakeBleTransport();
      final mgr = WatchManager(t, autoSyncTime: false);
      await Future<void>.delayed(const Duration(milliseconds: 20));

      const a = Alarm(
        slot: 2,
        enabled: true,
        hour: 6,
        minute: 45,
        weekdays: [false, true, false, true, false, false, false], // Mon, Wed
      );
      final before = t.sentA.length;
      await mgr.setAlarm(a);
      expect(t.sentA.length, before + 1);
      final pl = Codec.rxPayload(t.sentA.last);
      expect(Codec.rxOpcode(t.sentA.last), OpA.setAlarm);
      expect(pl[0], 2); // slot
      expect(pl[1], 1); // enabled = 1
      expect(pl[2], 0x06); // hour 6 BCD
      expect(pl[3], 0x45); // min 45 BCD
      mgr.dispose();
    });

    test('deleteAlarm sends an enabled=false write for the slot', () async {
      final t = FakeBleTransport();
      final mgr = WatchManager(t, autoSyncTime: false);
      await Future<void>.delayed(const Duration(milliseconds: 20));

      // Seed the slot map so deleteAlarm preserves the existing time.
      t.inA.add(_alarmReply(slot: 3, enabled: true, hour: 12, minute: 15));
      // Allow _onAlarm to land via the dispatcher subscription.
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(mgr.alarms.where((a) => a.slot == 3), isNotEmpty);

      await mgr.deleteAlarm(slot: 3);
      final pl = Codec.rxPayload(t.sentA.last);
      expect(Codec.rxOpcode(t.sentA.last), OpA.setAlarm);
      expect(pl[0], 3);
      expect(pl[1], 2); // disabled = 2
      expect(pl[2], 0x12); // hour 12 BCD preserved
      expect(pl[3], 0x15); // minute 15 BCD preserved
      mgr.dispose();
    });

    test('disconnect clears the slot map', () async {
      final t = FakeBleTransport();
      final mgr = WatchManager(t, autoSyncTime: false);
      await Future<void>.delayed(const Duration(milliseconds: 20));

      t.inA.add(_alarmReply(slot: 0, enabled: true, hour: 7, minute: 0));
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(mgr.alarms, isNotEmpty);

      t.linkState.value = LinkState.disconnected;
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(mgr.alarms, isEmpty);
      mgr.dispose();
    });
  });
}
