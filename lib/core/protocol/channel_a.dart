import 'dart:async';
import 'dart:typed_data';

import '../ble/ble_transport.dart';
import '../services/app_log.dart';
import 'codec.dart';
import 'opcodes.dart';

final _log = AppLog.instance;

/// Channel-A opcode decoder + dispatcher.
///
/// Mirrors `FUN_0082d2dc` (the 16-byte frame dispatcher in H59MA v14) and
/// decodes each handler's response payload into a typed record. The dispatch
/// is a pure function over a single frame; consumers wire the inbound stream
/// to [decode] and listen on the typed `on*` streams they care about.
///
/// The handler table here is intentionally narrower than the firmware's
/// opcode table — we expose only the response shapes that the app actually
/// consumes. Unknown opcodes are still forwarded on [unknown] for diagnostics.
class ChannelADispatcher {
  ChannelADispatcher(this._transport);

  final BleTransport _transport;

  final _unknown = StreamController<ChannelAFrame>.broadcast();
  final _time = StreamController<DateTime>.broadcast();
  final _dnd = StreamController<DndState>.broadcast();
  final _heartRateRecord = StreamController<HeartRateRecord>.broadcast();
  final _bloodOxygen = StreamController<BloodOxygenSetting>.broadcast();
  final _pressureSetting = StreamController<PressureSetting>.broadcast();
  final _pressure = StreamController<PressureReading>.broadcast();
  final _hrv = StreamController<HrvSetting>.broadcast();
  final _sugarLipids = StreamController<SugarLipidsSetting>.broadcast();
  final _uvTouch = StreamController<UvTouchSetting>.broadcast();
  final _sedentary = StreamController<SedentaryConfig>.broadcast();
  final _sportDetail = StreamController<SportDetail>.broadcast();
  final _pushMsg = StreamController<PushMsgUint>.broadcast();
  final _phoneSport = StreamController<PhoneSportUpdate>.broadcast();
  final _muslim = StreamController<MuslimConfig>.broadcast();
  final _menstruation = StreamController<MenstruationMixture>.broadcast();
  final _realtimeHr = StreamController<int>.broadcast();
  final _factoryReset = StreamController<void>.broadcast();
  final _restoreKey = StreamController<void>.broadcast();
  final _factoryCommand = StreamController<FactoryCommand>.broadcast();

  /// Live-time, type, lang, tz embedded in the SetTime 0x01 ACK.
  Stream<DateTime> get onTime => _time.stream;

  /// DND read/write state (`0x06`).
  Stream<DndState> get onDnd => _dnd.stream;

  /// Heart-rate historical record (`0x15`, multi-frame; final frame has `0xff`).
  Stream<HeartRateRecord> get onHeartRateRecord => _heartRateRecord.stream;

  /// SpO2 setting (`0x2c`).
  Stream<BloodOxygenSetting> get onBloodOxygen => _bloodOxygen.stream;

  /// Pressure config (`0x37`).
  Stream<PressureSetting> get onPressureSetting => _pressureSetting.stream;

  /// Pressure reading / unit (`0x38`).
  Stream<PressureReading> get onPressure => _pressure.stream;

  /// HRV config (`0x39`).
  Stream<HrvSetting> get onHrv => _hrv.stream;

  /// Sugar/lipids setting (`0x3a`).
  Stream<SugarLipidsSetting> get onSugarLipids => _sugarLipids.stream;

  /// UV / touch-control setting (`0x3b`).
  Stream<UvTouchSetting> get onUvTouch => _uvTouch.stream;

  /// Sedentary reminder read/write (`0x25`/`0x26`).
  Stream<SedentaryConfig> get onSedentary => _sedentary.stream;

  /// Detailed sport record (`0x43`).
  Stream<SportDetail> get onSportDetail => _sportDetail.stream;

  /// Notification / emoji push (`0x72`).
  Stream<PushMsgUint> get onPushMsg => _pushMsg.stream;

  /// Phone-side sport config (`0x77`).
  Stream<PhoneSportUpdate> get onPhoneSport => _phoneSport.stream;

