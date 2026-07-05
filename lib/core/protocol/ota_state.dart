import 'dart:typed_data';

import '../services/app_log.dart';
import 'codec.dart';
import 'opcodes.dart';

final _log = AppLog.instance;

/// OTA/DFU state machine driven by Channel-B command ids.
///
/// Mirrors `ota_dfu_state_machine` (`0x0082fe52`) and the OTA command workers
/// around `0x0082f1a4..0x0082f410` from the H59MA v14 firmware. The state table
/// the firmware walks lives at `DAT_00830120`/`DAT_00830124`.
///
/// On the wire the OTA flow runs over Channel-B:
///
/// ```
///   start    (0x01)   — enter DFU mode
///   init     (0x02)   — [01 or 04, size32LE, crc16LE, checksum16LE]
///   data     (0x03)   — [pocketIdx u16 LE, payload ...]
///   check    (0x04)   — verify written byte count
///   end      (0x05)   — exit / reboot
/// ```
///
/// State transitions and required fields are validated before each send so a
/// stale `init` after `data` cannot silently reset the device.
enum OtaPhase { idle, started, initialized, data, checking, complete, error }

/// Per-session OTA metadata.
class OtaSession {
  OtaSession({required this.image, required this.sizeBytes});
  final Uint8List image;
  final int sizeBytes;

  /// CRC-16/MODBUS of the image body. Mirrors the firmware's `crc16` over
  /// the whole image (FUN_0082f114).
  int crc16 = 0;

  /// 16-bit additive checksum. Used as a second integrity check.
  int additive = 0;

  /// 32-bit local signature/header value read from the container metadata.
  /// Firmware packet 1 separately checks the container header's first word
  /// against `0x81bdc3e5` before staging bytes after the 0x50-byte header.
  int signature = 0;

  /// Total pockets the firmware will receive (imageSize / 1024 rounded up).
  int pocketCount = 0;

  OtaPhase phase = OtaPhase.idle;
  int pocketsSent = 0;
  String? errorMessage;
}

/// Channel-B OTA driver. Pure state machine — emits events as transitions
/// happen so a flasher UI can render progress.
class OtaStateMachine {
  OtaStateMachine({required this.session});

  final OtaSession session;

  /// Local sanity check before OTA init. The firmware's hard check happens on
  /// data packet 1 against the container magic, so this only rejects obviously
  /// missing local metadata.
  bool checkSignature() {
    if (session.signature == 0) {
      _log.warn('ota', 'signature missing; device will likely reject');
      return false;
    }
    return true;
  }

  /// Computes CRC16 + additive checksum. Called by the flasher before `init`.
  void computeChecksums() {
    session.crc16 = Codec.crc16(session.image);
    session.additive = Codec.additiveChecksum(session.image, maskBits: 16);
  }

  /// Transitions to a new phase after validating the precondition. Returns
  /// `false` (and records an error) when the transition is illegal.
  bool transition(OtaPhase next) {
    final allowed = _allowedTransitions[session.phase]!;
    if (!allowed.contains(next)) {
      final msg =
          'illegal transition ${session.phase.name} → ${next.name} '
          '(allowed: ${allowed.map((e) => e.name).join(", ")})';
      session.errorMessage = msg;
      session.phase = OtaPhase.error;
      _log.error('ota', msg);
      return false;
    }
    session.phase = next;
    return true;
  }

  /// Builds the next frame payload for the requested phase.
  Uint8List payloadFor(OtaPhase phase) {
    switch (phase) {
      case OtaPhase.started:
        return Uint8List(0); // empty payload sentinel
      case OtaPhase.initialized:
        return Uint8List.fromList([
          0x01,
          ...Codec.u32le(session.sizeBytes),
          ...Codec.u16le(session.crc16),
          ...Codec.u16le(session.additive),
        ]);
      case OtaPhase.data:
        // Caller fills payload with [pocketIdx, chunk] bytes; this helper
        // exists so the transition + payload shape stay in one place.
        throw StateError('payloadFor(data) is filled by the flasher');
      case OtaPhase.checking:
      case OtaPhase.complete:
      case OtaPhase.idle:
      case OtaPhase.error:
        return Uint8List(0);
    }
  }

  /// Validates an incoming RSP frame from the device. Mirrors the firmware's
  /// acceptance checks (rspOk = `0`, rspLowBattery = `6`, anything else is a
  /// hard error).
  bool acceptRsp({required int rspType, required int status}) {
    if (rspType < OpB.rspOk || rspType > OpB.rspLowBattery) {
      session.errorMessage =
          'unexpected response type: 0x${rspType.toRadixString(16)}';
      session.phase = OtaPhase.error;
      return false;
    }
    if (rspType == OpB.rspLowBattery) {
      session.errorMessage = 'battery too low';
      session.phase = OtaPhase.error;
      return false;
    }
    if (status != 0) {
      session.errorMessage =
          'device error: type=0x${rspType.toRadixString(16)} '
          'status=0x${status.toRadixString(16)}';
      session.phase = OtaPhase.error;
      return false;
    }
    return true;
  }

  static const Map<OtaPhase, Set<OtaPhase>> _allowedTransitions = {
    OtaPhase.idle: {OtaPhase.started, OtaPhase.error},
    OtaPhase.started: {OtaPhase.initialized, OtaPhase.error},
    OtaPhase.initialized: {OtaPhase.data, OtaPhase.error},
    OtaPhase.data: {OtaPhase.checking, OtaPhase.data, OtaPhase.error},
    OtaPhase.checking: {OtaPhase.complete, OtaPhase.error},
    OtaPhase.complete: {OtaPhase.error},
    OtaPhase.error: {},
  };
}
