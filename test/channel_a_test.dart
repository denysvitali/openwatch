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

    test('heartRateSetting 0x16 read decodes enabled + interval + alarms', () async {
      final t = _StubTransport();
      final d = ChannelADispatcher(t);
      d.bind();
      final got = d.onHeartRateSetting.first;
      // pl = [sub=0x01, enabled=0x01, interval=30, startInterval=0, tooLow=50, tooHigh=180]
      final f = Codec.buildChannelA(OpA.heartRateSetting, [
        0x01, // sub = read
        0x01, // enabled (1=on, 2=off)
        30, // interval minutes
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

    test('heartRateSetting 0x16 read disabled maps enabled=false', () async {
      final t = _StubTransport();
      final d = ChannelADispatcher(t);
      d.bind();
      final got = d.onHeartRateSetting.first;
      // pl = [sub=0x01, enabled=0x02, interval=60, ...]
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

    test('heartRateSetting 0x16 write ack decodes from shifted layout', () async {
      final t = _StubTransport();
      final d = ChannelADispatcher(t);
      d.bind();
      final got = d.onHeartRateSetting.first;
      // Write ack: pl = [sub=0x02, _, enabled, interval, startInterval, tooLow, tooHigh]
      // The write ack echoes the request; enabled is at pl[2].
      final f = Codec.buildChannelA(OpA.heartRateSetting, [
        0x02, // sub = write
        0x00, // padding / reserved
        0x01, // enabled
        15, // interval
        0, // startInterval
        55, // tooLow
        175, // tooHigh
      ]);
      t.inA.add(f);
      final s = await got.timeout(const Duration(seconds: 1));
      expect(s.enabled, isTrue);
      expect(s.interval, 15);
      expect(s.startInterval, 0);
      expect(s.tooLow, 55);
      expect(s.tooHigh, 175);
    });

    test('heartRateSetting 0x16 short payload is ignored', () async {
      final t = _StubTransport();
      final d = ChannelADispatcher(t);
      d.bind();
      var fired = false;
      final sub = d.onHeartRateSetting.listen((_) {
        fired = true;
      });
      // Only 2 bytes — too short for either read or write decode.
      final f = Codec.buildChannelA(OpA.heartRateSetting, [0x01, 0x01]);
      t.inA.add(f);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(fired, isFalse);
      await sub.cancel();
    });

    test('bloodOxygenSetting 0x2c decodes 1-bit SpO2 toggle', () async {
      final t = _StubTransport();
      final d = ChannelADispatcher(t);
      d.bind();
      final got = d.onBloodOxygen.first;
      // sub=0x01 (read), value=0x01 (enabled).
      final f = Codec.buildChannelA(OpA.bloodOxygenSetting, [0x01, 0x01]);
      t.inA.add(f);
      final s = await got.timeout(const Duration(seconds: 1));
      expect(s.sub, 0x01);
      expect(s.enabled, isTrue);
    });

    test(
      'bloodOxygenSetting 0x2c disabled maps value 0 to enabled=false',
      () async {
        final t = _StubTransport();
        final d = ChannelADispatcher(t);
        d.bind();
        final got = d.onBloodOxygen.first;
        final f = Codec.buildChannelA(OpA.bloodOxygenSetting, [0x01, 0x00]);
        t.inA.add(f);
        final s = await got.timeout(const Duration(seconds: 1));
        expect(s.enabled, isFalse);
      },
    );

    test(
      'muslim 0x7a stub flag fires on [0x7A, 0xFF] (unimplemented RE)',
      () async {
        final t = _StubTransport();
        final d = ChannelADispatcher(t);
        d.bind();
        final got = d.onMuslim.first;
        // Per GHIDRA_DECOMPILATION.md §3.11 the v14 firmware returns the
        // one-byte stub error frame [0x7A, 0xFF] for every read because
        // FUN_00829c88 is unimplemented.
        final f = Codec.buildChannelA(OpA.muslim, [0x01, 0xff]);
        t.inA.add(f);
        final m = await got.timeout(const Duration(seconds: 1));
        expect(m.sub, 0x01);
        expect(m.stubbed, isTrue);
      },
    );

    test('muslim 0x7a non-stub frame leaves stubbed=false', () async {
      final t = _StubTransport();
      final d = ChannelADispatcher(t);
      d.bind();
      final got = d.onMuslim.first;
      // pl[1] != 0xFF — assume a future firmware would emit the
      // header byte instead of the stub error.
      final f = Codec.buildChannelA(OpA.muslim, [0x01, 0x00]);
      t.inA.add(f);
      final m = await got.timeout(const Duration(seconds: 1));
      expect(m.stubbed, isFalse);
    });

    test(
      'pressure 0x38 decodes 1-bit on/off setting (sub echo + value)',
      () async {
        final t = _StubTransport();
        final d = ChannelADispatcher(t);
        d.bind();
        final got = d.onPressure.first;
        // sub = 0x01 (read), value = 0x01 (enabled).
        final f = Codec.buildChannelA(OpA.pressure, [0x01, 0x01]);
        t.inA.add(f);
        final p = await got.timeout(const Duration(seconds: 1));
        expect(p.enabled, isTrue);
      },
    );

    test('pressure 0x38 disabled maps value 0 to enabled=false', () async {
      final t = _StubTransport();
      final d = ChannelADispatcher(t);
      d.bind();
      final got = d.onPressure.first;
      final f = Codec.buildChannelA(OpA.pressure, [0x01, 0x00]);
      t.inA.add(f);
      final p = await got.timeout(const Duration(seconds: 1));
      expect(p.enabled, isFalse);
    });

    test('touchControl 0x3b read decodes sub + batch + config byte', () async {
      final t = _StubTransport();
      final d = ChannelADispatcher(t);
      d.bind();
      final got = d.onUvTouch.first;
      // sub=0x01 (read), batch=0x00 (commit), configByte=0x42.
      final f = Codec.buildChannelA(OpA.touchControl, [0x01, 0x00, 0x42]);
      t.inA.add(f);
      final u = await got.timeout(const Duration(seconds: 1));
      expect(u.sub, 0x01);
      expect(u.batchMode, isFalse);
      expect(u.configByte, 0x42);
    });

    test(
      'touchControl 0x3b batch mode (req[1]!=0) sets batchMode=true',
      () async {
        final t = _StubTransport();
        final d = ChannelADispatcher(t);
        d.bind();
        final got = d.onUvTouch.first;
        final f = Codec.buildChannelA(OpA.touchControl, [0x02, 0x01, 0x42]);
        t.inA.add(f);
        final u = await got.timeout(const Duration(seconds: 1));
        expect(u.sub, 0x02);
        expect(u.batchMode, isTrue);
      },
    );

    test('bpData 0x0d emits chunk with monotonic seq', () async {
      final t = _StubTransport();
      final d = ChannelADispatcher(t);
      d.bind();
      final got = d.onBpRecord.first;
      final payload = List<int>.filled(14, 0xab);
      final f = Codec.buildChannelA(OpA.bpData, payload);
      t.inA.add(f);
      final c = await got.timeout(const Duration(seconds: 1));
      expect(c.seq, 0);
      expect(c.payload, Uint8List.fromList(payload));
    });

    test('bpData 0x0d seq increments per chunk', () async {
      final t = _StubTransport();
      final d = ChannelADispatcher(t);
      d.bind();
      final chunks = <BpRecordChunk>[];
      final sub = d.onBpRecord.listen(chunks.add);
      // Two chunks: header (14 B) + body (5 B).
      t.inA.add(Codec.buildChannelA(OpA.bpData, List.filled(14, 0xab)));
      t.inA.add(
        Codec.buildChannelA(OpA.bpData, [0x01, 0x02, 0x03, 0x04, 0x05]),
      );
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(chunks.length, 2);
      expect(chunks[0].seq, 0);
      expect(chunks[1].seq, 1);
      expect(chunks[0].payload.length, 14);
      expect(chunks[1].payload, [
        0x01,
        0x02,
        0x03,
        0x04,
        0x05,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
      ]);
      await sub.cancel();
    });

    test(
      'pressureSetting 0x37 header (pl[2]==0x1E) routes to onPressureSettingHeader',
      () async {
        final t = _StubTransport();
        final d = ChannelADispatcher(t);
        d.bind();
        final got = d.onPressureSettingHeader.first;
        // Header dword `0x1E050037` LE → frame bytes [0x37, slotId,
        // 0x05, 0x1E]; pl indexes shift down by one so pl[2] = 0x1E.
        final f = Codec.buildChannelA(OpA.pressureSetting, [0x00, 0x05, 0x1e]);
        t.inA.add(f);
        final h = await got.timeout(const Duration(seconds: 1));
        expect(h.slotId, 0x00);
      },
    );

    test(
      'pressureSetting 0x37 non-header frame routes to onPressureSettingChunk',
      () async {
        final t = _StubTransport();
        final d = ChannelADispatcher(t);
        d.bind();
        final got = d.onPressureSettingChunk.first;
        // pl[3] != 0x1E → chunk frame.
        final payload = [0xde, 0xad, 0xbe, 0xef];
        final f = Codec.buildChannelA(OpA.pressureSetting, [
          0x01,
          0x00,
          0x00,
          ...payload,
        ]);
        // Pad to 4 bytes minimum (pl[3] discriminator check).
        // Actually the buildChannelA helper will already zero-pad.
        t.inA.add(f);
        final c = await got.timeout(const Duration(seconds: 1));
        expect(c.payload.length, 14);
      },
    );

    test(
      'hrvSetting 0x39 header (pl[2]==0x1E) routes to onHrvHeader',
      () async {
        final t = _StubTransport();
        final d = ChannelADispatcher(t);
        d.bind();
        final got = d.onHrvHeader.first;
        // Header dword `0x1E050039` LE → frame bytes [0x39, slotId,
        // 0x05, 0x1E]; pl shifts down by one so pl[2] = 0x1E.
        final f = Codec.buildChannelA(OpA.hrv, [0x00, 0x05, 0x1e]);
        t.inA.add(f);
        final h = await got.timeout(const Duration(seconds: 1));
        expect(h.slotId, 0x00);
      },
    );

    test('hrvSetting 0x39 non-header frame routes to onHrvChunk', () async {
      final t = _StubTransport();
      final d = ChannelADispatcher(t);
      d.bind();
      final got = d.onHrvChunk.first;
      // pl[2] != 0x1E → chunk frame.
      final f = Codec.buildChannelA(OpA.hrv, [
        0x01,
        0x00,
        0x00,
        0xde,
        0xad,
        0xbe,
        0xef,
      ]);
      t.inA.add(f);
      final c = await got.timeout(const Duration(seconds: 1));
      expect(c.payload.length, 14);
    });

    test('readHeartRate 0x15 header frame fires onHeartRateHeader', () async {
      final t = _StubTransport();
      final d = ChannelADispatcher(t);
      d.bind();
      var fired = false;
      final sub = d.onHeartRateHeader.listen((_) {
        fired = true;
      });
      // pl[0] = 0x18 is the discriminator per GHIDRA_DECOMPILATION.md
      // §3.12 (the feature-bitmap dword's payload-size low byte).
      final f = Codec.buildChannelA(OpA.readHeartRate, [0x18, 0x80, 0x05]);
      t.inA.add(f);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(fired, isTrue);
      await sub.cancel();
    });

    test(
      'readHeartRate 0x15 chunk frame fires onHeartRateChunk with seq + payload',
      () async {
        final t = _StubTransport();
        final d = ChannelADispatcher(t);
        d.bind();
        final got = d.onHeartRateChunk.first;
        // pl[0] = seq (1); pl[1..] = payload bytes. buildChannelA
        // pads the rest of the 14-byte payload with zeros — the wire
        // shape never has trailing-zero filler, but the codec helper
        // does. The decoder surfaces the raw 13-byte chunk as-is.
        final payload = [0xde, 0xad, 0xbe, 0xef];
        final f = Codec.buildChannelA(OpA.readHeartRate, [1, ...payload]);
        t.inA.add(f);
        final c = await got.timeout(const Duration(seconds: 1));
        expect(c.seq, 1);
        // First 4 payload bytes match what we sent; rest is the codec's
        // zero-pad (the firmware never emits a <13-byte chunk, but our
        // build helper pads to fill the 14-byte payload field).
        expect(c.payload.sublist(0, payload.length), payload);
        expect(c.payload.length, 13);
      },
    );

    test(
      'readHeartRate 0x15 error frame (pl[0]==0xff) fires onHeartRateError',
      () async {
        final t = _StubTransport();
        final d = ChannelADispatcher(t);
        d.bind();
        var fired = false;
        final sub = d.onHeartRateError.listen((_) {
          fired = true;
        });
        final f = Codec.buildChannelA(OpA.readHeartRate, [0xff]);
        t.inA.add(f);
        await Future<void>.delayed(const Duration(milliseconds: 20));
        expect(fired, isTrue);
        await sub.cancel();
      },
    );

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

    test('deviceReboot 0xc6 ack frame fires onRestoreKey', () async {
      final t = _StubTransport();
      final d = ChannelADispatcher(t);
      d.bind();
      // Caller marks the outbound context (e.g. ProtocolHub does this
      // immediately after the 0xc6 send). Without the mark, the
      // dispatcher can't tell a reboot ack from a distribution
      // error response — both arrive as wire byte 0xC6.
      d.markRebootRequest();
      var fired = false;
      final sub = d.onRestoreKey.listen((_) {
        fired = true;
      });
      // Ack path: sub != 0x6C, so the watch queues a 1-byte ack.
      final f = Codec.buildChannelA(OpA.deviceReboot, [0x01]);
      t.inA.add(f);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(fired, isTrue);
      await sub.cancel();
    });

    test(
      'queryDataDistribution 0x46 success frame fires onQueryDataDistribution '
      'with decoded bitmask',
      () async {
        final t = _StubTransport();
        final d = ChannelADispatcher(t);
        d.bind();
        d.markDistributionQuery();
        final got = d.onQueryDataDistribution.first;
        // Known mask 0x00000005 → days 0 and 2 have data.
        final f = Codec.buildChannelA(OpA.queryDataDistribution, [
          0x00,
          0x00,
          0x00,
          0x05,
        ]);
        t.inA.add(f);
        final q = await got.timeout(const Duration(seconds: 1));
        expect(q.errorFlag, isFalse);
        expect(q.mask, 0x00000005);
        expect(q.hasData(0), isTrue);
        expect(q.hasData(1), isFalse);
        expect(q.hasData(2), isTrue);
        expect(q.hasData(31), isFalse);
      },
    );

    test(
      'queryDataDistribution 0xC6 (0x46|0x80) error frame surfaces errorFlag',
      () async {
        // Regression test for the original
        // `case OpA.deviceReboot || 0x46:` pattern-disjunction bug
        // which silently routed every 0x46 frame to onRestoreKey.
        // With markDistributionQuery() called before the request, the
        // 0xC6 error-flagged response now lands on
        // onQueryDataDistribution with errorFlag=true, NOT on
        // onRestoreKey.
        final t = _StubTransport();
        final d = ChannelADispatcher(t);
        d.bind();
        d.markDistributionQuery();
        final dist = <QueryDataDistribution>[];
        final restoreFired = <void>[];
        final sub1 = d.onQueryDataDistribution.listen(dist.add);
        final sub2 = d.onRestoreKey.listen(restoreFired.add);
        // wire byte 0xC6 (= 0x46 | 0x80) is the device-side error
        // flag pattern. pl[0] = 0xee is the firmware-specific error
        // subcode. buildChannelA puts 0x46 in byte[0]; OR in the
        // error flag bit and recompute the checksum so the dispatcher
        // accepts the frame.
        final f = Codec.buildChannelA(OpA.queryDataDistribution, [
          0xee,
          0x00,
          0x00,
          0x00,
        ]);
        f[0] = f[0] | 0x80;
        // Recompute additive checksum over bytes 0..14.
        var sum = 0;
        for (var i = 0; i < 15; i++) {
          sum = (sum + f[i]) & 0xFF;
        }
        f[15] = sum;
        t.inA.add(f);
        await Future<void>.delayed(const Duration(milliseconds: 20));
        expect(dist.length, 1);
        expect(dist.first.errorFlag, isTrue);
        expect(restoreFired, isEmpty);
        await sub1.cancel();
        await sub2.cancel();
      },
    );

    test('0xC6 frame WITHOUT outbound mark goes to onQueryDataDistribution '
        '(default — no spurious onRestoreKey)', () async {
      // When the host hasn't called either markRebootRequest() or
      // markDistributionQuery(), a 0xC6 frame must NOT fire
      // onRestoreKey — that was the original bug. The dispatcher
      // defaults to the distribution decoder since reboot context
      // is opt-in.
      final t = _StubTransport();
      final d = ChannelADispatcher(t);
      d.bind();
      final dist = <QueryDataDistribution>[];
      final restoreFired = <void>[];
      final sub1 = d.onQueryDataDistribution.listen(dist.add);
      final sub2 = d.onRestoreKey.listen(restoreFired.add);
      final f = Codec.buildChannelA(OpA.queryDataDistribution, [
        0x00,
        0x00,
        0x00,
        0x01,
      ]);
      t.inA.add(f);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(dist.length, 1);
      expect(restoreFired, isEmpty);
      await sub1.cancel();
      await sub2.cancel();
    });

    test(
      'emitRestoreKey fires onRestoreKey (optimistic 0x6C reboot ack)',
      () async {
        final t = _StubTransport();
        final d = ChannelADispatcher(t);
        d.bind();
        var fired = false;
        final sub = d.onRestoreKey.listen((_) {
          fired = true;
        });
        // Sub 0x6C tears down BLE — host fires the event optimistically.
        d.emitRestoreKey();
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

    test(
      'sugarLipidsSetting 0x3a read sub 0x03 (sugar) decodes feature value',
      () async {
        final t = _StubTransport();
        final d = ChannelADispatcher(t);
        d.bind();
        final got = d.onSugarLipids.first;
        // pl = [sub=0x03, subCmd=0x01, value=0x01] → sugar enabled.
        final f = Codec.buildChannelA(OpA.sugarLipidsSetting, [
          0x03,
          0x01,
          0x01,
        ]);
        t.inA.add(f);
        final s = await got.timeout(const Duration(seconds: 1));
        expect(s.sub, 0x03);
        expect(s.featureValue, 0x01);
        expect(s.writeAcksEcho, isFalse);
      },
    );

    test(
      'sugarLipidsSetting 0x3a read sub 0x04 (lipids) decodes feature value',
      () async {
        final t = _StubTransport();
        final d = ChannelADispatcher(t);
        d.bind();
        final got = d.onSugarLipids.first;
        // pl = [sub=0x04, subCmd=0x01, value=0x00] → lipids disabled.
        final f = Codec.buildChannelA(OpA.sugarLipidsSetting, [
          0x04,
          0x01,
          0x00,
        ]);
        t.inA.add(f);
        final s = await got.timeout(const Duration(seconds: 1));
        expect(s.sub, 0x04);
        expect(s.featureValue, 0x00);
        expect(s.writeAcksEcho, isFalse);
      },
    );

    test(
      'sugarLipidsSetting 0x3a sugar write echo sets writeAcksEcho=true',
      () async {
        // Per GHIDRA_DECOMPILATION.md §3.22, the `0x03 0x02` write ack
        // echoes the request frame unchanged — verify the dispatcher
        // surfaces writeAcksEcho=true so the host can distinguish the
        // echo shape from a regular read response.
        final t = _StubTransport();
        final d = ChannelADispatcher(t);
        d.bind();
        final got = d.onSugarLipids.first;
        // Build the echo: pl = [0x03, 0x02, 0x01] (sugar write with value=1).
        final f = Codec.buildChannelA(OpA.sugarLipidsSetting, [
          0x03,
          0x02,
          0x01,
        ]);
        t.inA.add(f);
        final s = await got.timeout(const Duration(seconds: 1));
        expect(s.sub, 0x03);
        expect(s.featureValue, 0x01);
        expect(s.writeAcksEcho, isTrue);
      },
    );

    test(
      'sugarLipidsSetting 0x3a lipids write ack keeps writeAcksEcho=false',
      () async {
        // Per GHIDRA_DECOMPILATION.md §3.22, the lipids write path uses a
        // 1-byte-cmd ack `[0x3A, 0, 0, 0, 0…0, cksum]` — the feature
        // value byte is zeroed out. Verify the dispatcher surfaces
        // writeAcksEcho=false so the host knows to issue a follow-up
        // read to confirm the bit flipped.
        final t = _StubTransport();
        final d = ChannelADispatcher(t);
        d.bind();
        final got = d.onSugarLipids.first;
        // pl = [0x04, 0x02, 0x00] — the lipids 1-byte-cmd ack.
        final f = Codec.buildChannelA(OpA.sugarLipidsSetting, [
          0x04,
          0x02,
          0x00,
        ]);
        t.inA.add(f);
        final s = await got.timeout(const Duration(seconds: 1));
        expect(s.sub, 0x04);
        expect(s.featureValue, 0x00);
        expect(s.writeAcksEcho, isFalse);
      },
    );

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

    test('todaySport 0x48 routes totals to onTodaySport', () async {
      final t = _StubTransport();
      final d = ChannelADispatcher(t);
      d.bind();
      final got = d.onTodaySport.first;
      t.inA.add(
        Codec.buildChannelA(OpA.todaySport, [
          0x00, 0x10, 0x00, // steps = 4096
          0x00, 0x00, 0x2a, // running
          0x00, 0x01, 0xf4, // calories = 500
          0x00, 0x0b, 0xb8, // distance = 3000 m
          0x01, 0x2c, // duration = 300 s
        ]),
      );
      final totals = await got.timeout(const Duration(seconds: 1));
      expect(totals.steps, 4096);
      expect(totals.running, 42);
      expect(totals.calories, 500);
      expect(totals.distanceMeters, 3000);
      expect(totals.durationSeconds, 300);
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
        // BCD 0x26/0x06/0x14 + slot byte (slot=10 -> 10<<2=0x28)
        // + record index/count + duration/aux pairs matching live
        // H59MA_V1.0 0x43 captures.
        final payload = <int>[
          0x26, // year BCD
          0x06, // month BCD
          0x14, // day BCD
          0x28, // slot << 2
          0x02, // record index
          0x0e, // header record count echo
          0x34, 0x12, // duration u16 LE
          0x78, 0x56, // auxLo u16 LE
          0x9a, 0x00, // auxHi u16 LE
          0x00, 0x00, // reserved
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