  /// Muslim-prayer config (`0x7a`).
  Stream<MuslimConfig> get onMuslim => _muslim.stream;

  /// Menstruation mixture read/write (`0x2b`).
  Stream<MenstruationMixture> get onMenstruation => _menstruation.stream;

  /// Continuous HR push (`0x1e`).
  Stream<int> get onRealtimeHr => _realtimeHr.stream;

  /// Factory reset completion (`0xff` ack after `"fff"` payload).
  Stream<void> get onFactoryReset => _factoryReset.stream;

  /// Reboot / restore-key sequence started (`0xc6`).
  Stream<void> get onRestoreKey => _restoreKey.stream;

  /// Factory / test-mode command received (`0x21`; the error-flagged response
  /// form is `0xa1` because `rxOpcode` strips the top bit).
  Stream<FactoryCommand> get onFactoryCommand => _factoryCommand.stream;

  /// Any frame we couldn't type-decode.
  Stream<ChannelAFrame> get unknown => _unknown.stream;

  /// Bind to the BLE transport's inbound Channel-A stream. Idempotent.
  StreamSubscription<Uint8List> bind() =>
      _transport.inboundA.listen(decode, onError: _onError);

  void _onError(Object e, StackTrace _) {
    _log.error('cha', 'inbound error: $e');
  }

  /// Decode a single Channel-A frame and fan it out to the right stream.
  ///
  /// Safe to call from anywhere; returns silently on invalid frames.
  void decode(Uint8List frame) {
    if (!Codec.isValidChannelA(frame)) {
      _log.warn('cha', 'dropping invalid frame');
      return;
    }
    final opcode = Codec.rxOpcode(frame);
    final pl = Codec.rxPayload(frame);
    switch (opcode) {
      case OpA.setTime:
        _decodeTime(pl);
      case OpA.dnd:
        _decodeDnd(pl);
      case OpA.readHeartRate:
        _decodeHeartRate(pl);
      case OpA.realTimeHeartRate:
        _decodeRealtimeHr(pl);
      case OpA.bloodOxygenSetting:
        _decodeBloodOxygen(pl);
      case OpA.pressure:
        _decodePressure(pl);
      case OpA.pressureSetting:
        _decodePressureSetting(pl);
      case OpA.hrv:
        _decodeHrv(pl);
      case OpA.sugarLipidsSetting:
        _decodeSugarLipids(pl);
      case OpA.touchControl:
        _decodeUvTouch(pl);
      case OpA.setSitLong:
      case OpA.readSitLong:
        _decodeSedentary(pl);
      case OpA.readDetailSport:
        _decodeSportDetail(pl);
      case OpA.pushMsgUint:
        _decodePushMsg(pl);
      case OpA.phoneSport:
        _decodePhoneSport(pl);
      case OpA.muslim:
        _decodeMuslim(pl);
      case OpA.menstruation:
        _decodeMenstruation(pl);
      case OpA.restoreKey:
        _restoreKey.add(null);
      case 0xa1 || 0x21:
        _decodeFactory(pl);
      case 0xff:
        // Factory reset ack; the request payload is `"fff"`.
        if (frame.length >= 16 &&
            frame[1] == 0x66 &&
            frame[2] == 0x66 &&
            frame[3] == 0x66) {
          _factoryReset.add(null);
        }
      default:
        _unknown.add(ChannelAFrame(opcode, pl, error: Codec.rxIsError(frame)));
    }
  }

  // ---------------------------------------------------------------------------
  // Decoders — one per opcode. Each mirrors the firmware handler it derives
  // from; see GHIDRA_DECOMPILATION.md §3 for the address map.
  // ---------------------------------------------------------------------------

