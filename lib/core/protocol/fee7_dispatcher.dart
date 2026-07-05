import 'dart:async';
import 'dart:typed_data';

import '../ble/fee7_service.dart';
import '../services/app_log.dart';
import 'channel_a.dart';
import 'codec.dart';
import 'opcodes.dart';

final _log = AppLog.instance;

/// Opcode-aware decoder + dispatcher for the vendor `0xFEE7` 16-byte command
/// channel (H59MA v14 `FUN_0082c944`, see `GHIDRA_DECOMPILATION.md` §8).
///
/// Mirrors the shape of [ChannelADispatcher]: decode is a pure function over
/// a single 16-byte frame; consumers wire [bind] to a [Fee7Service] and
/// listen on the typed `on*` streams they care about. Frames whose opcode
/// the app does not specifically decode are still forwarded on [unknown] as
/// a [UnaryOpcode], matching the firmware's `FUN_0082bcba` fallthrough.
class Fee7Dispatcher {
  Fee7Dispatcher(this._service);

  final Fee7Service _service;

  /// Every broadcast controller created via [_ctrl]; closed by [dispose] so
  /// adding a new opcode stream never requires touching the teardown list.
  final List<StreamController<Object?>> _controllers = [];

  StreamController<T> _ctrl<T>() {
    final c = StreamController<T>.broadcast();
    _controllers.add(c);
    return c;
  }

  // Typed opcode streams.
  late final _spo2Hr = _ctrl<SpO2HrUpdate>();
  late final _capability = _ctrl<CapabilityBlock>();
  late final _bloodOxygen = _ctrl<BloodOxygenUpdate>();
  late final _hrv = _ctrl<HrvSetting>();
  late final _handshake = _ctrl<HandshakeResponse>();
  late final _battery = _ctrl<Fee7BatteryResponse>();
  late final _alert = _ctrl<AlertTrigger>();
  late final _findPhone = _ctrl<FindPhoneEvent>();
  late final _status = _ctrl<StatusResponse>();
  late final _mode = _ctrl<ModeControl>();
  late final _modeCont = _ctrl<ModeControlCont>();
  late final _long = _ctrl<LongResponse>();
  late final _memoryRead = _ctrl<MemoryReadChunk>();
  late final _ota = _ctrl<OtaTrigger>();
  late final _vibration = _ctrl<VibrationPattern>();
  late final _unary = _ctrl<UnaryOpcode>();
  late final _unknown = _ctrl<UnaryOpcode>();
  int _memoryReadSeq = 0;

  /// `0x36` SpO2/HR read or set; `pl[0]` selects read vs set.
  Stream<SpO2HrUpdate> get onSpO2Hr => _spo2Hr.stream;

  /// `0x3c` capability block — fixed bytes reported by the device.
  Stream<CapabilityBlock> get onCapabilityBlock => _capability.stream;

  /// `0x3e` SpO2 read or set.
  Stream<BloodOxygenUpdate> get onBloodOxygen => _bloodOxygen.stream;

  /// HRV setting (`0x39` on the 0xFEE7 service). Channel-A `0x39`
  /// is the HRV history reader on H59MA v14; keep this vendor-service
  /// shape separate until captures prove an equivalent Channel-A setting.
  Stream<HrvSetting> get onHrv => _hrv.stream;

  /// `0x48` 'H' handshake — 15-byte device-info payload.
  Stream<HandshakeResponse> get onHandshake => _handshake.stream;

  /// `0x03` direct battery response: percent + charging flag.
  Stream<Fee7BatteryResponse> get onBattery => _battery.stream;

  /// `0x50` 'P' alert trigger; payload[1..N] decoded.
  Stream<AlertTrigger> get onAlert => _alert.stream;

  /// `0x51` 'Q' find-phone event; `pl[1]==1` arms the pattern.
  Stream<FindPhoneEvent> get onFindPhone => _findPhone.stream;

  /// `0x61` 'a' status response: 32-bit live status snapshot.
  Stream<StatusResponse> get onStatus => _status.stream;

  /// `0x69` 'i' multi-step mode control (start).
  Stream<ModeControl> get onModeControl => _mode.stream;

  /// `0x6a` 'j' continuation of `0x69` mode control.
  Stream<ModeControlCont> get onModeControlCont => _modeCont.stream;

  /// `0xc1` one-shot health/status response.
  Stream<LongResponse> get onLongResponse => _long.stream;

