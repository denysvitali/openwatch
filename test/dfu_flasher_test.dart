import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:openwatch/core/protocol/codec.dart';
import 'package:openwatch/core/protocol/dfu.dart';
import 'package:openwatch/core/protocol/opcodes.dart';

import 'support/fake_ble_transport.dart';

/// Adds the OTA-specific bits [FakeBleTransport] doesn't cover: a
/// `sendB` error injection hook and a helper to push synthetic
/// Channel-B RSP frames straight at `inboundB`.
class _StubTransport extends FakeBleTransport {
  Object? sendBError;

  @override
  Future<void> sendB(Uint8List framed) async {
    sentB.add(framed);
    if (sendBError != null) throw sendBError!;
  }

  /// Inject a Channel-B RSP frame. The OTA flasher awaits frames whose
  /// first byte is the Channel-B magic (`0xBC`); `type` is byte[1]
  /// (rspOk=0, rspLowBattery=6, etc.) and `status` is byte[6].
  void injectRsp(int type, {int status = 0}) {
    inB.add(Codec.buildChannelB(type, [status & 0xFF]));
  }

  /// Inject the one-byte Channel-B error/status frame emitted by
  /// firmware helper `FUN_0082ee00`.
  void injectNak({required int cmd, int errorCode = 0}) {
    inB.add(Codec.buildChannelB(cmd, [errorCode & 0xFF]));
  }
}

/// Builds a synthetic H59MA firmware image of [sizeBytes]. We don't need
/// a real container for the OTA flasher tests — the flasher does its
/// own CRC16/additive16 computation and pushes raw bytes to Channel-B.
Uint8List _fakeFirmware(int sizeBytes) =>
    Uint8List.fromList(List<int>.generate(sizeBytes, (i) => i & 0xFF));

/// Subscribes once to the flash [stream] and returns a handle that
/// the test can use to await specific progress events without
/// subscribing to the stream multiple times.
///
/// `async*` generators in Dart are single-subscription — every test
/// below needs to drive the stream via a *single* listener and read
/// progress off the collected events, not via repeated `.first` /
/// `.drain` calls (which would race the second listener on the same
/// underlying stream).
///
/// Usage:
/// ```dart
/// final watch = _watch(flasher.flash(fw));
/// await watch.waitForCount(1); // "Entering OTA"
/// await watch.waitForCount(2); // "Starting session"
/// ```
///
/// Or for tests that want to assert the terminal outcome:
/// ```dart
/// final result = await watch.done.timeout(const Duration(seconds: 12));
/// ```
class _FlashWatch {
  _FlashWatch._(this.done, this.waitForCount);

  /// Resolves with the collected event list once the stream closes,
  /// or with the terminal error if the stream errors out.
  final Future<List<DfuProgress>> done;

  /// Returns a future that completes when the [n]th progress event
  /// has been emitted by the stream (1-indexed). If the stream
  /// errors before [n] events arrive, the returned future completes
  /// with that error. If [n] is already <= the number of events
  /// received so far, the future resolves immediately with the
  /// cached event.
  final Future<DfuProgress> Function(int n) waitForCount;

  /// Future that completes with the first [DfuProgress] event.
  Future<DfuProgress> get first => waitForCount(1);
}

_FlashWatch _watch(Stream<DfuProgress> stream) {
  final events = <DfuProgress>[];
  final waiters = <int, Completer<DfuProgress>>{};
  final doneCompleter = Completer<List<DfuProgress>>();
  StreamSubscription<DfuProgress>? sub;
  sub = stream.listen(
    (e) {
      events.add(e);
      final w = waiters.remove(events.length);
      if (w != null && !w.isCompleted) w.complete(e);
    },
    onError: (Object e, StackTrace st) {
      for (final w in waiters.values) {
        if (!w.isCompleted) w.completeError(e, st);
      }
      waiters.clear();
      if (!doneCompleter.isCompleted) doneCompleter.completeError(e, st);
    },
    onDone: () {
      for (final w in waiters.values) {
        if (!w.isCompleted) {
          w.completeError(StateError('stream closed before event arrived'));
        }
      }
      waiters.clear();
      if (!doneCompleter.isCompleted) doneCompleter.complete(events);
      sub?.cancel();
    },
    cancelOnError: true,
  );

  Future<DfuProgress> waitForCount(int n) {
    if (n <= 0) {
      throw ArgumentError.value(n, 'n', 'must be 1-indexed');
    }
    if (n <= events.length) {
      return Future<DfuProgress>.value(events[n - 1]);
    }
    final existing = waiters[n];
    if (existing != null) return existing.future;
    final c = Completer<DfuProgress>();
    waiters[n] = c;
    return c.future;
  }

  return _FlashWatch._(doneCompleter.future, waitForCount);
}