  /// `setTime` (0x01) ACK mirrors `FUN_0082bb4e` — converts BCD back to DateTime.
  void _decodeTime(Uint8List pl) {
    if (pl.length < 6) return;
    final year = Codec.fromBcd(pl[0]) + 2000;
    final month = Codec.fromBcd(pl[1]);
    final day = Codec.fromBcd(pl[2]);
    final hour = Codec.fromBcd(pl[3]);
    final minute = Codec.fromBcd(pl[4]);
    final second = Codec.fromBcd(pl[5]);
    final t = DateTime(year, month, day, hour, minute, second);
    _time.add(t);
  }

  /// `dnd` (0x06): sub `0x01` reads state (`pl[1]`), sub `0x02` writes state.
  void _decodeDnd(Uint8List pl) {
    if (pl.isEmpty) return;
    final sub = pl[0];
    if (sub == 0x01 && pl.length >= 2) {
      _dnd.add(DndState(enabled: pl[1] == 1));
    } else if (sub == 0x02) {
      // Ack: just confirms the write; report enabled based on pl[1] if present.
      final enabled = pl.length >= 2 ? pl[1] == 1 : true;
      _dnd.add(DndState(enabled: enabled));
    }
  }

  /// `readHeartRate` (0x15): multi-frame response.
  ///
  /// `pl[0]==0x00` is the header (size + range); `pl[0]==0x01` is a record
  /// (utcStart i32 LE + samples); `pl[0]==0xff` ends the stream.
  void _decodeHeartRate(Uint8List pl) {
    if (pl.isEmpty) return;
    final tag = pl[0];
    if (tag == 0xff) return; // end marker; no record emitted
    if (tag == 0x01 && pl.length >= 5) {
      final ts = Codec.readU32le(pl, 1);
      final samples = <int>[];
      // Firmware samples are 13-byte stride; for the low-fidelity decoder we
      // surface the first byte of each record as a bpm candidate.
      for (var off = 5; off + 1 <= pl.length; off += 13) {
        final v = pl[off] & 0xFF;
        if (v >= 30 && v <= 240) samples.add(v);
      }
      if (samples.isNotEmpty) {
        _heartRateRecord.add(
          HeartRateRecord(
            timestamp: DateTime.fromMillisecondsSinceEpoch(
              ts * 1000,
              isUtc: true,
            ),
            samples: samples,
          ),
        );
      }
    }
  }

  /// `realTimeHeartRate` (0x1e): continuous HR push (`pl[0]` = bpm).
  void _decodeRealtimeHr(Uint8List pl) {
    if (pl.isEmpty) return;
    final bpm = pl[0] & 0xFF;
    if (bpm >= 30 && bpm <= 240) _realtimeHr.add(bpm);
  }

  /// `bloodOxygenSetting` (0x2c): sub `0x01` reads, `0x02` writes.
  void _decodeBloodOxygen(Uint8List pl) {
    if (pl.length < 2) return;
    final sub = pl[0];
    final value = pl[1];
    final enabled = value != 0;
    final intervalMin = pl.length >= 3 ? pl[2] : 0;
    _bloodOxygen.add(
      BloodOxygenSetting(
        sub: sub,
        enabled: enabled,
        intervalMinutes: intervalMin,
      ),
    );
  }

  /// `pressure` (0x38): sub `0x01` reads value; else writes unit.
  void _decodePressure(Uint8List pl) {
    if (pl.length < 2) return;
    final sub = pl[0];
    if (sub == 0x01) {
      final sys = pl[1] & 0xFF;
      final dia = pl.length >= 3 ? pl[2] & 0xFF : 0;
      _pressure.add(PressureReading(systolic: sys, diastolic: dia));
    } else {
      _pressure.add(PressureReading(unit: pl[1]));
    }
  }

  /// `pressureSetting` (0x37): read/write config.
  void _decodePressureSetting(Uint8List pl) {
    if (pl.length < 2) return;
    _pressureSetting.add(
      PressureSetting(
        enabled: pl[1] != 0,
        intervalMinutes: pl.length >= 3 ? pl[2] : 0,
      ),
    );
  }

