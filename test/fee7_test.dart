import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:openwatch/core/ble/fee7_service.dart';
import 'package:openwatch/core/protocol/codec.dart';
import 'package:openwatch/core/protocol/fee7_dispatcher.dart';
import 'package:openwatch/core/protocol/opcodes.dart';

/// Minimal in-memory host that satisfies the [Fee7Host] contract.
class _StubHost implements Fee7Host {
  final inbound = StreamController<Uint8List>.broadcast();
  final sent = <Uint8List>[];

  bool _hasWrite = true;
  bool _rejectWrites = false;

  void setHasWrite(bool v) => _hasWrite = v;
  void setRejectWrites(bool v) => _rejectWrites = v;

  @override
  Stream<Uint8List> get fee7Inbound => inbound.stream;

  @override
  bool get hasFee7Write => _hasWrite;

  @override
  Future<void> sendFee7(Uint8List frame) async {
    if (_rejectWrites || !_hasWrite) {
      throw StateError('fee7 write not available');
    }
    sent.add(frame);
  }
}

void main() {
  group('Fee7Service', () {
    test('sendCommand encodes a 16-byte frame with valid checksum', () async {
      final host = _StubHost();
      final svc = Fee7Service.attach(host);

      final frame = Codec.buildChannelA(Fee7.handshakeResponse, [
        0x11,
        0x22,
        0x33,
        0x44,
        0x55,
        0x66,
        0x77,
        0x88,
        0x99,
        0xAA,
        0xBB,
        0xCC,
        0xDD,
        0xEE,
      ]);
      expect(frame.length, 16);
      expect(Codec.isValidChannelA(frame), isTrue);

      await svc.sendCommand(frame);
      expect(host.sent, hasLength(1));
      expect(host.sent.first, frame);
      await svc.dispose();
    });

    test('sendCommand rejects wrong length', () async {
      final host = _StubHost();
      final svc = Fee7Service.attach(host);

      expect(() => svc.sendCommand(Uint8List(15)), throwsArgumentError);
      expect(() => svc.sendCommand(Uint8List(17)), throwsArgumentError);
      // No write should have been attempted.
      expect(host.sent, isEmpty);
      await svc.dispose();
    });

    test('sendCommand rejects frame with bad checksum', () async {
      final host = _StubHost();
      final svc = Fee7Service.attach(host);

      final frame = Codec.buildChannelA(Fee7.echoBase);
      frame[15] = (frame[15] + 1) & 0xFF;
      expect(() => svc.sendCommand(frame), throwsArgumentError);
      expect(host.sent, isEmpty);
      await svc.dispose();
    });
  });

  group('Fee7Dispatcher', () {
    test('routes 0x48 to HandshakeResponse stream', () async {
      final host = _StubHost();
      final svc = Fee7Service.attach(host);
      final d = Fee7Dispatcher(svc);
      d.bind();

      final got = d.onHandshake.first;
      // 15-byte device-info payload (the firmware sends 15 bytes; we surface
      // frame[0..14] = opcode + 14 payload bytes).
      final frame = Codec.buildChannelA(
        Fee7.handshakeResponse,
        List.filled(14, 0x42),
      );
      host.inbound.add(frame);

      final r = await got.timeout(const Duration(seconds: 1));
      expect(r.payload.length, 15);
      expect(r.payload[0], Fee7.handshakeResponse);
      expect(r.raw.length, 14);
      await svc.dispose();
    });

    test(
      '0x48 handshake decodes structured fields per FUN_0082bf40 RE',
      () async {
        final host = _StubHost();
        final svc = Fee7Service.attach(host);
        final d = Fee7Dispatcher(svc);
        d.bind();

        final got = d.onHandshake.first;
        // Build a payload matching the byte order documented in
        // GHIDRA_DECOMPILATION.md §8.2:
        //   pl[0..2]   hw_ver bytes (>>16, >>8, &0xff)
        //   pl[3..4]   pad
        //   pl[5]      fw_ver >> 16
        //   pl[6]      pad
        //   pl[7..8]   fw_ver (&0xff, >>8)
        //   pl[9..11]  batt_raw (mod 100 → percent)
        //   pl[12..13] status (low, high)
        // hw_ver = 0xAABBCC (>>16=0xAA, >>8=0xBB, &0xff=0xCC)
        // fw_ver = 0x112233 (>>16=0x11, &0xff=0x33, >>8=0x22)
        // batt_raw = 0x000064 (= 100, mod 100 = 0)
        // status = 0xBEEF
        final payload = <int>[
          0xAA, 0xBB, 0xCC, 0x00, 0x00, // hw_ver
          0x11, 0x00, 0x33, 0x22, // fw_ver
          0x00, 0x00, 0x64, // batt_raw = 100
          0xEF, 0xBE, // status
        ];
        final frame = Codec.buildChannelA(Fee7.handshakeResponse, payload);
        host.inbound.add(frame);

        final r = await got.timeout(const Duration(seconds: 1));
        expect(r.hwVersion, 0xAABBCC);
        expect(r.fwVersion, 0x112233);
        expect(r.batteryPercent, 0);
        expect(r.status, 0xBEEF);
        await svc.dispose();
      },
    );

    test('routes 0x61 to StatusResponse stream with battery+steps', () async {
      final host = _StubHost();
      final svc = Fee7Service.attach(host);
      final d = Fee7Dispatcher(svc);
      d.bind();

      final got = d.onStatus.first;
      final frame = Codec.buildChannelA(Fee7.statusResponse, [85, 1234 & 0xFF]);
      host.inbound.add(frame);

      final s = await got.timeout(const Duration(seconds: 1));
      expect(s.battery, 85);
      expect(s.steps, 1234 & 0xFF);
      await svc.dispose();
    });

    test('Echo 0x90 emits UnaryOpcode(0x90)', () async {
      final host = _StubHost();
      final svc = Fee7Service.attach(host);
      final d = Fee7Dispatcher(svc);
      d.bind();

      final got = d.onUnary.first;
      final frame = Codec.buildChannelA(Fee7.echoBase);
      host.inbound.add(frame);

      final u = await got.timeout(const Duration(seconds: 1));
      expect(u.opcode, 0x90);
      await svc.dispose();
    });

    test('routes 0x36 SpO2/HR update', () async {
      final host = _StubHost();
      final svc = Fee7Service.attach(host);
      final d = Fee7Dispatcher(svc);
      d.bind();

      final got = d.onSpO2Hr.first;
      final frame = Codec.buildChannelA(Fee7.spo2HrUpdate, [0x01, 0x55]);
      host.inbound.add(frame);

      final s = await got.timeout(const Duration(seconds: 1));
      expect(s.sub, 0x01);
      await svc.dispose();
    });

    test('routes 0x39 HRV setting to onHrv stream', () async {
      final host = _StubHost();
      final svc = Fee7Service.attach(host);
      final d = Fee7Dispatcher(svc);
      d.bind();

      final got = d.onHrv.first;
      // pl[0] = enabled flag (non-zero → true), pl[2] = interval minutes.
      final frame = Codec.buildChannelA(Fee7.hrv, [0x01, 0x00, 30]);
      host.inbound.add(frame);

      final s = await got.timeout(const Duration(seconds: 1));
      expect(s.enabled, isTrue);
      expect(s.intervalMinutes, 30);
      await svc.dispose();
    });

    test('routes 0x3e blood-oxygen update', () async {
      final host = _StubHost();
      final svc = Fee7Service.attach(host);
      final d = Fee7Dispatcher(svc);
      d.bind();

      final got = d.onBloodOxygen.first;
      final frame = Codec.buildChannelA(Fee7.bloodOxygenUpdate, [0x02]);
      host.inbound.add(frame);

      final s = await got.timeout(const Duration(seconds: 1));
      expect(s.sub, 0x02);
      await svc.dispose();
    });

    test('routes 0x3c capability block', () async {
      final host = _StubHost();
      final svc = Fee7Service.attach(host);
      final d = Fee7Dispatcher(svc);
      d.bind();

      final got = d.onCapabilityBlock.first;
      final frame = Codec.buildChannelA(Fee7.capabilityBlock, [
        0x00,
        0x40,
        0xa0,
        0x20,
        0x11,
        0x22,
      ]);
      host.inbound.add(frame);

      final b = await got.timeout(const Duration(seconds: 1));
      expect(b.fixed.length, 6);
      expect(b.fixed[0], Fee7.capabilityBlock);
      // fixed[1..5] are the first 5 payload bytes.
      expect(b.fixed[1], 0x00);
      expect(b.fixed[2], 0x40);
      expect(b.fixed[3], 0xa0);
      await svc.dispose();
    });

    test('routes 0x50 alert trigger', () async {
      final host = _StubHost();
      final svc = Fee7Service.attach(host);
      final d = Fee7Dispatcher(svc);
      d.bind();

      final got = d.onAlert.first;
      final frame = Codec.buildChannelA(Fee7.alertTrigger, [0x14, 0x10, 0x01]);
      host.inbound.add(frame);

      // payload = frame[1..14], zero-padded to 14 bytes.
      final a = await got.timeout(const Duration(seconds: 1));
      expect(a.payload.length, 14);
      expect(a.payload[0], 0x14);
      expect(a.payload[1], 0x10);
      expect(a.payload[2], 0x01);
      await svc.dispose();
    });

    test('routes 0x51 find-phone event with armsPattern flag', () async {
      final host = _StubHost();
      final svc = Fee7Service.attach(host);
      final d = Fee7Dispatcher(svc);
      d.bind();

      final got = d.onFindPhone.first;
      final frame = Codec.buildChannelA(Fee7.findPhoneEvent, [0x00, 0x01]);
      host.inbound.add(frame);

      final f = await got.timeout(const Duration(seconds: 1));
      expect(f.armsPattern, isTrue);
      await svc.dispose();
    });

    test('routes 0x69 mode control', () async {
      final host = _StubHost();
      final svc = Fee7Service.attach(host);
      final d = Fee7Dispatcher(svc);
      d.bind();

      final got = d.onModeControl.first;
      final frame = Codec.buildChannelA(Fee7.modeControl, [0x03]);
      host.inbound.add(frame);

      final m = await got.timeout(const Duration(seconds: 1));
      expect(m.step, 0x03);
      await svc.dispose();
    });

    test('routes reversed 0x6a mode-control continuation response', () async {
      final host = _StubHost();
      final svc = Fee7Service.attach(host);
      final d = Fee7Dispatcher(svc);
      d.bind();

      final got = d.onModeControlCont.first;
      final frame = Codec.buildChannelA(0x08, [Fee7.modeControlCont, 0x42]);
      host.inbound.add(frame);

      final m = await got.timeout(const Duration(seconds: 1));
      expect(m.step, 0x08);
      expect(m.payload.first, 0x42);
      await svc.dispose();
    });

    test('routes 0xc3 OTA trigger and detects routesToOta flag', () async {
      final host = _StubHost();
      final svc = Fee7Service.attach(host);
      final d = Fee7Dispatcher(svc);
      d.bind();

      final got = d.onOta.first;
      final frame = Codec.buildChannelA(Fee7.otaTrigger, [0x00, 0x00, 0x01]);
      host.inbound.add(frame);

      final o = await got.timeout(const Duration(seconds: 1));
      expect(o.routesToOta, isTrue);
      await svc.dispose();
    });

    test('routes 0xfe vibration pattern ONLY to onVibration', () async {
      final host = _StubHost();
      final svc = Fee7Service.attach(host);
      final d = Fee7Dispatcher(svc);
      d.bind();

      final vibEvents = <VibrationPattern>[];
      final unaryEvents = <UnaryOpcode>[];
      final vibSub = d.onVibration.listen(vibEvents.add);
      final unarySub = d.onUnary.listen(unaryEvents.add);
      final frame = Codec.buildChannelA(Fee7.vibrationPattern, [0x64]);
      host.inbound.add(frame);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await vibSub.cancel();
      await unarySub.cancel();

      expect(vibEvents, hasLength(1));
      expect(unaryEvents, isEmpty); // 0xfe must NOT double-emit on onUnary
      await svc.dispose();
    });

    test('unknown opcodes fall through to unknown stream', () async {
      final host = _StubHost();
      final svc = Fee7Service.attach(host);
      final d = Fee7Dispatcher(svc);
      d.bind();

      final got = d.unknown.first;
      final frame = Codec.buildChannelA(0x7b); // 0x7b is a documented no-op
      host.inbound.add(frame);

      final u = await got.timeout(const Duration(seconds: 1));
      expect(u.opcode, 0x7b);
      await svc.dispose();
    });

    test('0x61 status low-byte step counter', () async {
      final host = _StubHost();
      final svc = Fee7Service.attach(host);
      final d = Fee7Dispatcher(svc);
      d.bind();

      final got = d.onStatus.first;
      final frame = Codec.buildChannelA(Fee7.statusResponse, [80, 0xAB]);
      host.inbound.add(frame);

      final s = await got.timeout(const Duration(seconds: 1));
      expect(s.battery, 80);
      expect(s.stepsLowByte, 0xAB);
      expect(s.steps, 0xAB); // back-compat alias
      await svc.dispose();
    });
  });
}