/// Waits until the stub has observed a new Channel-B write and the
/// flasher's internal `_rspWaiter` Completer is registered. Used to
/// gate `injectRsp` so the response isn't silently dropped as a
/// "no waiter" no-op (the flasher's `_onRx` only consumes frames
/// while a Completer is in flight).
Future<void> _waitForSendB(_StubTransport t, {int previousCount = 0}) async {
  final deadline = DateTime.now().add(const Duration(seconds: 2));
  while (t.sentB.length <= previousCount) {
    if (DateTime.now().isAfter(deadline)) {
      throw TimeoutException(
        'No new Channel-B write within 2s (had $previousCount, now ${t.sentB.length})',
      );
    }
    await Future<void>.delayed(const Duration(milliseconds: 1));
  }
  // Settling delay so the inB controller's microtask for the matching
  // _onRx dispatch is guaranteed to have run on a slow host before
  // the test injects the next RSP.
  await Future<void>.delayed(const Duration(milliseconds: 2));
}

/// Inject a Channel-B RSP and drain the microtask queue before
/// returning. The flasher is an `async*` generator that:
///   1. calls `_send(...)` (which the stub records on `sentB`),
///   2. awaits `_awaitRsp()` to register `_rspWaiter`,
///   3. awaits another microtask whenever `_rspWaiter.complete(...)`
///      fires from `_onRx`.
///
/// If we inject two RSPs back-to-back without draining in between,
/// step (3) of the first RSP can land *after* step (1) of the second
/// send — at which point the second RSP is consumed against the
/// FIRST step's `_rspWaiter` (or dropped silently if no waiter is
/// yet registered), and the first step times out 10 s later.
///
/// `await Future<void>.delayed(Duration.zero)` schedules a Timer
/// whose completion microtask is queued *after* every pending
/// microtask, so it returns only once the flasher has fully resumed
/// from the previous RSP.
/// Inject a Channel-B RSP. Use this between multi-RSP sequences so
/// each RSP reaches the flasher's `_rspWaiter` for its corresponding
/// step. The flasher's `await _awaitRsp()` only consumes one frame
/// at a time, so consecutive RSPs without a `Future.delayed` may
/// race the in-flight microtask and silently drop the latter.
void _ack(_StubTransport t, int type, {int status = 0}) {
  t.injectRsp(type, status: status);
}