  /// `0xc0` raw memory-read streamer chunks. The firmware's shared
  /// fragmented streamer carries no wire sequence byte, so [MemoryReadChunk.seq]
  /// is assigned by arrival order.
  Stream<MemoryReadChunk> get onMemoryReadChunk => _memoryRead.stream;

  /// `0xc3` OTA control; `pl[0]` selects DFU state action and `pl[1]==1`
  /// requests the BLE/service reset helper.
  Stream<OtaTrigger> get onOta => _ota.stream;

  /// `0xfe` vibration-pattern request (duration-derived).
  Stream<VibrationPattern> get onVibration => _vibration.stream;

  /// Catch-all unary opcodes that the firmware echoes/acks as the opcode
  /// alone: `0x90`, `0x91`, `0x92..0x96`, `0x9e`, `0x9f`, `0xa0`, `0xbf`,
  /// `0xc4`, `0xc5`, `0xc8`, `0xc9`, `0xcd`, `0xce`.
  Stream<UnaryOpcode> get onUnary => _unary.stream;

  /// Unrecognized opcodes (still surfaced as [UnaryOpcode] so observability
  /// tools can record them; mirrors `FUN_0082bcba` fallthrough).
  Stream<UnaryOpcode> get unknown => _unknown.stream;

  /// Bind to the [Fee7Service] inbound stream. Idempotent.
  StreamSubscription<Uint8List> bind() =>
      _service.inboundStream.listen(decode, onError: _onError);

  void _onError(Object e, StackTrace _) {
    _log.error('fee7', 'inbound error: $e');
  }

  /// Decode one 16-byte frame and fan it out to the right stream.
  ///
  /// Returns silently on frames that fail the additive-8 checksum.
  void decode(Uint8List frame) {
    if (!Codec.isValidChannelA(frame)) {
      _log.warn('fee7', 'dropping invalid frame');
      return;
    }
    // Use rxOpcodeRaw (no error-flag strip) because the fee7 opcode table
    // is dense in the 0x80..0xff range where the high bit is part of the
    // opcode, not an error indicator. See GHIDRA_DECOMPILATION.md §8.
    final opcode = Codec.rxOpcodeRaw(frame);
    final pl = Codec.rxPayload(frame);

    switch (opcode) {
      case Fee7.spo2HrUpdate:
        _spo2Hr.add(_decodeSpO2Hr(pl));
      case Fee7.capabilityBlock:
        _capability.add(_decodeCapabilityBlock(frame));
      case Fee7.bloodOxygenUpdate:
        _bloodOxygen.add(_decodeBloodOxygenUpdate(pl));
      case Fee7.hrv:
        // Reuse the Channel-A HrvSetting shape until the fee7
        // producer-side payload details are pinned down.
        _hrv.add(
          HrvSetting(
            enabled: pl.isNotEmpty && pl[0] != 0,
            intervalMinutes: pl.length >= 3 ? pl[2] : 0,
          ),
        );
      case Fee7.handshakeResponse:
        _handshake.add(_decodeHandshakeResponse(frame, pl));
      case Fee7.battery:
        _battery.add(_decodeBatteryResponse(pl));
      case Fee7.alertTrigger:
        _alert.add(_decodeAlertTrigger(pl));
      case Fee7.findPhoneEvent:
        _findPhone.add(_decodeFindPhoneEvent(pl));
      case Fee7.statusResponse:
        _status.add(_decodeStatusResponse(pl));
      case Fee7.modeControl:
        _mode.add(_decodeModeControl(pl));
      case Fee7.modeControlCont:
        _modeCont.add(_decodeModeControlCont(pl));
      case Fee7.longResponse:
        _long.add(LongResponse(opcode: opcode, payload: pl));
      case Fee7.memoryRead:
        _memoryRead.add(
          MemoryReadChunk(
            seq: _memoryReadSeq++,
            payload: Uint8List.fromList(pl),
          ),
        );
      case Fee7.otaTrigger:
        _ota.add(_decodeOtaTrigger(pl));
      case Fee7.echoBase:
      case Fee7.echoBase2:
        // Echo back as a unary opcode; firmware simply emits `[opcode]`.
        final u = UnaryOpcode(opcode, payload: pl);
        _unary.add(u);
      case Fee7.vibrationPattern:
        // 0xfe has structured decoding and is surfaced on onVibration only;
        // isUnary() deliberately excludes it so it is NOT also emitted on
        // onUnary.
        _vibration.add(VibrationPattern(opcode: opcode, payload: pl));
      default:
        if (Fee7.isUnary(opcode)) {
          _unary.add(UnaryOpcode(opcode, payload: pl));
        } else {
          _unknown.add(UnaryOpcode(opcode, payload: pl));
        }
    }
  }