  /// `hrv` (0x39): read/write HRV config.
  void _decodeHrv(Uint8List pl) {
    if (pl.length < 2) return;
    _hrv.add(
      HrvSetting(
        enabled: pl[1] != 0,
        intervalMinutes: pl.length >= 3 ? pl[2] : 0,
      ),
    );
  }

  /// `sugarLipidsSetting` (0x3a): sub `0x03`/`0x04` read/write.
  void _decodeSugarLipids(Uint8List pl) {
    if (pl.length < 2) return;
    _sugarLipids.add(SugarLipidsSetting(sub: pl[0], value: pl[1]));
  }

  /// `touchControl` (0x3b) / `uvSetting`: config byte.
  void _decodeUvTouch(Uint8List pl) {
    if (pl.length < 2) return;
    _uvTouch.add(
      UvTouchSetting(
        touchWake: (pl[1] & 0x01) != 0,
        uv: pl.length >= 3 ? pl[2] : 0,
      ),
    );
  }

  /// `readSitLong` (0x26) / `setSitLong` (0x25): sedentary reminder.
  void _decodeSedentary(Uint8List pl) {
    if (pl.length < 3) return;
    _sedentary.add(
      SedentaryConfig(
        enabled: pl[1] != 0,
        startHour: pl[2],
        endHour: pl.length >= 4 ? pl[3] : 0,
      ),
    );
  }

  /// `readDetailSport` (0x43): detail record; the firmware emits multi-frame.
  void _decodeSportDetail(Uint8List pl) {
    if (pl.length < 5) return;
    final ts = Codec.readU32le(pl, 1);
    _sportDetail.add(
      SportDetail(
        timestamp: DateTime.fromMillisecondsSinceEpoch(ts * 1000, isUtc: true),
      ),
    );
  }

  /// `pushMsgUint` (0x72): UTF-8 notification text, possibly emoji-encoded.
  void _decodePushMsg(Uint8List pl) {
    if (pl.length < 2) return;
    final type = pl[0];
    // Skip length prefix (LE u16 at pl[1..2]) if present; payload bytes follow.
    final start = pl.length >= 3 ? 3 : 1;
    final bytes = pl.sublist(start);
    final text = String.fromCharCodes(bytes.where((b) => b != 0));
    _pushMsg.add(PushMsgUint(type: type, text: text));
  }

  /// `phoneSport` (0x77): jump-table dispatch on sub-byte (per decomp).
  ///
  /// The firmware's `FUN_0082ce0c` reads `subData[0]` and dispatches:
  /// `0x00`/`0x06` default-ack, `0x01` start/finish session, `0x02` calls
  /// `FUN_00830cb2`, `0x03` calls `FUN_00830cd4`, `0x04` cancels timer,
  /// `0x05` GPS/position delta (two u24 LE values: steps, meters).
  void _decodePhoneSport(Uint8List pl) {
    if (pl.isEmpty) return;
    final sub = pl[0];
    GpsDelta? gps;
    if (sub == 0x05 && pl.length >= 9) {
      gps = GpsDelta(
        steps: Codec.readU24le(pl, 2),
        meters: Codec.readU24le(pl, 6),
      );
    }
    _phoneSport.add(PhoneSportUpdate(sub: _phoneSportSub(sub), gpsDelta: gps));
  }

  static PhoneSportSub _phoneSportSub(int raw) {
    switch (raw) {
      case 0x01:
        return PhoneSportSub.startFinish;
      case 0x02:
        return PhoneSportSub.controlA;
      case 0x03:
        return PhoneSportSub.controlB;
      case 0x04:
        return PhoneSportSub.cancel;
      case 0x05:
        return PhoneSportSub.gpsDelta;
      case 0x00:
      case 0x06:
      default:
        return PhoneSportSub.defaultAck;
    }
  }

  /// `muslim` (0x7a): sub `0x01` reads, `0x02 0x01` resets.
  void _decodeMuslim(Uint8List pl) {
    if (pl.isEmpty) return;
    _muslim.add(MuslimConfig(sub: pl[0]));
  }

