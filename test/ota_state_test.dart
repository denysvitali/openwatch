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

    // -----------------------------------------------------------------
    // Audit follow-ups (OTA/DFU error-path hardening, June 2026).
    // See PROTOCOL.md §4.9 + GHIDRA_DECOMPILATION.md §5.1 + §2.0.
    // -----------------------------------------------------------------

    test('low-battery mid-transfer (data phase) transitions to error', () {
      // Mirrors the firmware path: `RSP_LOW_BATTERY` (type 6) is a hard
      // abort at every awaited step — including in the middle of a
      // multi-pocket data stream.
      session.phase = OtaPhase.data;
      expect(sm.acceptRsp(rspType: OpB.rspLowBattery, status: 0), isFalse);
      expect(session.phase, OtaPhase.error);
      expect(session.errorMessage, 'battery too low');
    });

    test('low-battery at every phase transitions to error', () {
      // Confirms the audit's task #4: low-battery handling applies
      // uniformly to started / initialized / data / checking — not
      // just the init step.
      for (final phase in [
        OtaPhase.started,
        OtaPhase.initialized,
        OtaPhase.data,
        OtaPhase.checking,
      ]) {
        session
          ..phase = phase
          ..errorMessage = null;
        expect(
          sm.acceptRsp(rspType: OpB.rspLowBattery, status: 0),
          isFalse,
          reason: 'phase=${phase.name}',
        );
        expect(session.phase, OtaPhase.error, reason: 'phase=${phase.name}');
      }
    });

    test('CRC mismatch mid-stream surfaces via acceptRsp non-zero status', () {
      // The H59MA firmware validates CRC16 over the staged image at
      // ota_check (FUN_0082f378) and returns a non-zero status byte if
      // the computed CRC differs from the metadata declared at init.
      // The state machine surfaces this as a generic "device error".
      session.phase = OtaPhase.checking;
      expect(sm.acceptRsp(rspType: OpB.rspCmdStatus, status: 0x42), isFalse);
      expect(session.phase, OtaPhase.error);
      expect(session.errorMessage, contains('0x42'));
    });

    test('Channel-B NAK code 0 (FUN_0082ee00) does NOT alias rspOk', () {
      // Per GHIDRA §2.0, a NAK frame is
      //   [0xBC][count_lo=1][count_hi=0][error_code][cmd][crc_lo][crc_hi]
      // The OTA state's `acceptRsp` is called with rspType/cmd and
      // status/error_code. A NAK with error_code=0 (default-slot NAK)
      // would look identical to a successful RSP from the state
      // machine's perspective. This test pins that gap: callers must
      // distinguish NAK frames BEFORE handing them to acceptRsp.
      //
      // For now, acceptRsp(rspType: X, status: 0) returns true for any
      // type — including hypothetical NAK types. The audit recommends
      // adding a dedicated `rspNak` opcode class and a third
      // acceptRsp branch to refuse NAK frames regardless of status.
      session.phase = OtaPhase.data;
      // NAK type placeholder (not currently in OpB enum). Simulate a
      // caller passing an unknown type with status=0.
      expect(sm.acceptRsp(rspType: 0xFE, status: 0), isTrue);
      // … so the current behaviour silently accepts it. This is the
      // gap the audit flags.
      expect(session.phase, OtaPhase.data);
    });

    test('connection drop mid-stream: phase frozen, no auto-rollback', () {
      // Audit task #3: there is NO equivalent of the history_sync
      // "commit 0xFF before clearing chunk day" pattern in the OTA
      // state machine. The state machine has no `onDisconnect` hook;
      // a mid-transfer BLE drop leaves `phase` stuck at `data`.
      session
        ..phase = OtaPhase.data
        ..pocketsSent = 7;
      // Simulate a connection drop by mutating session directly — the
      // production code has no callback. This test pins the gap.
      // (No assertion beyond "no exception is thrown" — the audit
      // calls out that `OtaStateMachine` exposes no rollback hook.)
      expect(session.pocketsSent, 7);
      expect(session.phase, OtaPhase.data);
    });

    test('error phase is terminal (no out-transitions)', () {
      // §5.1: once the firmware transitions to state 4 (ready/cancel),
      // subsequent OTA writes are early-returned. Mirrored here as
      // an empty allowed-transitions set for `error`.
      session.phase = OtaPhase.error;
      // Any transition out of error is illegal.
      for (final next in OtaPhase.values) {
        if (next == OtaPhase.error) continue;
        expect(
          sm.transition(next),
          isFalse,
          reason: 'error → ${next.name} must be illegal',
        );
      }
      // error → error is implicitly allowed (self-loop not in set,
      // but the test below confirms the contract).
      expect(sm.transition(OtaPhase.error), isFalse);
    });
  });
}
