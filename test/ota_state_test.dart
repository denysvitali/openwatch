import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:openwatch/core/protocol/codec.dart';
import 'package:openwatch/core/protocol/opcodes.dart';
import 'package:openwatch/core/protocol/ota_state.dart';

void main() {
  group('OtaStateMachine', () {
    late OtaSession session;
    late OtaStateMachine sm;

    setUp(() {
      session = OtaSession(
        image: Uint8List.fromList(List<int>.generate(2048, (i) => i & 0xFF)),
        sizeBytes: 2048,
      )..signature = 0xdeadbeef;
      session.pocketCount = (session.sizeBytes / 1024).ceil();
      sm = OtaStateMachine(session: session);
    });

    test('signature check rejects zero', () {
      session
        ..signature = 0
        ..phase = OtaPhase.idle;
      expect(sm.checkSignature(), isFalse);
    });

    test('signature check accepts non-zero', () {
      session.signature = 0xcafebabe;
      expect(sm.checkSignature(), isTrue);
    });

    test('computeChecksums derives CRC16 and additive', () {
      sm.computeChecksums();
      expect(session.crc16, Codec.crc16(session.image));
      var sum = 0;
      for (final b in session.image) {
        sum += b & 0xFF;
      }
      expect(session.additive, sum & 0xFFFF);
    });

    test('payloadFor(initialized) packs size+CRC+additive LE', () {
      sm.computeChecksums();
      session.phase = OtaPhase.initialized;
      final pl = sm.payloadFor(OtaPhase.initialized);
      expect(pl[0], 0x01);
      expect(Codec.readU32le(pl, 1), session.sizeBytes);
      expect(Codec.readU16le(pl, 5), session.crc16);
      expect(Codec.readU16le(pl, 7), session.additive);
    });

    test('illegal transition moves to error', () {
      session.phase = OtaPhase.idle;
      // idle → data is illegal; must jump to error.
      expect(sm.transition(OtaPhase.data), isFalse);
      expect(session.phase, OtaPhase.error);
      expect(session.errorMessage, contains('illegal'));
    });

    test('happy-path transitions are allowed', () {
      session.phase = OtaPhase.idle;
      expect(sm.transition(OtaPhase.started), isTrue);
      expect(sm.transition(OtaPhase.initialized), isTrue);
      expect(sm.transition(OtaPhase.data), isTrue);
      expect(sm.transition(OtaPhase.data), isTrue); // multiple data sends
      expect(sm.transition(OtaPhase.checking), isTrue);
      expect(sm.transition(OtaPhase.complete), isTrue);
    });

    test('acceptRsp OK keeps phase intact', () {
      session.phase = OtaPhase.data;
      expect(sm.acceptRsp(rspType: OpB.rspOk, status: 0), isTrue);
      expect(session.phase, OtaPhase.data);
    });

    test('acceptRsp low-battery transitions to error', () {
      session.phase = OtaPhase.data;
      expect(sm.acceptRsp(rspType: OpB.rspLowBattery, status: 0), isFalse);
      expect(session.phase, OtaPhase.error);
      expect(session.errorMessage, contains('battery'));
    });

    test('acceptRsp non-zero status transitions to error', () {
      session.phase = OtaPhase.initialized;
      expect(sm.acceptRsp(rspType: OpB.rspCmdStatus, status: 7), isFalse);
      expect(session.phase, OtaPhase.error);
      expect(session.errorMessage, contains('device error'));
    });
  });
}