  // ---------------------------------------------------------------------------
  // Decoders
  // ---------------------------------------------------------------------------

  SpO2HrUpdate _decodeSpO2Hr(Uint8List pl) {
    final sub = pl.isNotEmpty ? pl[0] : 0;
    return SpO2HrUpdate(sub: sub, payload: pl);
  }

  CapabilityBlock _decodeCapabilityBlock(Uint8List frame) {
    // The firmware returns a fixed byte sequence beginning
    // `[0x3c, 0, 0x40, 0xa0, 0x20, ...]`. We surface the first 6 bytes of
    // the frame verbatim so callers can compare against the expected
    // signature; any extra bytes are kept in `tail`.
    final fixed = frame.length >= 6
        ? Uint8List.sublistView(frame, 0, 6)
        : Uint8List.fromList(frame);
    final tail = frame.length > 6
        ? Uint8List.sublistView(frame, 6)
        : Uint8List(0);
    return CapabilityBlock(fixed: fixed, tail: tail);
  }

  BloodOxygenUpdate _decodeBloodOxygenUpdate(Uint8List pl) {
    final sub = pl.isNotEmpty ? pl[0] : 0;
    return BloodOxygenUpdate(sub: sub, payload: pl);
  }

  HandshakeResponse _decodeHandshakeResponse(Uint8List frame, Uint8List pl) {
    // Firmware sends a 15-byte device-info payload (see
    // GHIDRA_DECOMPILATION.md §8.2 / FUN_0082bf40). The body
    // interleaves four 4-byte fields in a vendor-specific byte
    // order that does NOT match plain little-endian:
    //   pl[0..2] = hw_ver (>>16, >>8, &0xff)
    //   pl[3..4] = pad
    //   pl[5..8] = fw_ver (&0xff, >>8, >>16 + pad)
    //   pl[9..11] = batt_raw (mod-100 → percent)
    //   pl[12..13] = tail (low, high)
    //
    // We surface the raw 14 bytes (pl) AND the structured view so
    // callers can pick the level of detail they want without
    // re-implementing the unpack.
    final payload = frame.length >= 15
        ? Uint8List.sublistView(frame, 0, 15)
        : Uint8List.fromList(frame);
    return HandshakeResponse(
      payload: payload,
      raw: pl,
      hwVersion: _decodeHandshakeHwVersion(pl),
      fwVersion: _decodeHandshakeFwVersion(pl),
      batteryPercent: pl.length >= 12
          ? (pl[9] | (pl[10] << 8) | (pl[11] << 16)) % 100
          : null,
      status: pl.length >= 14 ? (pl[12] | (pl[13] << 8)) & 0xFFFF : null,
    );
  }

  /// Decode the hardware-version uint24 at pl[0..2] in the order
  /// documented in `GHIDRA_DECOMPILATION.md` §8.2 — `>>16`, `>>8`,
  /// `&0xff` (LE-like, high byte first).
  static int _decodeHandshakeHwVersion(Uint8List pl) {
    if (pl.length < 3) return 0;
    return (pl[0] << 16) | (pl[1] << 8) | pl[2];
  }

  /// Decode the firmware-version uint32 at pl[5], pl[7], pl[8] —
  /// the bytes are non-contiguous (pl[6] is a pad). Per §8.2:
  /// `byte 6 = >>16`, `byte 8 = &0xff`, `byte 9 = >>8`.
  static int _decodeHandshakeFwVersion(Uint8List pl) {
    if (pl.length < 9) return 0;
    return (pl[5] << 16) | (pl[8] << 8) | pl[7];
  }

  AlertTrigger _decodeAlertTrigger(Uint8List pl) {
    return AlertTrigger(payload: pl);
  }

  FindPhoneEvent _decodeFindPhoneEvent(Uint8List pl) {
    // payload[1]==1 arms the pattern (per §8).
    final armsPattern = pl.length >= 2 && pl[1] == 1;
    return FindPhoneEvent(armsPattern: armsPattern, payload: pl);
  }