  /// `menstruation` (0x2b): mixture container; firmware uses additive
  /// checksum over the body before sending.
  void _decodeMenstruation(Uint8List pl) {
    if (pl.length < 2) return;
    _menstruation.add(MenstruationMixture(sub: pl[0], payload: pl.sublist(1)));
  }

  /// `factory` (0x21) — factory / test mode dispatch (per `FUN_00827f5c`).
  /// `pl[0]` selects the test action (subs `0x01`..`0x06`); unknown subs map
  /// to [FactoryAction.unknown].
  void _decodeFactory(Uint8List pl) {
    if (pl.isEmpty) {
      _factoryCommand.add(
        const FactoryCommand(action: FactoryAction.unknown, rawSub: 0),
      );
      return;
    }
    final sub = pl[0];
    _factoryCommand.add(
      FactoryCommand(action: _factoryAction(sub), rawSub: sub),
    );
  }

  /// Maps a factory sub-byte to its typed [FactoryAction] (per the table in
  /// `firmwares/GHIDRA_DECOMPILATION.md` §3.1 "Opcode 0xa1 factory/test mode").
  static FactoryAction _factoryAction(int sub) {
    switch (sub) {
      case 0x01:
        return FactoryAction.fullReset;
      case 0x02:
        return FactoryAction.restoreState;
      case 0x03:
        return FactoryAction.powerOff;
      case 0x04:
        return FactoryAction.startHr;
      case 0x05:
        return FactoryAction.stopHr;
      case 0x06:
        return FactoryAction.saveAndPowerOff;
      default:
        return FactoryAction.unknown;
    }
  }

  void dispose() {
    for (final c in [
      _unknown,
      _time,
      _dnd,
      _heartRateRecord,
      _bloodOxygen,
      _pressureSetting,
      _pressure,
      _hrv,
      _sugarLipids,
      _uvTouch,
      _sedentary,
      _sportDetail,
      _pushMsg,
      _phoneSport,
      _muslim,
      _menstruation,
      _realtimeHr,
      _factoryReset,
      _restoreKey,
      _factoryCommand,
    ]) {
      c.close();
    }
  }
}

/// A typed view of one Channel-A frame.
class ChannelAFrame {
  ChannelAFrame(this.opcode, this.payload, {this.error = false});
  final int opcode;
  final Uint8List payload;

  /// Whether the device flagged the response with the `0x80` error bit.
  final bool error;
}

// ---------------------------------------------------------------------------
// Typed records
// ---------------------------------------------------------------------------

class DndState {
  const DndState({required this.enabled});
  final bool enabled;
}

class HeartRateRecord {
  const HeartRateRecord({required this.timestamp, required this.samples});
  final DateTime timestamp;
  final List<int> samples;
}

class BloodOxygenSetting {
  const BloodOxygenSetting({
    required this.sub,
    required this.enabled,
    required this.intervalMinutes,
  });
  final int sub;
  final bool enabled;
  final int intervalMinutes;
}

class PressureReading {
  const PressureReading({this.systolic = 0, this.diastolic = 0, this.unit = 0});
  final int systolic;
  final int diastolic;

  /// Unit byte when the frame was a unit-write (sub != 0x01).
  final int unit;
}

class PressureSetting {
  const PressureSetting({required this.enabled, required this.intervalMinutes});
  final bool enabled;
  final int intervalMinutes;
}

class HrvSetting {
  const HrvSetting({required this.enabled, required this.intervalMinutes});
  final bool enabled;
  final int intervalMinutes;
}

class SugarLipidsSetting {
  const SugarLipidsSetting({required this.sub, required this.value});
  final int sub;
  final int value;
}

class UvTouchSetting {
  const UvTouchSetting({required this.touchWake, required this.uv});
  final bool touchWake;
  final int uv;
}

class SedentaryConfig {
  const SedentaryConfig({
    required this.enabled,
    required this.startHour,
    required this.endHour,
  });
  final bool enabled;
  final int startHour;
  final int endHour;
}

class SportDetail {
  const SportDetail({required this.timestamp});
  final DateTime timestamp;
}

