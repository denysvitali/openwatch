import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:openwatch/core/ble/ble_transport.dart';
import 'package:openwatch/core/protocol/channel_a.dart';
import 'package:openwatch/core/protocol/codec.dart';
import 'package:openwatch/core/protocol/opcodes.dart';

class _StubTransport implements BleTransport {
  final inA = StreamController<Uint8List>.broadcast();

  @override
  Stream<Uint8List> get inboundA => inA.stream;

  @override
  Future<void> sendA(Uint8List frame) async {}

  @override
  Future<void> sendB(Uint8List framed) async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

void main() {
  group('ChannelADispatcher', () {
    test('setTime ACK decodes BCD back to DateTime', () async {
      final t = _StubTransport();
      final d = ChannelADispatcher(t);
      d.bind();
      final got = d.onTime.first;
      final f = Codec.buildChannelA(OpA.setTime, [
        Codec.toBcd(26), // year % 100
        Codec.toBcd(6),
        Codec.toBcd(20),
        Codec.toBcd(14),
        Codec.toBcd(30),
        Codec.toBcd(45),
        0, // lang
        ((2 + 24) % 24) * 2 + 1, // tz
      ]);
      t.inA.add(f);
      final ts = await got.timeout(const Duration(seconds: 1));
      expect(ts.year, 2026);
      expect(ts.month, 6);
      expect(ts.day, 20);
      expect(ts.hour, 14);
    });

    test('realTimeHeartRate emits plausible bpm only', () async {
      final t = _StubTransport();
      final d = ChannelADispatcher(t);
      d.bind();
      final samples = <int>[];
      final sub = d.onRealtimeHr.listen(samples.add);
      final f = Codec.buildChannelA(OpA.realTimeHeartRate, [72]);
      t.inA.add(f);
      // 0xFF should be ignored (implausible).
      final f2 = Codec.buildChannelA(OpA.realTimeHeartRate, [0xFF]);
      t.inA.add(f2);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await sub.cancel();
      expect(samples, [72]);
    });

    test('pushMsgUint extracts text and skips null padding', () async {
      final t = _StubTransport();
      final d = ChannelADispatcher(t);
      d.bind();
      final got = d.onPushMsg.first;
      // type, lenLo, lenHi, "Hello" + zero pad
      final f = Codec.buildChannelA(OpA.pushMsgUint, [
        0x02,
        5,
        0,
        ...'Hello'.codeUnits,
      ]);
      t.inA.add(f);
      final msg = await got.timeout(const Duration(seconds: 1));
      expect(msg.type, 0x02);
      expect(msg.text, contains('Hello'));
    });

    test('DND read sub emits state', () async {
      final t = _StubTransport();
      final d = ChannelADispatcher(t);
      d.bind();
      final got = d.onDnd.first;
      final f = Codec.buildChannelA(OpA.dnd, [0x01, 0x01]);
      t.inA.add(f);
      final s = await got.timeout(const Duration(seconds: 1));
      expect(s.enabled, isTrue);
    });

    test('DND read decodes enable byte + 4-byte time window', () async {
      final t = _StubTransport();
      final d = ChannelADispatcher(t);
      d.bind();
      final got = d.onDnd.first;
      // pl[0]=sub(0x01) pl[1]=enable(0x01 on) pl[2..5]=window (22:00..07:30).
      final f = Codec.buildChannelA(OpA.dnd, [0x01, 0x01, 22, 0, 7, 30]);
      t.inA.add(f);
      final s = await got.timeout(const Duration(seconds: 1));
      expect(s.enabled, isTrue);
      expect(s.startHour, 22);
      expect(s.startMinute, 0);
      expect(s.endHour, 7);
      expect(s.endMinute, 30);
    });

    test('DND read decodes enable byte 0x02 as disabled', () async {
      final t = _StubTransport();
      final d = ChannelADispatcher(t);
      d.bind();
      final got = d.onDnd.first;
      final f = Codec.buildChannelA(OpA.dnd, [0x01, 0x02, 0, 0, 0, 0]);
      t.inA.add(f);
      final s = await got.timeout(const Duration(seconds: 1));
      expect(s.enabled, isFalse);
    });

    test('readSitLong 0x26 decodes BCD window + flags + interval', () async {
      final t = _StubTransport();
      final d = ChannelADispatcher(t);
      d.bind();
      final got = d.onSedentary.first;
      // pl[0..5] = BCD start_hour, BCD start_min, BCD end_hour,
      // BCD end_min, flags, interval. Build a 09:00..22:00 window,
      // enabled (flags=0x01), interval=30 minutes.
      final f = Codec.buildChannelA(OpA.readSitLong, [
        Codec.toBcd(9),
        Codec.toBcd(0),
        Codec.toBcd(22),
        Codec.toBcd(0),
        0x01,
        30,
      ]);
      t.inA.add(f);
      final s = await got.timeout(const Duration(seconds: 1));
      expect(s.enabled, isTrue);
      expect(s.startHour, 9);
      expect(s.startMinute, 0);
      expect(s.endHour, 22);
      expect(s.endMinute, 0);
      expect(s.flags, 0x01);
      expect(s.interval, 30);
    });

    test('readSitLong 0x26 flags bit 0 maps to enabled=false', () async {
      final t = _StubTransport();
      final d = ChannelADispatcher(t);
      d.bind();
      final got = d.onSedentary.first;
      // flags=0x00 (disabled), interval=0
      final f = Codec.buildChannelA(OpA.readSitLong, [
        Codec.toBcd(8),
        Codec.toBcd(30),
        Codec.toBcd(18),
        Codec.toBcd(0),
        0x00,
        0,
      ]);
      t.inA.add(f);
      final s = await got.timeout(const Duration(seconds: 1));
      expect(s.enabled, isFalse);
      expect(s.startHour, 8);
      expect(s.startMinute, 30);
    });

    test(
      'emitFactoryReset fires onFactoryReset (host-side optimistic ack)',
      () async {
        final t = _StubTransport();
        final d = ChannelADispatcher(t);
        d.bind();
        var fired = false;
        final sub = d.onFactoryReset.listen((_) {
          fired = true;
        });
        d.emitFactoryReset();
        await Future<void>.delayed(const Duration(milliseconds: 20));
        expect(fired, isTrue);
        await sub.cancel();
      },
    );

    test('phoneSport start/finish (sub 0x01) decodes to startFinish', () async {
      final t = _StubTransport();
      final d = ChannelADispatcher(t);
      d.bind();
      final got = d.onPhoneSport.first;
      final f = Codec.buildChannelA(OpA.phoneSport, [0x01]);
      t.inA.add(f);
      final u = await got.timeout(const Duration(seconds: 1));
      expect(u.sub, PhoneSportSub.startFinish);
      expect(u.gpsDelta, isNull);
    });

    test(
      'phoneSport gpsDelta (sub 0x05) decodes u24 LE steps/meters',
      () async {
        final t = _StubTransport();
        final d = ChannelADispatcher(t);
        d.bind();
        final got = d.onPhoneSport.first;
        // pl[0] = 0x05, pl[1] reserved, pl[2..4] = steps (u24 LE),
        // pl[5] reserved, pl[6..8] = meters (u24 LE).
        // steps  = 0x000ABC = 2748
        // meters = 0x001234 = 4660
        final f = Codec.buildChannelA(OpA.phoneSport, [
          0x05,
          0x00,
          0xBC, 0x0A, 0x00, // steps u24 LE
          0x00,
          0x34, 0x12, 0x00, // meters u24 LE
        ]);
        t.inA.add(f);
        final u = await got.timeout(const Duration(seconds: 1));
        expect(u.sub, PhoneSportSub.gpsDelta);
        expect(u.gpsDelta, isNotNull);
        expect(u.gpsDelta!.steps, 0x000ABC);
        expect(u.gpsDelta!.meters, 0x001234);
      },
    );

    test('factory 0xa1 sub 0x01 decodes to fullReset', () async {
      final t = _StubTransport();
      final d = ChannelADispatcher(t);
      d.bind();
      final got = d.onFactoryCommand.first;
      final f = Codec.buildChannelA(0xa1, [0x01]);
      t.inA.add(f);
      final cmd = await got.timeout(const Duration(seconds: 1));
      expect(cmd.action, FactoryAction.fullReset);
      expect(cmd.rawSub, 0x01);
    });

    test('factory 0xa1 sub 0x07 maps to unknown action', () async {
      final t = _StubTransport();
      final d = ChannelADispatcher(t);
      d.bind();
      final got = d.onFactoryCommand.first;
      final f = Codec.buildChannelA(0xa1, [0x07]);
      t.inA.add(f);
      final cmd = await got.timeout(const Duration(seconds: 1));
      expect(cmd.action, FactoryAction.unknown);
      expect(cmd.rawSub, 0x07);
    });

    test('invalid frames are dropped silently', () async {
      final t = _StubTransport();
      final d = ChannelADispatcher(t);
      d.bind();
      final got = d.unknown.first.timeout(
        const Duration(milliseconds: 100),
        onTimeout: () => ChannelAFrame(-1, Uint8List(0)),
      );
      // Send a 16-byte frame with broken checksum; should not produce any
      // event on `unknown` either.
      final bad = Codec.buildChannelA(0x55);
      bad[15] = (bad[15] + 1) & 0xFF;
      t.inA.add(bad);
      final u = await got;
      expect(u.opcode, -1);
    });

    test('vibration 0xc7 fragments arrive on onVibrationChunk', () async {
      final t = _StubTransport();
      final d = ChannelADispatcher(t);
      d.bind();
      final chunks = <VibrationChunk>[];
      final sub = d.onVibrationChunk.listen(chunks.add);

      // Send three fragments (simulating a 0xc7 fragmented response). The
      // codec pads short payloads to 14 bytes with zeros — that is the
      // wire shape (the firmware never emits a <14-byte chunk, but our
      // build helper pads for tests).
      final payloads = [
        Uint8List.fromList(List<int>.generate(14, (i) => i + 1)),
        Uint8List.fromList(List<int>.generate(14, (i) => i + 0x10)),
        Uint8List.fromList(List<int>.generate(14, (i) => i + 0x20)),
      ];
      for (final pl in payloads) {
        t.inA.add(Codec.buildChannelA(OpA.vibrationResponse, pl));
      }
      await Future<void>.delayed(const Duration(milliseconds: 20));

      expect(chunks.length, 3);
      expect(chunks[0].seq, 0);
      expect(chunks[1].seq, 1);
      expect(chunks[2].seq, 2);
      expect(chunks[0].payload, payloads[0]);
      expect(chunks[1].payload, payloads[1]);
      expect(chunks[2].payload, payloads[2]);
      await sub.cancel();
    });

    test('displayClock 0x18 echoes style + label slice', () async {
      final t = _StubTransport();
      final d = ChannelADispatcher(t);
      d.bind();
      final got = d.onDisplayClock.first;
      // Style 0x02 = label style, slot 0; length 0x05 echoes 5 label bytes.
      final label = [0x4f, 0x5f, 0x46, 0x41, 0x43]; // "O_FAC"
      final payload = <int>[0x02, 0x05, 0x05, ...label];
      t.inA.add(Codec.buildChannelA(OpA.displayClock, payload));
      final r = await got.timeout(const Duration(seconds: 1));
      expect(r.style, 0x02);
      expect(r.length, 0x05);
      expect(r.echoedLength, 0x05);
      expect(r.label, Uint8List.fromList(label));
    });

    test(
      'readDetailSport 0x43 header frame routes to onSportDetailHeader',
      () async {
        final t = _StubTransport();
        final d = ChannelADispatcher(t);
        d.bind();
        final got = d.onSportDetailHeader.first;
        // endOfData=false (0xf0), count=2, unitFlag=1 (seconds).
        t.inA.add(Codec.buildChannelA(OpA.readDetailSport, [0xf0, 0x02, 0x01]));
        final h = await got.timeout(const Duration(seconds: 1));
        expect(h.endOfData, isFalse);
        expect(h.recordCount, 0x02);
        expect(h.unitFlag, 0x01);
      },
    );

    test(
      'readDetailSport 0x43 record frame routes to onSportDetailRecord',
      () async {
        final t = _StubTransport();
        final d = ChannelADispatcher(t);
        d.bind();
        final got = d.onSportDetailRecord.first;
        // BCD 0x26/0x06/0x14 + packed (record=2, slot=10 -> (2)|(10<<2)=0x2a)
        // + duration lo u16 LE (0x1234) at pl[7..8] + auxLo (0x5678) at
        // pl[9..10] + auxHi (0x9a 0x00) at pl[11..12] + duration hi (0x00)
        // at pl[13].
        final payload = <int>[
          0x26, // year BCD
          0x06, // month BCD
          0x14, // day BCD
          0x2a, // packed low
          0x00, // packed high
          0x00, 0x00, // reserved
          0x34, 0x12, // duration lo u16 LE
          0x78, 0x56, // auxLo u16 LE
          0x9a, 0x00, // auxHi u16 LE
          0x00, // duration hi
        ];
        t.inA.add(Codec.buildChannelA(OpA.readDetailSport, payload));
        final r = await got.timeout(const Duration(seconds: 1));
        expect(r.year, 26);
        expect(r.month, 6);
        expect(r.day, 14);
        expect(r.recordIdx, 2);
        expect(r.slotIdx, 10);
        expect(r.duration & 0xffff, 0x1234);
        expect(r.auxLo, 0x5678);
        expect(r.auxHi, 0x9a);
      },
    );
  });
}