  Fee7BatteryResponse _decodeBatteryResponse(Uint8List pl) {
    return Fee7BatteryResponse(
      percent: pl.isNotEmpty ? pl[0] : null,
      charging: pl.length >= 2 ? pl[1] != 0 : null,
      payload: pl,
    );
  }

  StatusResponse _decodeStatusResponse(Uint8List pl) {
    final statusValue = pl.length >= 4 ? Codec.readU32le(pl, 0) : 0;
    return StatusResponse(statusValue: statusValue, payload: pl);
  }

  ModeControl _decodeModeControl(Uint8List pl) {
    final step = pl.isNotEmpty ? pl[0] : 0;
    return ModeControl(step: step, payload: pl);
  }

  ModeControlCont _decodeModeControlCont(Uint8List pl) {
    final step = pl.isNotEmpty ? pl[0] : 0;
    return ModeControlCont(step: step, payload: pl);
  }

  OtaTrigger _decodeOtaTrigger(Uint8List pl) {
    // Firmware `req[1]` selects the OTA state-machine action and `req[2]==1`
    // calls the BLE/service teardown helper first. `pl` is `req[1..14]`.
    final action = pl.isNotEmpty ? pl[0] : 0;
    final serviceResetRequested = pl.length >= 2 && pl[1] == 1;
    return OtaTrigger(
      action: action,
      serviceResetRequested: serviceResetRequested,
      payload: pl,
    );
  }

  void dispose() {
    for (final c in _controllers) {
      c.close();
    }
  }
}

// ---------------------------------------------------------------------------
// Typed records
// ---------------------------------------------------------------------------

/// Catch-all for opcodes the dispatcher does not specifically decode —
/// matches the firmware's `FUN_0082bcba` fallthrough so an unexpected
/// opcode is still surfaced rather than dropped.
class UnaryOpcode {
  UnaryOpcode(this.opcode, {Uint8List? payload}) : payload = payload ?? _empty;
  final int opcode;
  final Uint8List payload;
}

/// `0x36` SpO2 / HR read or set; `sub` (payload[0]) selects read vs set.
class SpO2HrUpdate {
  const SpO2HrUpdate({required this.sub, required this.payload});
  final int sub;
  final Uint8List payload;
}

/// `0x3c` fixed capability block. First 6 bytes carry the device
/// signature `[0x3c, 0, 0x40, 0xa0, 0x20, ...]`; any extra bytes are
/// preserved in [tail] for diagnostics.
class CapabilityBlock {
  CapabilityBlock({required this.fixed, Uint8List? tail})
    : tail = tail ?? _empty;
  final Uint8List fixed;
  final Uint8List tail;
}

/// `0x3e` SpO2 read/set.
class BloodOxygenUpdate {
  const BloodOxygenUpdate({required this.sub, required this.payload});
  final int sub;
  final Uint8List payload;
}

/// `0x48` 'H' handshake response — 15-byte device-info payload.
///
/// Beyond the raw [payload] / [raw] byte views, the decoder also
/// surfaces the four fields the firmware ships per
/// `FUN_0082bf40` / `GHIDRA_DECOMPILATION.md` §8.2:
///   * [hwVersion]  — hardware revision (e.g. `H59MA_V1.0`)
///   * [fwVersion]  — firmware version (e.g. `1.00.14`)
///   * [batteryPercent] — battery counter mod 100 (the firmware
///     does the divmod 100 for the host)
///   * [status]     — charge / status bits (low byte = flags,
///     high byte = state)
class HandshakeResponse {
  const HandshakeResponse({
    required this.payload,
    required this.raw,
    this.hwVersion = 0,
    this.fwVersion = 0,
    this.batteryPercent,
    this.status,
  });
  final Uint8List payload;
  final Uint8List raw;
  final int hwVersion;
  final int fwVersion;

  /// Battery percentage (0..99). `null` if the payload was too
  /// short to decode.
  final int? batteryPercent;

  /// Charge / status bits. `null` if the payload was too short.
  final int? status;
}

/// `0x03` direct battery response from FEE7.
///
/// H59MA v14 builds `[0x03, percent, charging]` at body offset `0x587e`.
class Fee7BatteryResponse {
  const Fee7BatteryResponse({
    required this.percent,
    required this.charging,
    required this.payload,
  });

  /// Battery percentage, or `null` when a malformed short payload was decoded.
  final int? percent;