class PushMsgUint {
  const PushMsgUint({required this.type, required this.text});
  final int type;
  final String text;
}

/// Sub-commands of opcode `0x77` `phoneSport` as dispatched by
/// `FUN_0082ce0c` in H59MA v14. See `GHIDRA_DECOMPILATION.md` §3.
enum PhoneSportSub {
  /// `0x00` and `0x06` — default-ack handler `FUN_0082cede`.
  defaultAck,

  /// `0x01` — start or finish a sport session (`FUN_0082ce2a`).
  startFinish,

  /// `0x02` — control A: invokes `FUN_00830cb2` and sets the
  /// `DAT_0082cff4+1` flag (`FUN_0082ce64`).
  controlA,

  /// `0x03` — control B: invokes `FUN_00830cd4` and sets the
  /// `DAT_0082cff4+1` flag (`FUN_0082ce72`).
  controlB,

  /// `0x04` — cancel: tears down the 1000 ms timer (`FUN_0082ce80`).
  cancel,

  /// `0x05` — GPS / position delta carrying two u24 LE fields (`FUN_0082ce96`).
  gpsDelta,
}

/// A single phone-side sport update frame on Channel A opcode `0x77`.
///
/// The firmware reply is a single `PhoneSportUpdate` per inbound frame.
/// For sub [PhoneSportSub.gpsDelta] the firmware replies with a
/// `FUN_0082ce96` body carrying two cumulative u24 LE counters
/// (steps and meters); for all other subs only the dispatcher flag is
/// reported.
class PhoneSportUpdate {
  const PhoneSportUpdate({required this.sub, this.gpsDelta});

  final PhoneSportSub sub;

  /// Populated only when [sub] is [PhoneSportSub.gpsDelta] and the frame
  /// carries the full 9-byte body.
  final GpsDelta? gpsDelta;
}

/// GPS / position delta body of a `phoneSport` `0x05` frame.
///
/// Both fields are decoded as u24 little-endian. They are cumulative
/// counters maintained by `FUN_0082ce96` — a phone feeding the watch GPS
/// samples should subtract the previous frame to obtain a per-update
/// delta.
class GpsDelta {
  const GpsDelta({required this.steps, required this.meters});

  /// Cumulative step counter at the time of this GPS update (u24 LE).
  final int steps;

  /// Cumulative distance in meters at the time of this GPS update (u24 LE).
  final int meters;
}

class MuslimConfig {
  const MuslimConfig({required this.sub});
  final int sub;
}

class MenstruationMixture {
  const MenstruationMixture({required this.sub, required this.payload});
  final int sub;
  final Uint8List payload;
}

/// Sub-commands of opcode `0xa1` factory / test mode dispatched by
/// `FUN_00827f5c` in H59MA v14. See `GHIDRA_DECOMPILATION.md` §3.1.
enum FactoryAction {
  /// `0x01` — full reset: stop sensors/motor, save state, power off.
  fullReset,

  /// `0x02` — restore the saved state back into the sensor modules.
  restoreState,

  /// `0x03` — power off / enter DLPS immediately.
  powerOff,

  /// `0x04` — start HR measurement in `0x800` mode.
  startHr,

  /// `0x05` — stop HR measurement.
  stopHr,

  /// `0x06` — save current state and then power off.
  saveAndPowerOff,

  /// Any sub-byte outside the `0x01`..`0x06` range. The firmware responds
  /// with `0xffa1` (error) in this case.
  unknown,
}

/// A factory / test-mode command received on Channel A opcode `0xa1`.
///
/// The firmware dispatches on `pl[0]` to one of six actions; subs outside
/// `0x01`..`0x06` map to [FactoryAction.unknown] but [rawSub] preserves the
/// original byte for diagnostics.
class FactoryCommand {
  const FactoryCommand({required this.action, required this.rawSub});

  final FactoryAction action;

  /// Original `pl[0]` byte from the frame, kept verbatim so callers can
  /// log unrecognized subs without losing data.
  final int rawSub;
}