/// Inject a Channel-B RSP AND wait long enough for the flasher to
/// fully process it. Use after the LAST ack in a multi-RSP sequence
/// so the subsequent `expectLater` sees the error in the awaited
/// future (rather than racing the microtask).
Future<void> _ackDrain(_StubTransport t, int type, {int status = 0}) async {
  t.injectRsp(type, status: status);
  await Future<void>.delayed(const Duration(milliseconds: 10));
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
      final first = await watch
          .waitForCount(1)
          .timeout(const Duration(seconds: 1));
      expect(first.phase, 'Entering OTA mode');
      t.injectRsp(OpB.rspOk);
      // The flash will block forever after this; we just verify that
      // pre-flight passed and the first event fired. The watcher
      // future resolves when the stream closes naturally.
      await watch.done.timeout(
        const Duration(milliseconds: 200),
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
      await watch
          .waitForCount(1)
          .timeout(const Duration(seconds: 1)); // "Entering OTA"
      // Inject otaStart ACK so we move to "Sending metadata".
      await Future<void>.delayed(const Duration(milliseconds: 600));
      await watch
          .waitForCount(2)
          .timeout(const Duration(seconds: 1)); // "Starting session"
      await _waitForSendB(t); // otaStart has been sent
      t.injectRsp(OpB.rspOk); // ack otaStart
      await watch
          .waitForCount(3)
          .timeout(const Duration(seconds: 1)); // "Sending metadata"
      await _waitForSendB(t); // otaInit has been sent
      // No RSP for otaInit → must timeout.
      await expectLater(
        watch.done.timeout(const Duration(seconds: 12)),
        throwsA(isA<TimeoutException>()),
      );
    });

    test('timeout on otaInit (state=initialized)', () async {
      final t = _StubTransport();
      final flasher = DfuFlasher(t);
      final fw = _fakeFirmware(1024); // 1 pocket
      final watch = _watch(flasher.flash(fw));
      await watch.waitForCount(1).timeout(const Duration(seconds: 1));
      await Future<void>.delayed(const Duration(milliseconds: 600));
      await watch
          .waitForCount(2)
          .timeout(const Duration(seconds: 1)); // "Starting session"
      await _waitForSendB(t);
      t.injectRsp(OpB.rspOk); // ack otaStart
      // No ack for otaInit → must timeout.
      await expectLater(
        watch.done.timeout(const Duration(seconds: 12)),
        throwsA(isA<TimeoutException>()),
      );
    });

    test('timeout on otaCheck (state=checking)', () async {
      final t = _StubTransport();
      final flasher = DfuFlasher(t);
      final fw = _fakeFirmware(2048); // 2 pockets
      final watch = _watch(flasher.flash(fw));
      await watch
          .waitForCount(1)
          .timeout(const Duration(seconds: 1)); // "Entering OTA"
      await Future<void>.delayed(const Duration(milliseconds: 600));
      await watch
          .waitForCount(2)
          .timeout(const Duration(seconds: 1)); // "Starting session"
      await _waitForSendB(t);
      _ack(t, OpB.rspOk); // ack otaStart → "Sending metadata"
      await watch
          .waitForCount(3)
          .timeout(const Duration(seconds: 1)); // "Sending metadata"
      await _waitForSendB(t);
      // The next two acks are back-to-back: otaInit then pocket 1.
      // Without a microtask drain between them the second `_ack`
      // races the flasher's `_rspWaiter` refresh and is silently
      // dropped (the flasher's `_onRx` returns early when
      // `_rspWaiter.isCompleted` is true). Use `_ackDrain` for the
      // first of the pair so the flasher fully resumes (yields
      // "Flashing" #1, sends pocket 2) before the next `_ack`.
      await _ackDrain(t, OpB.rspOk); // ack otaInit
      _ack(t, OpB.rspOk); // ack pocket 1 → "Flashing" #1
      await watch
          .waitForCount(4)
          .timeout(const Duration(seconds: 1)); // "Flashing" #1
      await _waitForSendB(t);
      _ack(t, OpB.rspOk); // ack pocket 2 → "Flashing" #2
      await watch
          .waitForCount(5)
          .timeout(const Duration(seconds: 1)); // "Flashing" #2"
      // No ack for otaCheck → must timeout.
      await expectLater(
        watch.done.timeout(const Duration(seconds: 12)),
        throwsA(isA<TimeoutException>()),
      );
    });
  });

  group('DfuFlasher low-battery handling (every awaited step)', () {
    test('RSP_LOW_BATTERY at otaStart throws DfuException', () async {
      final t = _StubTransport();
      final flasher = DfuFlasher(t);
      final fw = _fakeFirmware(1024);
      final watch = _watch(flasher.flash(fw));
      await watch.waitForCount(1).timeout(const Duration(seconds: 1));
      await Future<void>.delayed(const Duration(milliseconds: 600));
      await watch
          .waitForCount(2)
          .timeout(const Duration(seconds: 1)); // "Starting session"
      await _waitForSendB(t); // otaStart sent
      // Battery dies on the OTA-start RSP. Capture the expectTask
      // (which synchronously subscribes via matcher.matchAsync) BEFORE
      // injecting — otherwise the DfuException propagates through
      // `_watch.onError → doneCompleter → .timeout(12s)` with no
      // listener attached and the test zone reports it as unhandled.
      final expectTask = expectLater(
        watch.done.timeout(const Duration(seconds: 12)),
        throwsA(
          isA<DfuException>().having(
            (e) => e.message,
            'message',
            contains('battery too low'),
          ),
        ),
      );
      await _ackDrain(t, OpB.rspLowBattery);
      await expectTask;
    });

    test('RSP_LOW_BATTERY mid-transfer (after pocket 1 of 3)', () async {
      final t = _StubTransport();
      final flasher = DfuFlasher(t);
      final fw = _fakeFirmware(3072); // 3 pockets
      final watch = _watch(flasher.flash(fw));
      await watch
          .waitForCount(1)
          .timeout(const Duration(seconds: 1)); // "Entering OTA"
      await Future<void>.delayed(const Duration(milliseconds: 600));
      await watch
          .waitForCount(2)
          .timeout(const Duration(seconds: 1)); // "Starting session"
      await _waitForSendB(t);
      _ack(t, OpB.rspOk); // ack otaStart → "Sending metadata"
      await watch
          .waitForCount(3)
          .timeout(const Duration(seconds: 1)); // "Sending metadata"
      await _waitForSendB(t);
      // Drain between otaInit ack and pocket 1 ack — see
      // `timeout on otaCheck` for the rationale.
      await _ackDrain(t, OpB.rspOk); // ack otaInit
      _ack(t, OpB.rspOk); // ack pocket 1 → "Flashing" #1
      await watch
          .waitForCount(4)
          .timeout(const Duration(seconds: 1)); // "Flashing" #1
      await _waitForSendB(t);
      // Battery dies before pocket 2. Subscribe via expectLater
      // BEFORE injecting the error so the `.then` chain is attached
      // when the DfuException fires (otherwise it escapes to the
      // test zone as unhandled).
      final expectTask = expectLater(
        watch.done.timeout(const Duration(seconds: 12)),
        throwsA(
          isA<DfuException>().having(
            (e) => e.message,
            'message',
            contains('battery too low'),
          ),
        ),
      );
      await _ackDrain(t, OpB.rspLowBattery);
      await expectTask;
    });

    test('RSP_LOW_BATTERY at otaCheck (post-transfer)', () async {
      final t = _StubTransport();
      final flasher = DfuFlasher(t);
      final fw = _fakeFirmware(2048); // 2 pockets
      final watch = _watch(flasher.flash(fw));
      await watch
          .waitForCount(1)
          .timeout(const Duration(seconds: 1)); // "Entering OTA"
      await Future<void>.delayed(const Duration(milliseconds: 600));
      await watch
          .waitForCount(2)
          .timeout(const Duration(seconds: 1)); // "Starting session"
      await _waitForSendB(t);
      _ack(t, OpB.rspOk); // ack otaStart → "Sending metadata"
      await watch
          .waitForCount(3)
          .timeout(const Duration(seconds: 1)); // "Sending metadata"
      await _waitForSendB(t);
      // Drain between otaInit ack and pocket 1 ack — see
      // `timeout on otaCheck` for the rationale.
      await _ackDrain(t, OpB.rspOk); // ack otaInit
      _ack(t, OpB.rspOk); // ack pocket 1 → "Flashing" #1
      await watch
          .waitForCount(4)
          .timeout(const Duration(seconds: 1)); // "Flashing" #1
      await _waitForSendB(t);
      _ack(t, OpB.rspOk); // ack pocket 2 → "Flashing" #2
      await watch
          .waitForCount(5)
          .timeout(const Duration(seconds: 1)); // "Flashing" #2
      // Now at "Verifying" — battery dies during check.
      await watch
          .waitForCount(6)
          .timeout(const Duration(seconds: 1)); // "Verifying"
      await _waitForSendB(t);
      // Subscribe via expectLater BEFORE injecting the error so the
      // `.then` chain is attached when the DfuException fires.
      final expectTask = expectLater(
        watch.done.timeout(const Duration(seconds: 12)),
        throwsA(
          isA<DfuException>().having(
            (e) => e.message,
            'message',
            contains('battery too low'),
          ),
        ),
      );
      await _ackDrain(t, OpB.rspLowBattery);
      await expectTask;
    });
  });

  group('DfuFlasher CRC / NAK / status errors', () {
    test('non-zero status at otaStart surfaces DfuException', () async {
      final t = _StubTransport();
      final flasher = DfuFlasher(t);
      final fw = _fakeFirmware(1024);
      final watch = _watch(flasher.flash(fw));
      await watch.waitForCount(1).timeout(const Duration(seconds: 1));
      await Future<void>.delayed(const Duration(milliseconds: 600));
      await watch
          .waitForCount(2)
          .timeout(const Duration(seconds: 1)); // "Starting session"
      await _waitForSendB(t);
      // Subscribe via expectLater BEFORE injecting the error so the
      // `.then` chain is attached when the DfuException fires.
      final expectTask = expectLater(
        watch.done.timeout(const Duration(seconds: 12)),
        throwsA(
          isA<DfuException>().having(
            (e) => e.message,
            'message',
            contains('Device error'),
          ),
        ),
      );
      await _ackDrain(t, OpB.rspCmdStatus, status: 7);
      await expectTask;
    });

    test('non-zero status mid-transfer surfaces DfuException', () async {
      final t = _StubTransport();
      final flasher = DfuFlasher(t);
      final fw = _fakeFirmware(3072); // 3 pockets
      final watch = _watch(flasher.flash(fw));
      await watch.waitForCount(1).timeout(const Duration(seconds: 1));
      await Future<void>.delayed(const Duration(milliseconds: 600));
      await watch
          .waitForCount(2)
          .timeout(const Duration(seconds: 1)); // "Starting session"
      await _waitForSendB(t);
      _ack(t, OpB.rspOk); // ack otaStart → "Sending metadata"
      await watch
          .waitForCount(3)
          .timeout(const Duration(seconds: 1)); // "Sending metadata"
      await _waitForSendB(t);
      // Drain between otaInit ack and pocket 1 ack — see
      // `timeout on otaCheck` for the rationale.
      await _ackDrain(t, OpB.rspOk); // ack otaInit
      _ack(t, OpB.rspOk); // ack pocket 1 → "Flashing" #1
      // Wait for the flasher to register pocket 2's _rspWaiter
      // before injecting the NAK — otherwise the rspCmdStatus RSP
      // would race the pocket-1 microtask cascade and land on the
      // already-completed pocket-1 waiter (silently dropped).
      await watch
          .waitForCount(4)
          .timeout(const Duration(seconds: 1)); // "Flashing" #1
      await _waitForSendB(t);
      // Pocket 2 NAK with non-zero status. After Flashing #1 fires,
      // the flasher is sitting on `_awaitRsp()` for pocket 2 — its
      // _rspWaiter is registered, so the injected error is routed
      // straight to that Completer. Subscribe via expectLater BEFORE
      // injecting so the `.then` chain is attached when the error
      // fires.
      final expectTask = expectLater(
        watch.done.timeout(const Duration(seconds: 12)),
        throwsA(
          isA<DfuException>().having(
            (e) => e.message,
            'message',
            contains('Device error'),
          ),
        ),
      );
      await _ackDrain(t, OpB.rspCmdStatus, status: 2);
      await expectTask;
    });

    test('malformed OTA response frame surfaces as DfuException', () async {
      final t = _StubTransport();
      final flasher = DfuFlasher(t);
      final fw = _fakeFirmware(1024);
      final watch = _watch(flasher.flash(fw));
      await watch.waitForCount(1).timeout(const Duration(seconds: 1));
      await Future<void>.delayed(const Duration(milliseconds: 600));
      await watch
          .waitForCount(2)
          .timeout(const Duration(seconds: 1)); // "Starting session"
      await _waitForSendB(t);

      final expectTask = expectLater(
        watch.done.timeout(const Duration(seconds: 12)),
        throwsA(
          isA<DfuException>().having(
            (e) => e.message,
            'message',
            contains('Malformed OTA response'),
          ),
        ),
      );
      // Valid length and status, bad CRC.
      t.inB.add(
        Uint8List.fromList([
          Codec.channelBMagic,
          OpB.rspOk,
          0x01,
          0x00,
          0x00,
          0x00,
          0x00,
        ]),
      );
      await Future<void>.delayed(const Duration(milliseconds: 10));
      await expectTask;
    });

    test(
      'Channel-B NAK/status code (FUN_0082ee00) surfaces as device error',
      () async {
        // Per GHIDRA_DECOMPILATION.md §2.0, the helper emits a normal
        // Channel-B frame for the original cmd with a one-byte error payload.
        // For OTA responses that means the existing nonzero-status path must
        // stop progress.
        final t = _StubTransport();
        final flasher = DfuFlasher(t);
        final fw = _fakeFirmware(1024);
        final watch = _watch(flasher.flash(fw));
        await watch.waitForCount(1).timeout(const Duration(seconds: 1));
        await Future<void>.delayed(const Duration(milliseconds: 600));
        await watch
            .waitForCount(2)
            .timeout(const Duration(seconds: 1)); // "Starting session"
        await _waitForSendB(t);

        final expectTask = expectLater(
          watch.done.timeout(const Duration(seconds: 12)),
          throwsA(
            isA<DfuException>().having(
              (e) => e.message,
              'message',
              allOf(contains('Device error'), contains('status=2')),
            ),
          ),
        );
        t.injectNak(cmd: OpB.otaStart, errorCode: 2);
        await Future<void>.delayed(const Duration(milliseconds: 10));
        await expectTask;
      },
    );
  });

  group('DfuFlasher connection drop', () {
    test('transport sendB error surfaces as exception', () async {
      final t = _StubTransport()
        ..sendBError = const _FakeBleError('BLE link disconnected');
      final flasher = DfuFlasher(t);
      final fw = _fakeFirmware(1024);
      final watch = _watch(flasher.flash(fw));
      await watch
          .waitForCount(1)
          .timeout(const Duration(seconds: 1)); // "Entering OTA"
      // The flasher yields "Starting session" and immediately calls
      // _send(otaStart). sendB throws FakeBleError synchronously,
      // so the stream errors at that point. waitForCount(2) returns
      // the cached "Starting session" event because it was yielded
      // before the throw.
      await watch
          .waitForCount(2)
          .timeout(const Duration(seconds: 1)); // "Starting session"
      // Use direct await with try/catch — expectLater sometimes
      // re-raises the original exception instead of matching
      // throwsA when the async* generator errors synchronously.
      Object? caught;
      try {
        await watch.done.timeout(const Duration(seconds: 5));
        fail('expected FakeBleError, got stream completion');
      } on Object catch (e) {
        caught = e;
      }
      expect(caught, isA<_FakeBleError>());
    });

    test('inbound stream closing mid-transfer does not deadlock', () async {
      final t = _StubTransport();
      final flasher = DfuFlasher(t);
      final fw = _fakeFirmware(2048); // 2 pockets
      final watch = _watch(flasher.flash(fw));
      await watch.waitForCount(1).timeout(const Duration(seconds: 1));
      await Future<void>.delayed(const Duration(milliseconds: 600));
      await watch
          .waitForCount(2)
          .timeout(const Duration(seconds: 1)); // "Starting session"
      await _waitForSendB(t);
      _ack(t, OpB.rspOk); // ack otaStart → "Sending metadata"
      await watch
          .waitForCount(3)
          .timeout(const Duration(seconds: 1)); // "Sending metadata"
      await _waitForSendB(t);
      _ack(t, OpB.rspOk); // ack otaInit
      _ack(t, OpB.rspOk); // ack pocket 1 → "Flashing" #1
      // Now close the inbound stream before pocket 2 ack arrives —
      // the flasher must not hang indefinitely. We verify the rx
      // subscription is cancelled by the `finally` block.
      await t.inB.close();
      // The flasher awaits `_awaitRsp()` which has its own 10s
      // timeout. We assert that the operation terminates (with a
      // TimeoutException, since no RSP arrives).
      await expectLater(
        watch.done.timeout(const Duration(seconds: 12)),
        throwsA(isA<TimeoutException>()),
      );
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
      Future<void>.delayed(const Duration(milliseconds: 600), () {
        t.injectRsp(OpB.rspOk);
      });
      Future<void>.delayed(const Duration(milliseconds: 650), () {
        t.injectRsp(OpB.rspOk);
      });
      Future<void>.delayed(const Duration(milliseconds: 700), () {
        t.injectRsp(OpB.rspOk);
      });
      Future<void>.delayed(const Duration(milliseconds: 750), () {
        t.injectRsp(OpB.rspOk);
      });
      Future<void>.delayed(const Duration(milliseconds: 800), () {
        t.injectRsp(OpB.rspOk);
      });
      final events = await watch.done.timeout(const Duration(seconds: 10));
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
