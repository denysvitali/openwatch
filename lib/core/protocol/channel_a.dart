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
  final _heartRateHeader = StreamController<void>.broadcast();
  final _heartRateChunk = StreamController<HeartRateChunk>.broadcast();
  final _heartRateError = StreamController<void>.broadcast();
  final _bloodOxygen = StreamController<BloodOxygenSetting>.broadcast();
  final _pressureSetting = StreamController<PressureSetting>.broadcast();
  final _pressure = StreamController<PressureReading>.broadcast();
  final _hrv = StreamController<HrvSetting>.broadcast();
  final _sugarLipids = StreamController<SugarLipidsSetting>.broadcast();
  final _uvTouch = StreamController<UvTouchSetting>.broadcast();
  final _sedentary = StreamController<SedentaryConfig>.broadcast();
  final _sportDetailHeader = StreamController<SportDetailHeader>.broadcast();
  final _sportDetailRecord = StreamController<SportDetailRecord>.broadcast();
  final _pushMsg = StreamController<PushMsgUint>.broadcast();
  final _phoneSport = StreamController<PhoneSportUpdate>.broadcast();
  final _muslim = StreamController<MuslimConfig>.broadcast();
  final _menstruation = StreamController<MenstruationMixture>.broadcast();
  final _realtimeHr = StreamController<int>.broadcast();
  final _factoryReset = StreamController<void>.broadcast();
  final _restoreKey = StreamController<void>.broadcast();
  final _factoryCommand = StreamController<FactoryCommand>.broadcast();
  final _vibrationChunks = StreamController<VibrationChunk>.broadcast();
  int _vibrationSeq = 0;
  final _displayClock = StreamController<DisplayClockResponse>.broadcast();

  /// Live-time, type, lang, tz embedded in the SetTime 0x01 ACK.
  Stream<DateTime> get onTime => _time.stream;

  /// DND read/write state (`0x06`).
  Stream<DndState> get onDnd => _dnd.stream;

  /// Heart-rate historical record (`0x15`, multi-frame; final frame has `0xff`).
  Stream<HeartRateRecord> get onHeartRateRecord => _heartRateRecord.stream;

  /// Heart-rate historical record header (`0x15`, phase 1). Fires once per
  /// read before the chunked payload — see
  /// `GHIDRA_DECOMPILATION.md` §3.12. The header discriminator is
  /// `pl[0] == 0x18` (the payload-size low byte of the `0x5180015`
  /// feature-bitmap-shape dword).
  Stream<void> get onHeartRateHeader => _heartRateHeader.stream;

  /// Heart-rate historical record chunk (`0x15`, phase 2). Fires once
  /// per 13-byte payload frame; consumers reassemble until 23 chunks
  /// have arrived (the maximum the firmware emits for a 292-byte record)
  /// or a quiet period elapses.
  Stream<HeartRateChunk> get onHeartRateChunk => _heartRateChunk.stream;

  /// Heart-rate historical record "no data at this index" error
  /// (`0x15` with `pl[0] == 0xFF`). Fires once when the requested index
  /// resolves to an empty record slot.
  Stream<void> get onHeartRateError => _heartRateError.stream;

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

  /// Detailed sport record header (`0x43`, phase 1).
  ///
  /// The firmware emits a 16-byte header frame carrying the end-of-data
  /// flag, the record count for the queried range, and the unit flag
  /// echo. Followed by [onSportDetailRecord] frames (one per counted
  /// slot). See `GHIDRA_DECOMPILATION.md` §3.6.
  Stream<SportDetailHeader> get onSportDetailHeader =>
      _sportDetailHeader.stream;

  /// Detailed sport record payload (`0x43`, phase 2). One frame per
  /// non-empty hourly slot in the range requested by the host.
  Stream<SportDetailRecord> get onSportDetailRecord =>
      _sportDetailRecord.stream;

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

  /// Vibration / motor pattern chunk (`0xc7`). The firmware fragments each
  /// play request into up to 6 chunks of ≤14 payload bytes (see
  /// `GHIDRA_DECOMPILATION.md` §3.2 — `FUN_0082b938`). There is **no end
  /// marker** on the wire; consumers must reassemble by buffering chunks
  /// until a quiet period (e.g. 100 ms) elapses, or until 6 chunks have
  /// arrived (the maximum the firmware emits).
  Stream<VibrationChunk> get onVibrationChunk => _vibrationChunks.stream;

  /// Watch-face / display-clock response (`0x18`). The watch echoes the
  /// request back with `response[2] = length` and the echoed label in
  /// `response[3..]` (`FUN_0082ccb6`, see
  /// `GHIDRA_DECOMPILATION.md` §3.5).
  Stream<DisplayClockResponse> get onDisplayClock => _displayClock.stream;

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
      case OpA.displayClock:
        _decodeDisplayClock(pl);
      case OpA.phoneSport:
        _decodePhoneSport(pl);
      case OpA.muslim:
        _decodeMuslim(pl);
      case OpA.menstruation:
        _decodeMenstruation(pl);
      case OpA.restoreKey:
        _restoreKey.add(null);
      case OpA.deviceReboot || 0x46:
        // 0xc6 ack path (sub != 0x6C). The 0x6C reboot path tears
        // down BLE before any response can be parsed — see
        // GHIDRA_DECOMPILATION.md §3.14. ProtocolHub.notifyDeviceRebootAccepted()
        // fires the event optimistically from the outbound send.
        _restoreKey.add(null);
      case OpA.vibrationResponse || 0x47:
        _decodeVibration(pl);
      case 0xa1 || 0x21:
        _decodeFactory(pl);
      // 0xff (factory-reset trigger, see OpA.factoryReset + FUN_0082cde8)
      // intentionally has NO switch arm: the handler does not queue a
      // response, so nothing will ever land in decode() for this opcode.
      // The WatchManager fires `onFactoryReset` optimistically when its
      // outbound sendA returns successfully.
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

  /// `dnd` (0x06): sub `0x01` reads state, sub `0x02` writes state.
  ///
  /// The read response (per `FUN_0082a7e4`, see
  /// `GHIDRA_DECOMPILATION.md` §3.7) is:
  ///   `pl[0] = 0x01` (sub-opcode echo)
  ///   `pl[1] = 0x01` (on) or `0x02` (off); `0x00` is reserved ("always-on")
  ///   `pl[2..5] = startHour, startMinute, endHour, endMinute`
  ///
  /// The write ack (`0x06 0x02`) echoes the request — enabled flag is at
  /// `pl[2]` per the write-path packing, with `pl[3..6]` holding the
  /// time window fields.
  void _decodeDnd(Uint8List pl) {
    if (pl.isEmpty) return;
    final sub = pl[0];
    if (sub == 0x01 && pl.length >= 6) {
      _dnd.add(
        DndState(
          enabled: pl[1] == 0x01,
          startHour: pl[2],
          startMinute: pl[3],
          endHour: pl[4],
          endMinute: pl[5],
        ),
      );
    } else if (sub == 0x02 && pl.length >= 6) {
      // Write ack mirrors the request layout (enable at pl[2]).
      _dnd.add(
        DndState(
          enabled: pl[2] == 0x01,
          startHour: pl[3],
          startMinute: pl[4],
          endHour: pl[5],
          endMinute: pl.length > 6 ? pl[6] : 0,
        ),
      );
    }
  }

  /// `readHeartRate` (0x15): two-phase per-record dump.
  ///
  /// Per `FUN_0082cf48` (`GHIDRA_DECOMPILATION.md` §3.12):
  ///   * Header frame  — `pl[0] == 0x18` (payload-size low byte),
  ///                     `pl[1..2] == 0x80 0x05` (rest of the
  ///                     `0x5180015` feature-bitmap dword).
  ///   * Payload chunk — `pl[0]` is the 1-based sequence number
  ///                     (1..23); `pl[1..14]` carries ≤13 payload
  ///                     bytes of the 292-byte HR record.
  ///   * Error frame   — `pl[0] == 0xFF` (no record at this index).
  ///
  /// The legacy single-frame `HeartRateRecord(timestamp, samples)`
  /// event is intentionally not fired — consumers should subscribe to
  /// the chunk stream and reassemble.
  void _decodeHeartRate(Uint8List pl) {
    if (pl.isEmpty) return;
    final tag = pl[0];
    if (tag == 0x18) {
      _heartRateHeader.add(null);
      return;
    }
    if (tag == 0xff) {
      _heartRateError.add(null);
      return;
    }
    // pl[0] = sequence number (1..23); everything past it is payload.
    _heartRateChunk.add(
      HeartRateChunk(seq: tag, payload: Uint8List.fromList(pl.sublist(1))),
    );
  }

  /// `realTimeHeartRate` (0x1e): continuous HR push (`pl[0]` = bpm).
  ///
  /// **v14 firmware status**: `0x1e` is host→watch only on H59MA v14 —
  /// the handler is a 3-sub-opcode controller (start/stop/reset) that
  /// never queues a response frame (see `FUN_0082d20c` +
  /// `GHIDRA_DECOMPILATION.md` §3.13). HR bpm pushes on v14 travel
  /// through the `0x73` / `0x78` `deviceNotify` paths instead — use
  /// `HrParser.parseDeviceNotify` in `lib/core/services/watch_manager.dart`
  /// for the live values.
  ///
  /// The decoder below is kept as a defensive fallback for older
  /// firmware variants that may have pushed `pl[0]=bpm` directly on
  /// `0x1e` (the original pre-RE assumption). It is harmless on v14
  /// because no frames ever reach it.
  void _decodeRealtimeHr(Uint8List pl) {
    if (pl.isEmpty) return;
    final bpm = pl[0] & 0xFF;
    if (bpm >= 30 && bpm <= 240) _realtimeHr.add(bpm);
  }

  /// `bloodOxygenSetting` (0x2c): sub `0x01` reads, `0x02` writes.
  ///
  /// The handler is a single-bit on/off flag for the SpO2 (blood-oxygen)
  /// sensor, stored as bit 1 of a shared config byte (per
  /// `FUN_0082d1c2` — see `GHIDRA_DECOMPILATION.md` §3.10). The
  /// response layout is:
  ///   `pl[0] = req[1]` echo (0x01 read / 0x02 write)
  ///   `pl[1] = SpO2 enabled value (0 = off, 1 = on)`
  void _decodeBloodOxygen(Uint8List pl) {
    if (pl.length < 2) return;
    _bloodOxygen.add(BloodOxygenSetting(sub: pl[0], enabled: pl[1] != 0));
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
  ///
  /// The read response (per `FUN_0082d258` + `FUN_0082ae84`, see
  /// `GHIDRA_DECOMPILATION.md` §3.9) carries:
  ///   `pl[0] = BCD(start_hour)`, `pl[1] = BCD(start_min)`,
  ///   `pl[2] = BCD(end_hour)`,  `pl[3] = BCD(end_min)`,
  ///   `pl[4] = flags`,           `pl[5] = interval` (raw u8, ≤ 60).
  /// (Frame byte numbers in the RE doc are 1..6 because they include
  /// the cmd byte; [Codec.rxPayload] strips the cmd so the pl indices
  /// shift down by one.)
  void _decodeSedentary(Uint8List pl) {
    if (pl.length < 6) return;
    final enabled = (pl[4] & 0x01) != 0;
    _sedentary.add(
      SedentaryConfig(
        enabled: enabled,
        startHour: Codec.fromBcd(pl[0]),
        startMinute: Codec.fromBcd(pl[1]),
        endHour: Codec.fromBcd(pl[2]),
        endMinute: Codec.fromBcd(pl[3]),
        flags: pl[4],
        interval: pl[5],
      ),
    );
  }

  /// `readDetailSport` (0x43): two-phase per-hour activity dump.
  ///
  /// Phase 1 (header frame) — `pl[0]` is the end-of-data flag
  /// (`0xF0` = records follow; `0xFF` = zero records / done), `pl[1]` is
  /// the record count, `pl[2]` echoes the unit_flag from the request
  /// (durations are 10-second units when 0, 1-second units when 1).
  /// Phase 2 (record frames) — `pl[0..2]` are BCD year/month/day for
  /// the day's "month index", `pl[3..4]` pack `(record_idx)|(slot_idx<<2)`,
  /// `pl[8..14]` carry the duration u16 split across three byte ranges
  /// plus the two aux u16s. See `GHIDRA_DECOMPILATION.md` §3.6.
  void _decodeSportDetail(Uint8List pl) {
    if (pl.length < 4) return;
    final endFlag = pl[0];
    if (endFlag == 0xf0 || endFlag == 0xff) {
      _sportDetailHeader.add(
        SportDetailHeader(
          endOfData: endFlag == 0xff,
          recordCount: pl[1],
          unitFlag: pl[2],
        ),
      );
      return;
    }
    // Record frame: BCD date + packed indices + duration/aux. The
    // 16-byte frame has the opcode at byte[0], so the indices below are
    // frame-relative - 1 (i.e. they map to pl[] starting at 0).
    if (pl.length < 14) return;
    final year = Codec.fromBcd(pl[0]);
    final month = Codec.fromBcd(pl[1]);
    final day = Codec.fromBcd(pl[2]);
    final packed = pl[3] | (pl[4] << 8);
    // RE wire: packed = (record_idx) | (slot_idx << 2). record_idx is
    // bounded by `0..count`, slot_idx by `0..23`, so 2 bits for idx and
    // 6 bits for slot.
    final recordIdx = packed & 0x3;
    final slotIdx = (packed >> 2) & 0x3f;
    // Frame bytes 8..9 = pl[7..8] = duration_lo; frame byte 14 = pl[13]
    // = duration_hi. Reassemble into a 24-bit value.
    final duration = pl[7] | (pl[8] << 8) | (pl[13] << 16);
    // Frame bytes 10..11 = pl[9..10] = aux_lo; frame bytes 12..13 =
    // pl[11..12] = aux_hi.
    final auxLo = pl[9] | (pl[10] << 8);
    final auxHi = pl[11] | (pl[12] << 8);
    _sportDetailRecord.add(
      SportDetailRecord(
        year: year,
        month: month,
        day: day,
        recordIdx: recordIdx,
        slotIdx: slotIdx,
        duration: duration,
        auxLo: auxLo,
        auxHi: auxHi,
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
  /// `0x00`/`0x06` default-ack, `0x01` start/finish session, `0x02`
  /// pause bit, `0x03` lap bit, `0x04` cancel, `0x05` GPS/position
  /// delta. See `GHIDRA_DECOMPILATION.md` §3.16.
  ///
  /// For `0x05` the two u24 LE values in the request are
  /// *arbitrary bit-pattern encodings* of latitude and longitude,
  /// NOT BCD degrees-minutes — the watch keeps a running sum of
  /// per-tick deltas and surfaces the cumulative total in the
  /// response. The field names [GpsDelta.steps] / [GpsDelta.meters]
  /// are kept for backwards compatibility with the original
  /// APK-derived PROTOCOL.md — see `GHIDRA_DECOMPILATION.md` §3.16
  /// for the correct semantic.
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
  ///
  /// **v14 firmware status**: the read+reset helpers
  /// `FUN_00829c88`/`FUN_00829c90` are unimplemented stubs in H59MA
  /// v14 — every read returns a one-byte `0x7A 0xFF` error frame and
  /// every reset is a no-op. We surface [MuslimConfig.stubbed] = true
  /// so a UI can show "prayer times not supported on this firmware"
  /// instead of hanging on a missing reply. The two-phase response
  /// (header + 13-byte-chunk fragmented payload via `FUN_0082c988`,
  /// see `GHIDRA_DECOMPILATION.md` §3.11) will be wired up here when
  /// the producer side ships.
  void _decodeMuslim(Uint8List pl) {
    if (pl.isEmpty) return;
    final stubbed = pl.length >= 2 && pl[1] == 0xff;
    _muslim.add(MuslimConfig(sub: pl[0], stubbed: stubbed));
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

  /// `vibrationResponse` (0xc7) — fragmented motor-pattern reply. Each
  /// fragment carries up to 14 payload bytes; the firmware emits up to 6
  /// chunks per play request (`FUN_0082b938` + `min(duration, 6)`). We
  /// surface a monotonically-increasing `seq` so a UI layer can reassemble
  /// the chunks by buffering until a quiet period or 6 chunks have arrived.
  void _decodeVibration(Uint8List pl) {
    _vibrationChunks.add(
      VibrationChunk(seq: _vibrationSeq++, payload: Uint8List.fromList(pl)),
    );
  }

  /// `displayClock` (0x18) — watch-face / clock display response. The
  /// firmware echoes the request back per `FUN_0082ccb6` (see
  /// `GHIDRA_DECOMPILATION.md` §3.5): `pl[1]` is the style selector,
  /// `pl[2]` is the echoed length (label length for style `0x01`, or the
  /// raw `length` byte from the request for label styles), and `pl[3..]`
  /// carries the echoed label slice for label styles.
  void _decodeDisplayClock(Uint8List pl) {
    if (pl.length < 3) return;
    final style = pl[0];
    final length = pl[1];
    final echoedLength = pl[2];
    final labelStart = pl.length > 3 ? 3 : pl.length;
    final labelEnd = (labelStart + echoedLength).clamp(0, pl.length);
    final label = pl.sublist(labelStart, labelEnd);
    _displayClock.add(
      DisplayClockResponse(
        style: style,
        length: length,
        echoedLength: echoedLength,
        label: Uint8List.fromList(label),
      ),
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

  /// Optimistic outbound-side hook: the host calls this when its
  /// `0xff "fff"` send completes without transport error (the firmware
  /// never queues a response — see
  /// `GHIDRA_DECOMPILATION.md` §3.8 / `FUN_0082cde8`).
  void emitFactoryReset() {
    if (_factoryReset.isClosed) return;
    _factoryReset.add(null);
  }

  /// Optimistic outbound-side hook for the `0xc6` device-reboot path.
  /// The `0x6C` sub-byte tears down BLE before any response can be
  /// parsed, so the host fires this on outbound send complete (see
  /// `GHIDRA_DECOMPILATION.md` §3.14).
  void emitRestoreKey() {
    if (_restoreKey.isClosed) return;
    _restoreKey.add(null);
  }

  void dispose() {
    for (final c in [
      _unknown,
      _time,
      _dnd,
      _heartRateRecord,
      _heartRateHeader,
      _heartRateChunk,
      _heartRateError,
      _bloodOxygen,
      _pressureSetting,
      _pressure,
      _hrv,
      _sugarLipids,
      _uvTouch,
      _sedentary,
      _sportDetailHeader,
      _sportDetailRecord,
      _pushMsg,
      _phoneSport,
      _muslim,
      _menstruation,
      _realtimeHr,
      _factoryReset,
      _restoreKey,
      _factoryCommand,
      _vibrationChunks,
      _displayClock,
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
  const DndState({
    required this.enabled,
    this.startHour = 0,
    this.startMinute = 0,
    this.endHour = 0,
    this.endMinute = 0,
  });
  final bool enabled;

  /// Do-Not-Disturb window start (hour-of-day, 0..23).
  final int startHour;

  /// Do-Not-Disturb window start minute (0..59).
  final int startMinute;

  /// Do-Not-Disturb window end (hour-of-day, 0..23). May be < [startHour]
  /// when the window crosses midnight.
  final int endHour;

  /// Do-Not-Disturb window end minute (0..59).
  final int endMinute;
}

class HeartRateRecord {
  const HeartRateRecord({required this.timestamp, required this.samples});
  final DateTime timestamp;
  final List<int> samples;
}

/// One chunk of a heart-rate historical record (`0x15`, phase 2).
///
/// The firmware ships a 292-byte HR record as `ceil(292 / 13) = 23`
/// chunks of ≤13 bytes each (see `GHIDRA_DECOMPILATION.md` §3.12,
/// `FUN_0082cf48`). [seq] is the 1-based sequence number; consumers
/// should buffer chunks until either 23 have arrived or a quiet
/// period elapses, then reassemble.
class HeartRateChunk {
  const HeartRateChunk({required this.seq, required this.payload});
  final int seq;
  final Uint8List payload;
}

class BloodOxygenSetting {
  const BloodOxygenSetting({required this.sub, required this.enabled});
  final int sub;
  final bool enabled;
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
    this.startMinute = 0,
    required this.endHour,
    this.endMinute = 0,
    this.flags = 0,
    this.interval = 0,
  });
  final bool enabled;

  /// Sedentary window start hour-of-day (0..23).
  final int startHour;

  /// Sedentary window start minute (0..59).
  final int startMinute;

  /// Sedentary window end hour-of-day (0..23). May be < [startHour]
  /// when the window crosses midnight.
  final int endHour;

  /// Sedentary window end minute (0..59).
  final int endMinute;

  /// Raw `flags` byte from the response. Bit 0 is the enabled flag;
  /// remaining bits are a day-of-week bitmap (semantics carried over
  /// from the producer — see `GHIDRA_DECOMPILATION.md` §3.9).
  final int flags;

  /// Nudge interval in minutes (clamped to ≤ 60 by the firmware).
  final int interval;
}

/// Header frame for a `0x43` per-hour activity dump (phase 1).
///
/// `endOfData == true` means the range is empty or already finished;
/// `endOfData == false` means [recordCount] record frames will follow on
/// [ChannelADispatcher.onSportDetailRecord].
class SportDetailHeader {
  const SportDetailHeader({
    required this.endOfData,
    required this.recordCount,
    required this.unitFlag,
  });
  final bool endOfData;
  final int recordCount;
  final int unitFlag;
}

/// Record frame for a `0x43` per-hour activity dump (phase 2).
///
/// [year]/[month]/[day] are the BCD-decoded date of the day's "month
/// index" (NOT the slot's timestamp — the slot is per-hour inside the
/// day). [slotIdx] is the hour-of-day (0..23), [recordIdx] is the
/// running counter. [duration] units are `10s` when the matching
/// header has `unitFlag == 0`, otherwise seconds. [auxLo] and [auxHi]
/// carry the per-slot second u16s (distance / calorie low / etc.,
/// depending on firmware variant — exact meaning TBD per
/// `GHIDRA_DECOMPILATION.md` §3.6).
class SportDetailRecord {
  const SportDetailRecord({
    required this.year,
    required this.month,
    required this.day,
    required this.recordIdx,
    required this.slotIdx,
    required this.duration,
    required this.auxLo,
    required this.auxHi,
  });
  final int year;
  final int month;
  final int day;
  final int recordIdx;
  final int slotIdx;
  final int duration;
  final int auxLo;
  final int auxHi;
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

  /// First u24 LE value from the `0x77 0x05` request. Per
  /// `GHIDRA_DECOMPILATION.md` §3.16 the firmware treats this as
  /// an arbitrary latitude bit-pattern (NOT steps). The field name
  /// is kept for backwards compatibility with the original
  /// APK-derived `PROTOCOL.md`.
  final int steps;

  /// Second u24 LE value from the `0x77 0x05` request — arbitrary
  /// longitude bit-pattern (NOT meters). Field name kept for
  /// backwards compatibility.
  final int meters;
}

class MuslimConfig {
  const MuslimConfig({required this.sub, this.stubbed = false});
  final int sub;

  /// `true` when the firmware returned the stub "not implemented"
  /// frame `[0x7A, 0xFF]` instead of prayer data. See
  /// `GHIDRA_DECOMPILATION.md` §3.11 — the read+reset helpers are
  /// unimplemented in H59MA v14.
  final bool stubbed;
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

/// A single fragment of a vibration / motor pattern response (opcode `0xc7`).
///
/// The firmware fragments each play request into up to 6 chunks of ≤14
/// payload bytes (`FUN_0082b938` + `min(duration, 6)`). There is no explicit
/// end-of-message marker on the wire — consumers must reassemble by
/// buffering chunks until a quiet period (e.g. 100 ms) elapses, or until
/// 6 chunks have arrived. [seq] is monotonically increasing per
/// [ChannelADispatcher] instance so reassemblers can detect dropped chunks.
class VibrationChunk {
  const VibrationChunk({required this.seq, required this.payload});
  final int seq;
  final Uint8List payload;
}

/// Response to a `displayClock` (0x18) request — the watch-face / clock
/// display echo. Per `FUN_0082ccb6` (GHIDRA_DECOMPILATION.md §3.5) the
/// firmware always echoes the request back; [style] is the sub-type
/// selector, [length] is the request's `length` byte (or the
/// previously-cached label length for style `0x01`), and [echoedLength]
/// is `response[2]` — the value the host should use to correlate the
/// echo. [label] is the echoed label slice for label styles (styles
/// `0x02`, `0x12`, `0x22`, `0x32`); empty for numeric or pass-through.
class DisplayClockResponse {
  const DisplayClockResponse({
    required this.style,
    required this.length,
    required this.echoedLength,
    required this.label,
  });
  final int style;
  final int length;
  final int echoedLength;
  final Uint8List label;
}