  /// `true` when the firmware's charge-state helper returned non-zero.
  final bool? charging;

  final Uint8List payload;
}

/// `0x50` 'P' alert trigger; payload bytes carry the alarm pattern.
class AlertTrigger {
  const AlertTrigger({required this.payload});
  final Uint8List payload;
}

/// `0x51` 'Q' find-phone event. [armsPattern] is `true` when
/// `payload[1] == 1`, mirroring the firmware's "arm" condition.
class FindPhoneEvent {
  const FindPhoneEvent({required this.armsPattern, required this.payload});
  final bool armsPattern;
  final Uint8List payload;
}

/// `0x61` 'a' status response: 32-bit live status snapshot.
///
/// The firmware sends `pl[0..3] = DAT_0082bfd4 + 0x2c` as a little-endian
/// u32, or an all-zero idle ACK when the producer side has nothing new.
/// Older code treated the low bytes as battery/step aliases; keep those
/// accessors so existing callers do not break while newer code can use the
/// explicit [statusValue] and [statusLowByte] names.
class StatusResponse {
  StatusResponse({required this.statusValue, Uint8List? payload})
    : payload = payload ?? _empty;

  final int statusValue;

  bool get isIdle => statusValue == 0;

  int get statusLowByte => statusValue & 0xFF;

  /// Back-compat alias for older code that interpreted the low byte as battery.
  int get battery => statusLowByte;

  /// Low byte of the step counter (`pl[1]`). Truncated to 8 bits.
  int get stepsLowByte => (statusValue >> 8) & 0xFF;

  final Uint8List payload;

  /// Back-compat alias for the older `steps` field.
  int get steps => stepsLowByte;
}

/// `0x69` 'i' multi-step mode control (start).
class ModeControl {
  const ModeControl({required this.step, required this.payload});
  final int step;
  final Uint8List payload;
}

/// `0x6a` 'j' continuation of `0x69` mode control.
class ModeControlCont {
  const ModeControlCont({required this.step, required this.payload});
  final int step;
  final Uint8List payload;
}

/// `0xc1` one-shot health/status response.
class LongResponse {
  const LongResponse({required this.opcode, required this.payload});
  final int opcode;
  final Uint8List payload;
}

/// One chunk from `0xc0` raw memory read.
///
/// H59MA v14 builds each response with the shared `FUN_0082b938` streamer:
/// byte 0 is `0xc0`, bytes 1..14 are consecutive bytes copied from the
/// requested address, and byte 15 is the additive checksum. The streamer does
/// not include a wire sequence byte, so [seq] is assigned locally.
class MemoryReadChunk {
  const MemoryReadChunk({required this.seq, required this.payload});
  final int seq;
  final Uint8List payload;
}

/// `0xc3` OTA control.
///
/// H59MA v14 first checks `req[2] == 1` to run the BLE/service reset helper,
/// then dispatches `req[1] == 1` to `ota_dfu_state_machine(4, 0)` and
/// `req[1] == 2` to `ota_dfu_state_machine(0, 0)`. Since [payload] is
/// `req[1..14]`, [action] is `payload[0]` and [serviceResetRequested] is
/// `payload[1] == 1`.
class OtaTrigger {
  const OtaTrigger({
    required this.action,
    required this.serviceResetRequested,
    required this.payload,
  });

  /// Raw `req[1]` action byte. Known firmware actions are `1` and `2`.
  final int action;

  /// True when `req[2] == 1`; the firmware runs the BLE/service reset helper
  /// before applying [action].
  final bool serviceResetRequested;

  bool get startsDfu => action == 1;
  bool get exitsDfu => action == 2;

  /// Back-compat alias for older diagnostics. It now means the action byte is
  /// the firmware's `ota_dfu_state_machine(4, 0)` route.
  bool get routesToOta => startsDfu;

  final Uint8List payload;
}

/// `0xfe` vibration-pattern request. The firmware derives the pattern from
/// a duration argument.
class VibrationPattern {
  const VibrationPattern({required this.opcode, required this.payload});
  final int opcode;
  final Uint8List payload;
}

/// Shared empty `Uint8List` used as the default for optional `payload`
/// parameters on the typed records above. Cannot be `const` because
/// `Uint8List`'s constructor is not const-constructible; we fall back to a
/// top-level `final` so all record constructors share one allocation.
final Uint8List _empty = Uint8List(0);
