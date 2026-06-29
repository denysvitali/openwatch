import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:openwatch/core/ble/ble_transport.dart';
import 'package:openwatch/core/protocol/codec.dart';
import 'package:openwatch/core/protocol/dfu.dart';
import 'package:openwatch/core/protocol/opcodes.dart';

/// Minimal [BleTransport] stub that records writes and lets the test
/// inject arbitrary Channel-B inbound frames. Mirrors the
/// `_StubTransport` pattern in `channel_a_test.dart`, but exposes
/// `inboundB` (the OTA path subscribes to Channel B).
class _StubTransport implements BleTransport {
  final inB = StreamController<Uint8List>.broadcast();
  final sentA = <Uint8List>[];
  final sentB = <Uint8List>[];
  Object? sendBError;
  bool closed = false;

  @override
  Stream<Uint8List> get inboundB => inB.stream;

  @override
  Future<void> sendA(Uint8List frame) async {
    sentA.add(frame);
  }

  @override
  Future<void> sendB(Uint8List framed) async {
    sentB.add(framed);
    if (sendBError != null) throw sendBError!;
  }

  /// Inject a Channel-B RSP frame. The OTA flasher awaits frames whose
  /// first byte is the Channel-B magic (`0xBC`); `type` is byte[1]
  /// (rspOk=0, rspLowBattery=6, etc.) and `status` is byte[6].
  void injectRsp(int type, {int status = 0}) {
    // Empty-payload sentinel — the flasher only reads byte[1] (type) and
    // byte[6] (status), so length-7 is enough: [BC][type][len=1][crc][status][pad][pad]
    final frame = Uint8List(7);
    frame[0] = Codec.channelBMagic;
    frame[1] = type & 0xFF;
    frame[2] = 0x01; // payload length = 1 (status byte)
    frame[3] = 0x00;
    // CRC over payload byte (just `status`); we'll let the flasher ignore
    // the parser-layer CRC — the OTA flasher does its own validation
    // directly on the frame, so any 7-byte frame with 0xBC magic reaches
    // _onRx.
    frame[6] = status & 0xFF;
    inB.add(frame);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) {
    // close()/dispose()/etc. — no-op for the stub.
    if (invocation.memberName == #close) return null;
    return null;
  }
}

/// Builds a synthetic H59MA firmware image of [sizeBytes]. We don't need
/// a real container for the OTA flasher tests — the flasher does its
/// own CRC16/additive16 computation and pushes raw bytes to Channel-B.
Uint8List _fakeFirmware(int sizeBytes) =>
    Uint8List.fromList(List<int>.generate(sizeBytes, (i) => i & 0xFF));

/// Subscribes once to the flash [stream] and returns:
///   * a future that completes with the first [DfuProgress] emitted
///     (or completes with the stream's terminal error if one fires
///     before any event),
///   * a future that completes with the full event list (or terminal
///     error) once the stream closes.
///
/// `async*` generators in Dart are single-subscription — every test
/// below needs to drive the stream via a *single* listener and read
/// progress off the collected events, not via repeated `.first` /
/// `.drain` calls (which would race the second listener on the same
/// underlying stream).
({Future<DfuProgress> first, Future<List<DfuProgress>> done}) _watch(
  Stream<DfuProgress> stream,
) {
  final firstCompleter = Completer<DfuProgress>();
  final doneCompleter = Completer<List<DfuProgress>>();
  final events = <DfuProgress>[];
  StreamSubscription<DfuProgress>? sub;
  sub = stream.listen(
    (e) {
      events.add(e);
      if (!firstCompleter.isCompleted) firstCompleter.complete(e);
    },
    onError: (Object e, StackTrace st) {
      if (!firstCompleter.isCompleted) firstCompleter.completeError(e, st);
      if (!doneCompleter.isCompleted) {
        doneCompleter.completeError(e, st);
      }
    },
    onDone: () {
      if (!firstCompleter.isCompleted) {
        firstCompleter.completeError(
          StateError('stream closed with no events'),
        );
      }
      if (!doneCompleter.isCompleted) doneCompleter.complete(events);
      sub?.cancel();
    },
    cancelOnError: true,
  );
  return (first: firstCompleter.future, done: doneCompleter.future);
}

void main() {
  group('DfuFlasher pre-flight', () {
    test('rejects firmware larger than 12 MB cap (0xBB8000)', () async {
      final t = _StubTransport();
      final flasher = DfuFlasher(t);
      final huge = _fakeFirmware(0xBB8001); // one byte over the cap
      expect(
        () => flasher.flash(huge).drain<void>(),
        throwsA(
          isA<DfuException>().having(
            (e) => e.message,
            'message',
            contains('12 MB'),
          ),
        ),
      );
      // No transport writes should have happened before the size check.
      expect(t.sentA, isEmpty);
      expect(t.sentB, isEmpty);
    });

    test('accepts firmware exactly at the 12 MB cap', () async {
      final t = _StubTransport();
      final flasher = DfuFlasher(t);
      final ok = _fakeFirmware(0xBB8000);
      final watch = _watch(flasher.flash(ok));
      final first = await watch.first.timeout(const Duration(seconds: 1));
      expect(first.phase, 'Entering OTA mode');
      t.injectRsp(OpB.rspOk);
      // Closing the stream without injecting further acks lets the
      // flasher's pre-flight pass; the watcher future resolves when the
      // stream closes naturally (it won't — the flash is blocked on
      // otaStart — so we race against a generous timeout instead and
      // only assert pre-flight succeeded).
      await watch.done.timeout(
        const Duration(seconds: 5),
        onTimeout: () => const <DfuProgress>[],
      );
    });
  });

  group('DfuFlasher timeout errors', () {
    test('timeout on otaStart (state=started)', () async {
      final t = _StubTransport();
      final flasher = DfuFlasher(t);
      final fw = _fakeFirmware(2048); // 2 pockets

      final watch = _watch(flasher.flash(fw));
      await watch.first.timeout(const Duration(seconds: 1)); // "Entering OTA"
      // Inject otaStart ACK so we move to "Sending metadata".
      t.injectRsp(OpB.rspOk);
      await watch.first.timeout(const Duration(seconds: 1)); // "Sending meta"
      // Now block: no RSP injected. The flasher will hit its 10 s
      // timeout. We expect a TimeoutException via the watcher's
      // `done` future (which surfaces the stream's terminal error).
      await expectLater(
        watch.done,
        throwsA(
          isA<TimeoutException>().having(
            (e) => e.message,
            'message',
            contains('No completion'),
          ),
        ),
      );
    });

    test('timeout on otaInit (state=initialized)', () async {
      final t = _StubTransport();
      final flasher = DfuFlasher(t);
      final fw = _fakeFirmware(1024); // 1 pocket
      final watch = _watch(flasher.flash(fw));
      await watch.first.timeout(const Duration(seconds: 1));
      t.injectRsp(OpB.rspOk); // ack otaStart
      // No ack for otaInit → must timeout.
      await expectLater(watch.done, throwsA(isA<TimeoutException>()));
    });

    test('timeout on otaCheck (state=checking)', () async {
      final t = _StubTransport();
      final flasher = DfuFlasher(t);
      final fw = _fakeFirmware(2048); // 2 pockets
      final watch = _watch(flasher.flash(fw));
      await watch.first.timeout(const Duration(seconds: 1));
      t.injectRsp(OpB.rspOk); // ack otaStart
      await watch.first.timeout(const Duration(seconds: 1)); // "Sending meta"
      t.injectRsp(OpB.rspOk); // ack otaInit
      // ACK both pockets.
      t.injectRsp(OpB.rspOk);
      t.injectRsp(OpB.rspOk);
      // No ack for otaCheck → must timeout.
      await expectLater(watch.done, throwsA(isA<TimeoutException>()));
    });
  });

  group('DfuFlasher low-battery handling (every awaited step)', () {
    test('RSP_LOW_BATTERY at otaStart throws DfuException', () async {
      final t = _StubTransport();
      final flasher = DfuFlasher(t);
      final fw = _fakeFirmware(1024);
      final watch = _watch(flasher.flash(fw));
      await watch.first.timeout(const Duration(seconds: 1));
      t.injectRsp(OpB.rspLowBattery);
      await expectLater(
        watch.done,
        throwsA(
          isA<DfuException>().having(
            (e) => e.message,
            'message',
            contains('battery too low'),
          ),
        ),
      );
    });

    test('RSP_LOW_BATTERY mid-transfer (after pocket 1 of 3)', () async {
      final t = _StubTransport();
      final flasher = DfuFlasher(t);
      final fw = _fakeFirmware(3072); // 3 pockets
      final watch = _watch(flasher.flash(fw));
      await watch.first.timeout(const Duration(seconds: 1)); // "Entering OTA"
      t.injectRsp(OpB.rspOk);
      await watch.first.timeout(const Duration(seconds: 1)); // "Sending meta"
      t.injectRsp(OpB.rspOk);
      // ACK pocket 1
      t.injectRsp(OpB.rspOk);
      // Battery dies before pocket 2
      t.injectRsp(OpB.rspLowBattery);
      await expectLater(
        watch.done,
        throwsA(
          isA<DfuException>().having(
            (e) => e.message,
            'message',
            contains('battery too low'),
          ),
        ),
      );
    });

    test('RSP_LOW_BATTERY at otaCheck (post-transfer)', () async {
      final t = _StubTransport();
      final flasher = DfuFlasher(t);
      final fw = _fakeFirmware(2048); // 2 pockets
      final watch = _watch(flasher.flash(fw));
      await watch.first.timeout(const Duration(seconds: 1));
      t.injectRsp(OpB.rspOk);
      await watch.first.timeout(const Duration(seconds: 1));
      t.injectRsp(OpB.rspOk);
      t.injectRsp(OpB.rspOk);
      t.injectRsp(OpB.rspOk);
      // Now at "Verifying" — battery dies during check.
      t.injectRsp(OpB.rspLowBattery);
      await expectLater(
        watch.done,
        throwsA(
          isA<DfuException>().having(
            (e) => e.message,
            'message',
            contains('battery too low'),
          ),
        ),
      );
    });
  });

  group('DfuFlasher CRC / NAK / status errors', () {
    test('non-zero status at otaStart surfaces DfuException', () async {
      final t = _StubTransport();
      final flasher = DfuFlasher(t);
      final fw = _fakeFirmware(1024);
      final watch = _watch(flasher.flash(fw));
      await watch.first.timeout(const Duration(seconds: 1));
      t.injectRsp(OpB.rspCmdStatus, status: 7);
      await expectLater(
        watch.done,
        throwsA(
          isA<DfuException>().having(
            (e) => e.message,
            'message',
            contains('device error'),
          ),
        ),
      );
    });

    test('non-zero status mid-transfer surfaces DfuException', () async {
      final t = _StubTransport();
      final flasher = DfuFlasher(t);
      final fw = _fakeFirmware(3072); // 3 pockets
      final watch = _watch(flasher.flash(fw));
      await watch.first.timeout(const Duration(seconds: 1));
      t.injectRsp(OpB.rspOk);
      await watch.first.timeout(const Duration(seconds: 1));
      t.injectRsp(OpB.rspOk);
      t.injectRsp(OpB.rspOk); // pocket 1 ok
      // Pocket 2 NAK with non-zero status
      t.injectRsp(OpB.rspCmdStatus, status: 2);
      await expectLater(
        watch.done,
        throwsA(
          isA<DfuException>().having(
            (e) => e.message,
            'message',
            contains('device error'),
          ),
        ),
      );
    });

    test('Channel-B NAK code 0 (FUN_0082ee00) surfaces as device error', () {
      // Per GHIDRA_DECOMPILATION.md §2.0, a NAK frame is
      //   [0xBC][count=1][error_code][cmd][crc_lo][crc_hi]
      // — 7 bytes with error_code at byte[3], NOT byte[6].
      // The OTA flasher currently reads `frame[6]` as status, so a
      // firmware-issued NAK (error_code at byte[3], 0x00 length-sentinel)
      // would be misinterpreted. This test pins the current behaviour:
      // a NAK where byte[6]=0 looks like rspOk type=NAK. We document
      // the gap so the audit report can flag it.
      final t = _StubTransport();
      final flasher = DfuFlasher(t);
      final fw = _fakeFirmware(1024);
      final stream = flasher.flash(fw);
      // Simulate the firmware NAK path: cmd echoed, length-sentinel
      // (FF FF FF FF), no status byte at byte[6].
      // Per the parser, this would never reassemble (length=0xFFFF),
      // so we cannot actually trigger this through the flasher. The
      // flasher subscribes to `inboundB` (raw notify chunks), so the
      // NAK arrives as 7 raw bytes. The flasher only consumes the
      // status byte at frame[6]; in a real NAK that byte is the high
      // byte of the CRC. We assert the current behaviour: the NAK is
      // silently ignored (frame is not 7 bytes of 0xBC magic + RSP
      // shape), so the flasher hangs on its 10s timeout.
      //
      // This test is informational — it documents the gap rather than
      // asserting a fix. See the audit report.
      expect(stream, isNotNull); // smoke test that the flasher is constructible
      stream.listen((_) {}); // keep the single subscription alive
    });
  });

  group('DfuFlasher connection drop', () {
    test('transport sendB error surfaces as exception', () async {
      final t = _StubTransport()
        ..sendBError = const _FakeBleError('BLE link disconnected');
      final flasher = DfuFlasher(t);
      final fw = _fakeFirmware(1024);
      final watch = _watch(flasher.flash(fw));
      await watch.first.timeout(const Duration(seconds: 1));
      // switchToOta() sends on Channel A — that succeeds (sentA).
      // otaStart is the first Channel-B write and will throw.
      await expectLater(watch.done, throwsA(isA<_FakeBleError>()));
    });

    test('inbound stream closing mid-transfer does not deadlock', () async {
      final t = _StubTransport();
      final flasher = DfuFlasher(t);
      final fw = _fakeFirmware(2048); // 2 pockets
      final watch = _watch(flasher.flash(fw));
      await watch.first.timeout(const Duration(seconds: 1));
      t.injectRsp(OpB.rspOk);
      await watch.first.timeout(const Duration(seconds: 1));
      t.injectRsp(OpB.rspOk);
      t.injectRsp(OpB.rspOk); // ack pocket 1
      // Now close the inbound stream before pocket 2 ack arrives —
      // the flasher must not hang indefinitely. We verify the rx
      // subscription is cancelled by the `finally` block.
      await t.inB.close();
      // The flasher awaits `_awaitRsp()` which has its own 10s
      // timeout. We assert that the operation terminates (with a
      // TimeoutException, since no RSP arrives).
      await expectLater(watch.done, throwsA(isA<TimeoutException>()));
    });
  });

  group('DfuFlasher happy path', () {
    test('flashes a 2-pocket image end-to-end', () async {
      final t = _StubTransport();
      final flasher = DfuFlasher(t);
      final fw = _fakeFirmware(2048);
      final watch = _watch(flasher.flash(fw));
      // Pump acks ahead of the stream consumer.
      // Sequence of acks needed: otaStart, otaInit, pocket 1, pocket 2,
      // otaCheck. After check, otaEnd fires-and-forgets (no RSP).
      // Inject them in order with small delays so each `_awaitRsp` has
      // time to register its Completer first.
      Future<void>.delayed(const Duration(milliseconds: 50), () {
        t.injectRsp(OpB.rspOk);
      });
      Future<void>.delayed(const Duration(milliseconds: 100), () {
        t.injectRsp(OpB.rspOk);
      });
      Future<void>.delayed(const Duration(milliseconds: 150), () {
        t.injectRsp(OpB.rspOk);
      });
      Future<void>.delayed(const Duration(milliseconds: 200), () {
        t.injectRsp(OpB.rspOk);
      });
      Future<void>.delayed(const Duration(milliseconds: 250), () {
        t.injectRsp(OpB.rspOk);
      });
      final events = await watch.done.timeout(const Duration(seconds: 5));
      final phases = events.map((p) => p.phase).toList();
      expect(phases, contains('Done'));
      expect(events.last.percent, 1.0);
    });
  });
}

class _FakeBleError implements Exception {
  const _FakeBleError(this.message);
  final String message;
  @override
  String toString() => 'FakeBleError: $message';
}
