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

  final WatchLink _transport;

  /// Every broadcast controller created via [_ctrl]; closed by [dispose] so
  /// adding a new opcode stream never requires touching the teardown list.
  final List<StreamController<Object?>> _controllers = [];

  StreamController<T> _ctrl<T>() {
    final c = StreamController<T>.broadcast();
    _controllers.add(c);
    return c;
  }

  late final _unknown = _ctrl<ChannelAFrame>();
  late final _time = _ctrl<DateTime>();
  late final _dnd = _ctrl<DndState>();
  late final _heartRateRecord = _ctrl<HeartRateRecord>();
  late final _heartRateHeader = _ctrl<void>();
  late final _heartRateChunk = _ctrl<HeartRateChunk>();
  late final _heartRateError = _ctrl<void>();
  late final _heartRateSetting = _ctrl<HeartRateSetting>();
  late final _bloodOxygen = _ctrl<BloodOxygenSetting>();
  late final _bpRecord = _ctrl<BpRecordChunk>();
  int _bpRecordSeq = 0;
  late final _pressureSettingHeader = _ctrl<PressureSettingHeader>();
  late final _pressureSettingChunk = _ctrl<PressureSettingChunk>();
  late final _pressure = _ctrl<PressureReading>();
  late final _hrvHeader = _ctrl<HrvSettingHeader>();
  late final _hrvChunk = _ctrl<HrvSettingChunk>();
  late final _sugarLipids = _ctrl<SugarLipidsSetting>();
  late final _uvTouch = _ctrl<UvTouchSetting>();
  late final _sedentary = _ctrl<SedentaryConfig>();
  late final _todaySport = _ctrl<SportTotals>();
  late final _sportDetailHeader = _ctrl<SportDetailHeader>();
  late final _sportDetailRecord = _ctrl<SportDetailRecord>();
  late final _pushMsg = _ctrl<PushMsgUint>();
  late final _pushMsgChunk = _ctrl<PushMsgChunk>();
  late final _pushMsgReassembled = _ctrl<PushMsgUint>();
  final _pushReassembler = PushMsgReassembler();
  int _pushMsgSeq = 0;
  late final _phoneSport = _ctrl<PhoneSportUpdate>();
  late final _muslim = _ctrl<MuslimConfig>();
  late final _menstruation = _ctrl<MenstruationMixture>();
  late final _realtimeHr = _ctrl<int>();
  late final _factoryReset = _ctrl<void>();
  late final _restoreKey = _ctrl<void>();
  late final _factoryCommand = _ctrl<FactoryCommand>();
  late final _vibrationChunks = _ctrl<VibrationChunk>();
  int _vibrationSeq = 0;
  late final _displayClock = _ctrl<DisplayClockResponse>();
  late final _queryDataDistribution = _ctrl<QueryDataDistribution>();
  late final _music = _ctrl<MusicRsp>();
  late final _alarm = _ctrl<Alarm>();

  /// Fires once per `0x01` setTime ACK, carrying the host's wall-clock
  /// time at the moment the watch confirmed the sync. The 14-byte payload
  /// of the ACK is a *fixed* capability-bitmap shape per
  /// `firmwares/GHIDRA_DECOMPILATION.md` §3.4 (the four little-endian
  /// dwords `0x16010000 / 0 / 0x200001 / 0x3000` — it does NOT carry the
  /// watch's current RTC). Subscribers that want a live RTC echo should
  /// not rely on this stream; use the host clock as the source of truth.
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

  /// Heart-rate setting read/write (`0x16`).
  Stream<HeartRateSetting> get onHeartRateSetting => _heartRateSetting.stream;

  /// SpO2 setting (`0x2c`).
  Stream<BloodOxygenSetting> get onBloodOxygen => _bloodOxygen.stream;

  /// Blood-pressure record chunk (`0x0d`). The firmware emits a
  /// fragmented BP record (header always first, body optional
  /// if record > 14 B) via `FUN_0082b938` after a `0x0e`
  /// `sub=0` advance. See `GHIDRA_DECOMPILATION.md` §3.19.
  Stream<BpRecordChunk> get onBpRecord => _bpRecord.stream;

  /// Stress history (`0x37`) — header discriminator (`pl[3] == 0x1E`).
  ///
  /// Per `GHIDRA_DECOMPILATION.md` §3.20 the read response is a
  /// two-phase fragmenter pattern: a single 16-byte header frame
  /// (the literal dword `0x1E050037` little-endian → `pl[3] == 0x1E`)
  /// followed by four sequenced payload frames via the shared
  /// `FUN_0082c988`. The `slot_id` (today vs yesterday) is echoed
  /// at `payload[0]`. See the RE for the 49-byte record layout
  /// (`slotId + 48 half-hour samples`).
  Stream<PressureSettingHeader> get onPressureSettingHeader =>
      _pressureSettingHeader.stream;

  /// Stress history (`0x37`) — payload chunk after the header.
  ///
  /// See [onPressureSettingHeader] for the full two-phase flow.
  /// Each chunk is up to 13 payload bytes; the firmware emits
  /// 4 chunks for a typical 49-byte record (`ceil(49 / 13) = 4`).
  Stream<PressureSettingChunk> get onPressureSettingChunk =>
      _pressureSettingChunk.stream;

  /// Stress auto-measure enabled flag (`0x36`).
  Stream<PressureReading> get onPressure => _pressure.stream;

  /// HRV config (`0x39`) — header discriminator (`pl[2] == 0x1E`).
  ///
  /// Per `GHIDRA_DECOMPILATION.md` §3.21 the read response is a
  /// two-phase fragmenter pattern: a single 16-byte header frame
  /// (the literal dword `0x1E050039` little-endian → `pl[2] == 0x1E`)
  /// followed by four sequenced payload frames via the shared
  /// `FUN_0082c988`. **Note**: the 0x1E feature id is the
  /// same as `0x37 pressure` — disambiguate by cmd byte
  /// (`OpA.hrv` 0x39 vs `OpA.pressure` 0x37).
  Stream<HrvSettingHeader> get onHrvHeader => _hrvHeader.stream;

  /// HRV config (`0x39`) — payload chunk after the header.
  ///
  /// See [onHrvHeader] for the full two-phase flow. Each chunk
  /// carries up to 13 bytes of the 49-byte HRV record
  /// (`slotId + 48 half-hour samples`).
  Stream<HrvSettingChunk> get onHrvChunk => _hrvChunk.stream;

  /// Sugar/lipids setting (`0x3a`).
  Stream<SugarLipidsSetting> get onSugarLipids => _sugarLipids.stream;

  /// UV / touch-control setting (`0x3b`).
  Stream<UvTouchSetting> get onUvTouch => _uvTouch.stream;

  /// Sedentary reminder read/write (`0x25`/`0x26`).
  Stream<SedentaryConfig> get onSedentary => _sedentary.stream;

  /// Today's activity totals (`0x48`). The payload uses the same 3-byte
  /// big-endian groups as the legacy Oudmon SDK's `TodaySportDataRsp`.
  Stream<SportTotals> get onTodaySport => _todaySport.stream;

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

  /// Raw `0x72` payload chunk (`FUN_00829e92`, see
  /// `GHIDRA_DECOMPILATION.md` §3.3). The host→watch direction is
  /// chunked (11 UTF-8 bytes per frame + a 2-byte flush marker pair);
  /// the watch→phone direction is normally single-frame but may also
  /// emit chunked if the watch mirrors the same buffer pattern for long
  /// outgoing notifications. [PushMsgChunk.seq] is a monotonically
  /// increasing 0-based sequence so subscribers can sort and reassemble
  /// without trusting wall-clock arrival order.
  Stream<PushMsgChunk> get onPushMsgChunk => _pushMsgChunk.stream;

  /// Reassembled `0x72` notification text. The reassembler buffers
  /// [PushMsgChunk]s emitted on [onPushMsgChunk] and flushes them as a
  /// single [PushMsgUint] when either:
  ///   * the §3.3 *flush marker* fires — a frame whose `pl[2] ==
  ///     pl[3]` (the firmware uses this guard to avoid spurious flushes
  ///     from stale data), **or**
  ///   * a 250 ms quiet window elapses with no new chunk.
  ///
  /// The single-frame shortcut on [onPushMsg] still fires immediately so
  /// legacy single-frame consumers don't pay the reassembly latency.
  Stream<PushMsgUint> get onPushMsgReassembled => _pushMsgReassembled.stream;

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

  /// Clock-alarm slot read (`0x24`). See [Alarm] for the record shape
  /// and `PROTOCOL.md` §4.3 for the wire layout.
  Stream<Alarm> get onAlarm => _alarm.stream;

  /// Now-playing push (`0x1d`). The watch re-broadcasts the metadata
  /// whenever iOS media state changes. See [MusicRsp] for the
  /// inferred wire layout — the only opcode in the persistent
  /// notify-listener registry without a fixed payload spec, so
  /// treat the field order as plausible until the first live
  /// capture re-validates it.
  Stream<MusicRsp> get onMusic => _music.stream;

  /// Data-distribution bitmask (`0x46`). The watch reports which of the
  /// last 32 days have stored health data; bit *d* ⇒ day *d* (where
  /// day 0 is today). See `PROTOCOL.md` §4.6.
  Stream<QueryDataDistribution> get onQueryDataDistribution =>
      _queryDataDistribution.stream;

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
      case OpA.heartRateSetting:
        _decodeHeartRateSetting(pl);
      case OpA.bpData:
        _decodeBpRecord(pl);
      case OpA.pressureSetting:
        _decodePressure(pl);
      case OpA.pressure:
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
      case OpA.todaySport:
        _decodeTodaySport(pl);
      case OpA.readDetailSport:
        _decodeSportDetail(pl);
      case OpA.pushMsgUint:
        _decodePushMsg(pl);
      case OpA.displayClock:
        _decodeDisplayClock(pl);
      case OpA.readAlarm:
        _decodeAlarm(pl);
      case OpA.phoneSport:
        _decodePhoneSport(pl);
      case OpA.muslim:
        _decodeMuslim(pl);
      case OpA.menstruation:
        _decodeMenstruation(pl);
      case OpA.restoreKey:
        _restoreKey.add(null);
      case OpA.queryDataDistribution:
        // `0x46` strips to the same base as the `0xc6` device-reboot
        // ack (top bit clears). Both raw opcodes land here after
        // `rxOpcode`. Use the last-marked outbound context to
        // discriminate:
        //   * raw 0xc6 + reboot context  → reboot ack → onRestoreKey
        //   * raw 0xc6 + distribution ctx → distribution error
        //   * raw 0x46 + anything         → distribution response
        // The 0x6C reboot path tears down BLE before any response
        // can be parsed (see GHIDRA_DECOMPILATION.md §3.14) —
        // ProtocolHub optimistically fires onRestoreKey on the
        // outbound send complete via emitRestoreKey().
        if (Codec.rxOpcodeRaw(frame) == OpA.deviceReboot && _expectRebootAck) {
          _restoreKey.add(null);
          _expectRebootAck = false;
        } else {
          _decodeQueryDataDistribution(pl, error: Codec.rxIsError(frame));
        }
      case OpA.vibrationResponse || 0x47:
        _decodeVibration(pl);
      case 0xa1 || 0x21:
        _decodeFactory(pl);
      case OpA.musicNotify:
        _decodeMusic(pl);
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

  /// `setTime` (0x01) ACK observer.
  ///
  /// The firmware's reply payload is a 14-byte **fixed** capability shape
  /// (the four little-endian dwords `0x16010000 / 0 / 0x200001 / 0x3000`)
  /// per `firmwares/GHIDRA_DECOMPILATION.md` §3.4 — it does NOT carry the
  /// watch's current RTC, so we cannot decode a meaningful DateTime from
  /// the bytes. The previous behaviour read the capability dwords as BCD
  /// and emitted a bogus `DateTime(2000, …)`, which surfaced downstream
  /// as a stable "year 2000" clock mismatch on every sync. The right
  /// signal for subscribers is "the watch acknowledged setTime at host
  /// wall-clock `now`" — that's all we can truthfully emit.
  void _decodeTime(Uint8List pl) {
    if (pl.length < 4) return;
    _time.add(DateTime.now());
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

  /// `queryDataDistribution` (0x46): 4-byte BE bitmask of which
  /// of the last 32 days have stored health data. Per
  /// `PROTOCOL.md` §4.6: `isTheDayHasData(day) = (mask >> day) & 1`.
  /// A wire byte of `0xC6` (`0x46 | 0x80`) means the device is
  /// reporting a per-opcode error — we surface that via
  /// [QueryDataDistribution.errorFlag] so callers can decide
  /// whether to fall back to blind polling.
  void _decodeQueryDataDistribution(Uint8List pl, {required bool error}) {
    if (pl.isEmpty) return;
    _queryDataDistribution.add(
      QueryDataDistribution.fromPayload(pl, errorFlag: error),
    );
  }

  /// `readHeartRate` (0x15): two-phase per-record dump.
  ///
  /// Per `FUN_0082cf48` (`GHIDRA_DECOMPILATION.md` §3.12):
  ///   * Header frame  — older captures use `pl[0] == 0x18` (payload-size
  ///                     low byte), `pl[1..2] == 0x80 0x05` (rest of the
  ///                     `0x5180015` feature-bitmap dword). H59MAX live
  ///                     firmware sends the same phase as
  ///                     `pl[0] == 0x00`, `pl[1] == totalFrames`,
  ///                     `pl[2] == sampleIntervalMinutes`.
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
    if (tag == 0x18 || (tag == 0x00 && pl.length >= 3 && pl[1] > 0)) {
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

  /// `heartRateSetting` (0x16): read/write HR auto-measure config.
  ///
  /// Per `PROTOCOL.md` §4.3 the read response is:
  ///   `pl[0] = 0x01` (sub-opcode echo)
  ///   `pl[1] = enabled` (1 = on, 2 = off)
  ///   `pl[2] = interval` (minutes between auto-measures)
  ///   `pl[3] = startInterval` (minutes after midnight to start)
  ///   `pl[4] = tooLow` (bpm threshold for low alarm)
  ///   `pl[5] = tooHigh` (bpm threshold for high alarm)
  ///
  /// The write ack (`0x16 0x02`) echoes the request — same layout.
  void _decodeHeartRateSetting(Uint8List pl) {
    if (pl.length < 3) return;
    final sub = pl[0];
    int enabledVal;
    int interval;
    int startInterval;
    int tooLow;
    int tooHigh;
    if (sub == 0x01 && pl.length >= 6) {
      enabledVal = pl[1];
      interval = pl[2];
      startInterval = pl[3];
      tooLow = pl[4];
      tooHigh = pl[5];
    } else if (sub == 0x02 && pl.length >= 6) {
      enabledVal = pl[2];
      interval = pl[3];
      startInterval = pl[4];
      tooLow = pl[5];
      tooHigh = pl.length > 6 ? pl[6] : 180;
    } else {
      return;
    }
    _heartRateSetting.add(
      HeartRateSetting(
        enabled: enabledVal == 1,
        interval: interval,
        startInterval: startInterval,
        tooLow: tooLow,
        tooHigh: tooHigh,
      ),
    );
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

  /// `bpData` (0x0d): blood-pressure record chunk.
  ///
  /// Per `GHIDRA_DECOMPILATION.md` §3.19 / `FUN_0082cb28` +
  /// `FUN_0082c0a4`: the response to a `0x0e sub=0` advance is a
  /// fragmented BP record — the first chunk is always a 14-byte
  /// header, followed by an optional body chunk for records longer
  /// than 14 B. There is no explicit end-of-message marker.
  ///
  /// The decoder surfaces each chunk with a monotonically
  /// increasing [BpRecordChunk.seq] (reset by the consumer on
  /// each `advanceBpRecord()` request — the dispatcher itself
  /// cannot know when the host issued one). Consumers reassemble
  /// by starting a new record each time they see `seq` reset.
  void _decodeBpRecord(Uint8List pl) {
    if (pl.isEmpty) return;
    _bpRecord.add(BpRecordChunk(seq: _bpRecordSeq++, payload: pl));
  }

  /// `pressureSetting` (0x36): 1-bit on/off setting (analogous to 0x2c SpO2).
  ///
  /// Per `FUN_0082ca54` / `GHIDRA_DECOMPILATION.md` §3.17:
  ///   `pl[0]` = sub-opcode echo (0x01 read / 0x02+ write)
  ///   `pl[1]` = pressure enabled value (0/1 for read; echoed
  ///             req[2] for write)
  ///
  /// The H59MA pressure sensor (if present) is either enabled or
  /// disabled — not a continuous reading. A host that wants the
  /// actual mmHg / kPa must subscribe to a push channel (likely
  /// 0x2B-routed event) rather than poll 0x36.
  void _decodePressure(Uint8List pl) {
    if (pl.length < 2) return;
    _pressure.add(PressureReading(enabled: pl[1] != 0));
  }

  /// `pressure` (0x37): stress-history two-phase read response.
  ///
  /// Per `GHIDRA_DECOMPILATION.md` §3.20 the response is identical
  /// in shape to the `0x7a muslim` handler — a single 16-byte
  /// header frame followed by four sequenced `FUN_0082c988`
  /// payload frames. Each payload frame carries `seq + up to 13`
  /// record bytes. The header discriminator is
  /// `pl[3] == 0x1E` (the feature-bitmap-shape dword `0x1E050037`
  /// little-endian → bytes `0x37, 0x00, 0x05, 0x1E`).
  ///
  /// The actual 49-byte record (`slotId + 48 half-hour samples`)
  /// is *not* decoded here — consumers reassemble from the chunks
  /// and apply the producer-side layout from `FUN_008344fe`.
  void _decodePressureSetting(Uint8List pl) {
    if (pl.length < 4) return;
    // The RE indexes bytes from frame[0] (the cmd byte); [Codec.rxPayload]
    // strips that off, so pl[2] = frame[3] = the 0x1E discriminator.
    if (pl[2] == 0x1e) {
      _pressureSettingHeader.add(PressureSettingHeader(slotId: pl[0]));
      return;
    }
    _pressureSettingChunk.add(
      PressureSettingChunk(payload: _stripOptionalSeriesSeq(pl)),
    );
  }

  /// `hrv` (0x39): HRV-history two-phase read response.
  ///
  /// Per `GHIDRA_DECOMPILATION.md` §3.21 the response is
  /// structurally identical to `0x37 stress history` — a single
  /// 16-byte header frame followed by four sequenced `FUN_0082c988`
  /// payload frames. Each payload frame carries `seq + up to 13`
  /// record bytes. The header discriminator is `pl[2] == 0x1E`
  /// (the `0x1E050039` little-endian dword);
  /// the *same* 0x1E feature id as `0x37 stress history`, so
  /// the cmd byte is the only reliable route discriminator.
  void _decodeHrv(Uint8List pl) {
    if (pl.length < 4) return;
    if (pl[2] == 0x1e) {
      _hrvHeader.add(HrvSettingHeader(slotId: pl[0]));
      return;
    }
    _hrvChunk.add(HrvSettingChunk(payload: _stripOptionalSeriesSeq(pl)));
  }

  Uint8List _stripOptionalSeriesSeq(Uint8List pl) {
    // Live H59MAX 0x37/0x39 chunks carry a 1-based series byte followed
    // by 13 data bytes. Header frames are filtered before this helper.
    if (pl.length == 14 && pl[0] >= 1 && pl[0] <= 4) {
      return Uint8List.sublistView(pl, 1);
    }
    return pl;
  }

  /// `sugarLipidsSetting` (0x3a): sub `0x03` (sugar) / `0x04` (lipids)
  /// read/write. Per `GHIDRA_DECOMPILATION.md` §3.22 / `FUN_0082cc1e`:
  ///   * `pl[0]` = sub echo (0x03 sugar / 0x04 lipids)
  ///   * `pl[1]` = sub-cmd echo (0x01 read / 0x02 write)
  ///   * `pl[2]` = feature value (0/1 for read; echoed `req[3]` for
  ///     sugar-write; zeroed out for the lipids 1-byte-cmd ack)
  ///
  /// Sugar writes echo the request frame (same shape as `0x06 DND` §3.7
  /// and `0x3b uvTouch` §3.18), so when `sub == 0x03 && subCmd == 0x02`
  /// we surface [SugarLipidsSetting.writeAcksEcho] = true. Lipids writes
  /// use a 1-byte-cmd ack `[0x3A, 0, 0, 0, 0…0, cksum]` and we surface
  /// `writeAcksEcho = false` — the host can then issue a follow-up read
  /// to confirm the bit flipped.
  void _decodeSugarLipids(Uint8List pl) {
    if (pl.length < 2) return;
    final sub = pl[0];
    final subCmd = pl[1];
    final featureValue = pl.length > 2 ? pl[2] : 0;
    final writeAcksEcho = sub == 0x03 && subCmd == 0x02;
    _sugarLipids.add(
      SugarLipidsSetting(
        sub: sub,
        featureValue: featureValue,
        writeAcksEcho: writeAcksEcho,
      ),
    );
  }

  /// `touchControl` (0x3b) / `uvSetting`: 1-byte read/write of the
  /// UV/touch control byte at `DAT_0082cfe8 + 8`.
  ///
  /// Per `FUN_0082cbc8` / `GHIDRA_DECOMPILATION.md` §3.18:
  ///   `pl[0] = sub-opcode echo (0x01 read / 0x02 write)`
  ///   `pl[1] = batch-mode flag` (non-zero → don't commit, response
  ///              is just an echo of the request)
  ///   `pl[2] = read value (0x01 path)` | `req[3] (0x02 + no-op)`
  ///
  /// The rest of the frame is a byte-for-byte echo of the request
  /// — the handler `memcpy`s the request into the response and
  /// overwrites only byte 0 (cmd) and byte 2 (read value).
  void _decodeUvTouch(Uint8List pl) {
    if (pl.length < 3) return;
    _uvTouch.add(
      UvTouchSetting(sub: pl[0], configByte: pl[2], batchMode: pl[1] != 0),
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

  /// `todaySport` (0x48): 3-byte big-endian activity totals.
  ///
  /// This opcode is not part of the v14 Channel-A dispatcher table in
  /// GHIDRA §3, but it remains in the APK-derived protocol and is used by
  /// existing firmware variants. Keeping it typed here lets the rest of
  /// the app share one parser with [WatchManager].
  void _decodeTodaySport(Uint8List pl) {
    final totals = SportTotals.tryParse(pl);
    if (totals != null) _todaySport.add(totals);
  }

  /// `readDetailSport` (0x43): two-phase per-hour activity dump.
  ///
  /// Phase 1 (header frame) — `pl[0]` is the end-of-data flag
  /// (`0xF0` = records follow; `0xFF` = zero records / done), `pl[1]` is
  /// the record count, `pl[2]` echoes the unit_flag from the request
  /// (durations are 10-second units when 0, 1-second units when 1).
  /// Phase 2 (record frames) — `pl[0..2]` are BCD year/month/day for
  /// the day's "month index", `pl[3]` packs the hour slot (`slot << 2`),
  /// `pl[4]` is the record index, `pl[5]` echoes the header count, and
  /// `pl[6..11]` carry duration + two aux u16s. See
  /// `GHIDRA_DECOMPILATION.md` §3.6 and live H59MA_V1.0 captures.
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
    final slotIdx = (pl[3] >> 2) & 0x3f;
    final recordIdx = pl[4];
    final duration = pl[6] | (pl[7] << 8);
    final auxLo = pl[8] | (pl[9] << 8);
    final auxHi = pl[10] | (pl[11] << 8);
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
  ///
  /// Per `GHIDRA_DECOMPILATION.md` §3.3 (`FUN_00829e92`), a `0x72` frame is:
  ///
  /// | Byte | Field                                |
  /// |-----:|--------------------------------------|
  /// |  0   | `notification_type` (0..14)          |
  /// |  1   | `flush_marker_lo`                     |
  /// |  2   | `flush_marker_hi`                     |
  /// |  3.. | up to 11 UTF-8 bytes of payload       |
  ///
  /// `flush_marker_lo == flush_marker_hi` triggers a render-and-clear on the
  /// firmware side — that's the only end-of-message marker on the wire.
  ///
  /// We expose three streams:
  ///   * [onPushMsg]       — single-frame shortcut for legacy callers
  ///     (skips reassembly; matches the previous behavior exactly).
  ///   * [onPushMsgChunk]  — raw frame, plus [PushMsgChunk.seq] for
  ///     sort-by-arrival-order reassembly.
  ///   * [onPushMsgReassembled] — chunked frames merged into one
  ///     [PushMsgUint] via the §3.3 flush marker or a 250 ms quiet window.
  void _decodePushMsg(Uint8List pl) {
    if (pl.isEmpty) return;

    // Capture before push() — the reassembler flips _isFirstFrame to
    // false during the first frame, so the check below would otherwise
    // always read false after a successful push().
    final wasFirstFrame = _pushReassembler.isFirstFrame;

    // Raw chunk (always) — emits with a monotonic seq so subscribers can
    // reassemble in arrival order without trusting wall-clock timing.
    final seq = _pushMsgSeq++;
    _pushMsgChunk.add(PushMsgChunk(seq: seq, payload: Uint8List.fromList(pl)));
    _pushReassembler.push(seq, pl, _pushMsgReassembled);

    // Legacy single-frame shortcut. We only fire this on the *first*
    // frame of a sequence so a chunked message doesn't fan out into N
    // truncated `PushMsgUint`s — the reassembled stream is the
    // authoritative source for chunked messages.
    if (wasFirstFrame) {
      final type = pl[0];
      // Legacy wire shape (PROTOCOL.md §4.6, mirrored in §3.3 host→watch
      // direction): `[type, lenLo, lenHi, content…]`. The first 3 bytes
      // are a u16-LE length prefix when present; we only skip them when
      // there's room.
      final start = pl.length >= 3 ? 3 : 1;
      final bytes = pl.sublist(start);
      final text = String.fromCharCodes(bytes.where((b) => b != 0));
      _pushMsg.add(PushMsgUint(type: type, text: text));
    }
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

  /// `menstruation` (0x2b): 16-byte notify frame. Layout (incl. byte-0
  /// sentinel quirk + read/write asymmetry) is documented on
  /// [MenstruationMixture]; see also `GHIDRA_DECOMPILATION.md` §3.1.
  /// The dispatcher forwards the 15-byte body unchanged — callers that
  /// want the parsed fields should use [MenstruationMixture.tryParse].
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

  /// `musicNotify` (0x1d) — now-playing push forwarded from the watch's
  /// ANCS / iOS-media bridge.
  ///
  /// The on-wire layout is inferred from the symmetric host→watch
  /// `executeMusicSend` (`0x06 → [(playing^1), progress, volume, UTF-8 name]`,
  /// see `PROTOCOL.md` §4.8 line 463). Per `PROTOCOL.md` §3.1 the
  /// `MusicSwitch playing` boolean is XOR-1 inverted, so a wire byte
  /// of `0` means "playing" and `1` means "paused".
  ///
  /// This decoder is best-effort: `0x1d` is in the persistent
  /// notify-listener registry pre-registered by the APK (`PROTOCOL.md`
  /// §4.1 line 194) but is **not** statically resolved to a fixed
  /// payload in H59MA v14 — there are no live captures of the
  /// payload bytes, so the field ordering is inferred. Treat
  /// [MusicRsp] fields as plausibly-ordered; the dashboard hides
  /// the card entirely when the wire bytes look malformed.
  void _decodeMusic(Uint8List pl) {
    if (pl.length < 4) {
      _log.warn('music', 'dropped short 0x1d frame (len=${pl.length})');
      return;
    }
    final playing = (pl[0] ^ 0x01) != 0;
    final progress = pl[1] & 0xFF;
    final volume = pl[2] & 0xFF;
    // Skip a leading null (often used as a fill byte between the
    // header fields and the start of the UTF-8 string) and strip any
    // trailing null padding so the UI never shows stray "·" glyphs.
    var start = 3;
    if (start < pl.length && pl[start] == 0) start++;
    final rawTitle = pl.sublist(start);
    final title = String.fromCharCodes(rawTitle.where((b) => b != 0)).trim();
    _music.add(
      MusicRsp(
        isPlaying: playing,
        progress: progress,
        volume: volume,
        track: title,
      ),
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

  /// `readAlarm` (0x24) — clock-alarm slot read.
  ///
  /// Per `PROTOCOL.md` §4.3 the response is
  /// `[idx, en(0..2), hourBCD, minuteBCD, day0..day6]` (11 bytes
  /// total). `en == 0` is treated as "disabled" — the docs say the
  /// value range is 0..2 but 0 only appears on freshly-flashed
  /// devices, so mapping it explicitly avoids surfacing a phantom
  /// disabled alarm.
  void _decodeAlarm(Uint8List pl) {
    if (pl.length < 4) return;
    final idx = pl[0];
    final enabled = pl[1] == 1;
    final hour = Codec.fromBcd(pl[2]);
    final minute = Codec.fromBcd(pl[3]);
    final weekdays = List<bool>.generate(7, (i) {
      final b = pl.length > 4 + i ? pl[4 + i] : 0;
      return b != 0;
    });
    _alarm.add(
      Alarm(
        slot: idx,
        enabled: enabled,
        hour: hour,
        minute: minute,
        weekdays: weekdays,
      ),
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

  // ---------------------------------------------------------------------------
  // Outbound-context tracking.
  //
  // The 0x46 distribution opcode and the 0xc6 reboot ack share the
  // same post-strip opcode (top bit clears). We mark which request
  // we just sent so the next 0xC6 frame can be routed to the right
  // stream. The flag is single-shot — it clears on the first
  // matching response (or whenever a new request overrides it).
  // ---------------------------------------------------------------------------

  bool _expectRebootAck = false;

  /// Mark that the host just sent a `0xc6` device-reboot request. The
  /// next 0xC6 response frame will be routed to [onRestoreKey].
  void markRebootRequest() {
    _expectRebootAck = true;
  }

  /// Mark that the host just sent a `0x46` queryDataDistribution
  /// request. The next response frame on this opcode — including
  /// any 0xC6 error-flagged variant — will be routed to
  /// [onQueryDataDistribution].
  void markDistributionQuery() {
    _expectRebootAck = false;
  }

  void dispose() {
    _pushReassembler.cancel();
    for (final c in _controllers) {
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

/// Stress auto-measure enabled flag (`0x36`). The H59MA pressure sensor is
/// either on or off — there is no continuous reading on this
/// opcode. See `GHIDRA_DECOMPILATION.md` §3.17 / `FUN_0082ca54`.
/// One chunk of a blood-pressure record (`0x0d`).
///
/// Per `GHIDRA_DECOMPILATION.md` §3.19 the record is fragmented
/// via `FUN_0082b938`: the first chunk is always the 14-byte
/// header, followed by an optional body chunk when the record
/// is larger than 14 B. The decoder cannot tell header from body
/// from a single frame — the discriminator is the *position*
/// within an advance sequence (host issued `0x0e sub=0`, first
/// frame = header, optional second frame = body). The dispatcher
/// exposes a monotonic [seq] so consumers can reset on each
/// advance request.
class BpRecordChunk {
  const BpRecordChunk({required this.seq, required this.payload});
  final int seq;
  final Uint8List payload;
}

class PressureReading {
  const PressureReading({required this.enabled});
  final bool enabled;
}

/// Header frame of a `0x37` stress-history read (`pl[3] == 0x1E`).
/// [slotId] echoes `req[1]` (today = 0, yesterday = 1, ...).
/// See `GHIDRA_DECOMPILATION.md` §3.20.
class PressureSettingHeader {
  const PressureSettingHeader({required this.slotId});
  final int slotId;
}

/// Payload chunk of a `0x37` stress-history read (frames 2..N
/// of the two-phase response). Each chunk carries up to 13
/// bytes of the 49-byte pressure record (`slotId + 48 samples`)
/// after the wire sequence byte is stripped. There is no
/// end-of-message marker — consumers reassemble by waiting for a
/// quiet period after the header.
class PressureSettingChunk {
  const PressureSettingChunk({required this.payload});
  final Uint8List payload;
}

/// Heart-rate auto-measure config (`0x16`).
///
/// Per `PROTOCOL.md` §4.3 the read response carries:
///   `pl[1]` = enabled (1 = on, 2 = off)
///   `pl[2]` = interval (minutes between auto-measures)
///   `pl[3]` = startInterval (minutes after midnight to start)
///   `pl[4]` = tooLow (bpm threshold for low alarm)
///   `pl[5]` = tooHigh (bpm threshold for high alarm)
class HeartRateSetting {
  const HeartRateSetting({
    required this.enabled,
    required this.interval,
    this.startInterval = 0,
    this.tooLow = 50,
    this.tooHigh = 180,
  });

  final bool enabled;
  final int interval;
  final int startInterval;
  final int tooLow;
  final int tooHigh;
}

/// Header frame of a `0x39` HRV history read (`pl[2] == 0x1E`).
/// [slotId] echoes `req[1]` (today = 0, yesterday = 1, ...).
/// See `GHIDRA_DECOMPILATION.md` §3.21.
class HrvSettingHeader {
  const HrvSettingHeader({required this.slotId});
  final int slotId;
}

/// Payload chunk of a `0x39` HRV history read (frames 2..N of
/// the two-phase response). Each chunk carries up to 13 bytes of
/// the 49-byte HRV record (`slotId + 48 samples`) after the wire
/// sequence byte is stripped. There is no end-of-message marker —
/// consumers reassemble by waiting for a quiet period after the header.
class HrvSettingChunk {
  const HrvSettingChunk({required this.payload});
  final Uint8List payload;
}

/// `sugarLipidsSetting` (`0x3a`) read/write response. A two-bit-per-feature
/// config pair (sugar = bit 5, lipids = bit 7 of the shared config byte at
/// `DAT_008277f0 + 0x2D`) packed into a single Channel-A opcode.
///
/// Per `GHIDRA_DECOMPILATION.md` §3.22 (`FUN_0082cc1e`) the response is:
///   * **read** (`req[1]` = 0x03 or 0x04, `req[2]` = 0x01) — built fresh on
///     the stack: `[0x3A, sub, 0x01, featureValue, 0…0, cksum]`.
///   * **write** — the two features use **different** ack shapes:
///     - sugar (`0x03 0x02`) echoes the 16-byte request unchanged
///     - lipids (`0x04 0x02`) sends a 1-byte-cmd ack
///       `[0x3A, 0, 0, 0, 0…0, cksum]`
///     The `writeAcksEcho` flag lets the host tell these two shapes apart
///     without keeping outbound-context state.
class SugarLipidsSetting {
  const SugarLipidsSetting({
    required this.sub,
    required this.featureValue,
    required this.writeAcksEcho,
  });

  /// Sub-opcode echo from `pl[0]`: `0x03` = sugar, `0x04` = lipids.
  final int sub;

  /// Feature value at `pl[2]`. For a read this is the live `0/1` bit; for a
  /// write ack that *echoes the request*, this is the value the watch just
  /// committed (echoed from `req[3]`). For a lipids 1-byte-cmd ack the
  /// decoder surfaces `0` (the firmware zeros out the whole response).
  final int featureValue;

  /// `true` when this is a sugar-write ack (the request frame echoed back
  /// unchanged — `pl[1] == 0x02` and the rest of the bytes mirror the
  /// outbound frame). `false` for read responses and for the lipids 1-byte
  /// ack. See `GHIDRA_DECOMPILATION.md` §3.22 for the asymmetric write
  /// semantics.
  final bool writeAcksEcho;
}

/// UV / touch-screen control-byte response (`0x3b`).
///
/// Per `GHIDRA_DECOMPILATION.md` §3.18 the response is mostly an
/// echo of the request — only [configByte] carries the actual
/// value (read OR echoed `req[3]`). [batchMode] reflects
/// `req[1]` (the host's "don't commit" flag).
class UvTouchSetting {
  const UvTouchSetting({
    required this.sub,
    required this.configByte,
    required this.batchMode,
  });

  /// Sub-opcode echo (0x01 read / 0x02 write).
  final int sub;

  /// 1-byte UV/touch control value. For the `0x01` read path this
  /// is the current config byte from `DAT_0082cfe8 + 8`; for
  /// write paths this echoes `req[3]`.
  final int configByte;

  /// `true` when `req[1] != 0` (host asked the watch not to
  /// commit, e.g. for a multi-frame batched write).
  final bool batchMode;
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

/// One clock-alarm slot (`0x24` read response).
///
/// `weekdays[0]` is Sunday (Sun..Sat order matches the wire
/// `day0..day6` from `PROTOCOL.md` §4.3).
class Alarm {
  const Alarm({
    required this.slot,
    required this.enabled,
    required this.hour,
    required this.minute,
    this.weekdays = const [false, false, false, false, false, false, false],
  });

  /// Firmware slot index `0..4` (clock alarms).
  final int slot;

  /// Whether the alarm is armed.
  final bool enabled;

  /// 24-hour hour, `0..23`.
  final int hour;

  /// Minute, `0..59`.
  final int minute;

  /// `weekdays[i] == true` means "fire on day i", Sun..Sat.
  final List<bool> weekdays;

  /// Packed bitmask (`Σ(weekdays[i] << i)`).
  int get weekMask {
    var m = 0;
    for (var i = 0; i < weekdays.length && i < 7; i++) {
      if (weekdays[i]) m |= 1 << i;
    }
    return m;
  }

  /// `true` if any weekday is selected.
  bool get repeats => weekdays.any((d) => d);

  /// `HH:MM` 24-hour formatted time.
  String get labelTime {
    final hh = hour.toString().padLeft(2, '0');
    final mm = minute.toString().padLeft(2, '0');
    return '$hh:$mm';
  }

  Alarm copyWith({
    int? slot,
    bool? enabled,
    int? hour,
    int? minute,
    List<bool>? weekdays,
  }) => Alarm(
    slot: slot ?? this.slot,
    enabled: enabled ?? this.enabled,
    hour: hour ?? this.hour,
    minute: minute ?? this.minute,
    weekdays: weekdays ?? this.weekdays,
  );

  @override
  bool operator ==(Object other) =>
      other is Alarm &&
      other.slot == slot &&
      other.enabled == enabled &&
      other.hour == hour &&
      other.minute == minute &&
      _listEq(other.weekdays, weekdays);

  @override
  int get hashCode =>
      Object.hash(slot, enabled, hour, minute, Object.hashAll(weekdays));

  static bool _listEq(List<bool> a, List<bool> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}

/// Activity totals from `0x48 todaySport`.
///
/// Payload layout follows `PROTOCOL.md` §4.4: five big-endian groups where
/// the first four are 24-bit counters and the final duration is 16-bit.
class SportTotals {
  const SportTotals({
    required this.steps,
    required this.running,
    required this.calories,
    required this.distanceMeters,
    required this.durationSeconds,
  });

  final int steps;
  final int running;
  final int calories;
  final int distanceMeters;
  final int durationSeconds;

  static SportTotals? tryParse(Uint8List pl) {
    if (pl.length < 12) return null;
    final rawCalories = Codec.readU24be(pl, 6);
    return SportTotals(
      steps: Codec.readU24be(pl, 0),
      running: Codec.readU24be(pl, 3),
      calories: _normalizeCalories(rawCalories),
      distanceMeters: Codec.readU24be(pl, 9),
      durationSeconds: pl.length >= 14 ? ((pl[12] << 8) | pl[13]) : 0,
    );
  }

  static int _normalizeCalories(int rawCalories) {
    const maxSaneKcal = 20000;
    if (rawCalories <= maxSaneKcal) return rawCalories;
    // Live H59MA captures show this 24-bit field as small calories while the
    // app stores and displays food calories (kcal): e.g. 265301 -> 265 kcal.
    return (rawCalories / 1000).round();
  }
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

/// One raw `0x72` frame as emitted on the wire — see
/// [ChannelADispatcher.onPushMsgChunk] and `GHIDRA_DECOMPILATION.md` §3.3.
///
/// [seq] is a 0-based monotonic counter assigned by the dispatcher so
/// subscribers can sort and reassemble without trusting wall-clock
/// arrival order (BLE link retransmits can otherwise invert ordering).
class PushMsgChunk {
  const PushMsgChunk({required this.seq, required this.payload});
  final int seq;
  final Uint8List payload;
}

/// Buffers [PushMsgChunk]s emitted on a `0x72` stream and emits one
/// [PushMsgUint] per message. Flushes when either:
///
///   * the §3.3 flush marker pair `pl[1] == pl[2]` fires (the firmware
///     uses this same guard — `FUN_00829e92` only renders when the two
///     bytes match), **or**
///   * a [quietWindow] of silence elapses with no new chunk (default
///     250 ms — long enough to span a typical ~100 ms BLE link
///     retransmit burst, short enough that the UI sees the notification
///     within a perceptible frame).
///
/// Single-frame pushes (the most common case from the watch's
/// notification bridge) flush on the very first chunk with no timer
/// delay, so [isFirstFrame] stays accurate and the legacy single-frame
/// shortcut on [ChannelADispatcher.onPushMsg] can fire in lock-step.
class PushMsgReassembler {
  PushMsgReassembler({Duration quietWindow = const Duration(milliseconds: 250)})
    : _quietWindow = quietWindow,
      _isFirstFrame = true;

  /// Defaults match the §3.3 buffer shape (133-byte `text[0x85]`).
  static const int _maxBufferBytes = 133;

  final Duration _quietWindow;
  bool _isFirstFrame;

  /// True exactly once — on the first [push] call after the last flush.
  /// After that, callers should wait for the assembled [PushMsgUint].
  bool get isFirstFrame => _isFirstFrame;

  int? _type;
  final List<int> _buf = [];
  Timer? _timer;
  int? _nextSeq;

  /// Feed a chunk. Returns `true` if the chunk completed a message and
  /// the assembled [PushMsgUint] was emitted on [out].
  bool push(int seq, Uint8List pl, StreamController<PushMsgUint> out) {
    // First frame after flush — record type + initialize buffer.
    if (_isFirstFrame) {
      _isFirstFrame = false;
      _type = pl.isNotEmpty ? pl[0] : 0;
      _buf.clear();
      _nextSeq = seq + 1;
    } else if (_nextSeq != seq) {
      // Out-of-order chunk (rare; only on a flaky link). Reset state so
      // we never concatenate garbled bytes from a different message.
      _reset();
      _isFirstFrame = false;
      _type = pl.isNotEmpty ? pl[0] : 0;
      _nextSeq = seq + 1;
    } else {
      _nextSeq = seq + 1;
    }

    // §3.3 frame layout: [type, flushLo, flushHi, payload…]. Bytes 1..n
    // are the chunk's UTF-8 payload; the flush-marker pair is at [1..2].
    //
    // Legacy single-frame pushes predate §3.3 and arrive as a 2-byte
    // payload `[type, ...content]` — the dispatcher cannot distinguish
    // them from a §3.3 frame mid-stream, but it CAN tell that a frame
    // this short has no room for both a flush-marker pair *and* a
    // payload, so we treat it as a complete single-frame message and
    // emit immediately. This keeps the legacy wire shape working
    // without paying the 250 ms quiet-window latency.
    final isLegacyShort = pl.length < 3;
    final start = pl.length >= 3 ? 3 : 1;
    final flush = !isLegacyShort && pl[1] == pl[2];
    for (var i = start; i < pl.length; i++) {
      if (_buf.length >= _maxBufferBytes) break; // hard cap matches firmware.
      _buf.add(pl[i]);
    }

    if (isLegacyShort || flush) {
      _emit(out);
      return true;
    }
    // Reset the quiet-window timer.
    _timer?.cancel();
    _timer = Timer(_quietWindow, () {
      if (_buf.isEmpty) return;
      _emit(out);
    });
    return false;
  }

  /// Stop the pending quiet-window timer. Call on link teardown to avoid
  /// leaking a [Timer] across reconnects.
  void cancel() {
    _timer?.cancel();
    _timer = null;
  }

  void _emit(StreamController<PushMsgUint> out) {
    _timer?.cancel();
    _timer = null;
    final text = String.fromCharCodes(_buf.where((b) => b != 0));
    out.add(PushMsgUint(type: _type ?? 0, text: text));
    _reset();
  }

  void _reset() {
    _type = null;
    _buf.clear();
    _nextSeq = null;
    _isFirstFrame = true;
  }
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

/// `MenstruationDataRsp` (0x2b): 16-byte Channel-A notify frame carrying the
/// user's menstrual-cycle configuration plus a phase hint used by the
/// firmware UI.
///
/// The wire shape (verified against H59MA v14 — see
/// `GHIDRA_DECOMPILATION.md` §3.1 / §3.1.1, `FUN_0082b078` lazy-init +
/// `FUN_0082af28` read-memcpy + `FUN_0082aee4` write) is:
///
/// | byte | meaning                                                                       |
/// |------|-------------------------------------------------------------------------------|
/// | 0    | presence sentinel: `0xCA` ⇒ record present; `0x00` ⇒ lazy-init zero state      |
/// | 1    | `BCD(startDate.year)`                                                         |
/// | 2    | `BCD(cycleLenDays)`                                                           |
/// | 3    | `BCD(startDate.day)` — zero here triggers the cycle-phase detector returning 3 |
/// | 4..5 | `currentDay - record[4]` u16 LE on **write**; low byte only on **read**       |
/// | 6..7 | `currentMonth - record[6]` u16 LE on **write**; low byte only on **read**      |
/// | 8..12| 5-byte opaque `periodData` blob (semantics not RE-resolvable)                 |
/// | 13..15| always-zero padding                                                           |
///
/// **Byte-0 sentinel quirk** (`FUN_0082af28`): on read the firmware overwrites
/// `rsp[0]` with `start_date_bcd[0]` *before* the copy-out, so the returned
/// frame's byte 0 is the BCD year nibble — **not** the `0xCA` sentinel. Hosts
/// that want the presence sentinel must re-stamp `rsp[0] = 0x2B` (the
/// request opcode) themselves before they can use the lazy-init-zero
/// detection below. [tryParse] expects a 15-byte body that has already had
/// the cmd byte stripped (i.e. the same shape that
/// [ChannelADispatcher._decodeMenstruation] feeds into `payload`).
class MenstruationMixture {
  const MenstruationMixture({required this.sub, required this.payload});

  /// Sub-byte that echoed back the request's `req[1]` selector (read vs
  /// write — `OpA.mixRead` / `OpA.mixWrite`).
  final int sub;

  /// Raw 15-byte body, layout as described in the class doc.
  final Uint8List payload;

  /// Presence sentinel at `payload[0]`. The firmware's lazy-init handler
  /// writes `0x00` when no record exists and `0xCA` once a write has
  /// committed a record (see `FUN_0082b078` in
  /// `GHIDRA_DECOMPILATION.md` §3.1.1).
  ///
  /// Note: on a real read (`FUN_0082af28`) the firmware overwrites this
  /// byte with `start_date_bcd[0]` before sending — so a fresh read frame
  /// will *not* show `0xCA`. Callers that want to discriminate "present"
  /// vs "lazy-init empty" should re-stamp byte 0 with `0x2B` (the
  /// request opcode) before calling [tryParse], or compare against
  /// [presenceSentinel] / 0 directly.
  static const int presenceSentinel = 0xCA;

  /// Parsed view of a 15-byte [payload] body.
  ///
  /// Returns `null` when the body length is not exactly 15 bytes or the
  /// presence sentinel at `payload[0]` is zero (lazy-init empty state).
  ///
  /// **Important**: pass the *post-strip* body — i.e. the bytes that
  /// remain after [Codec.rxPayload] has removed the cmd byte (or after
  /// [ChannelADispatcher] has produced a [MenstruationMixture] for you).
  /// The full 16-byte Channel-A frame includes the cmd byte at index 0,
  /// which would push every field offset by one.
  static MenstruationParsed? tryParse(Uint8List payload) {
    if (payload.length != 15) return null;
    if (payload[0] == 0x00) return null;
    return MenstruationParsed._(payload);
  }

  /// Convenience: try to parse [payload] (or, when called as a default
  /// constructor, the receiver's own `payload`) into a [MenstruationParsed]
  /// view. Returns `null` for the wrong-length / lazy-init-zero cases.
  MenstruationParsed? get parsed => tryParse(payload);
}

/// Parsed view of a [MenstruationMixture] body. Fields map 1:1 to the byte
/// offsets documented on [MenstruationMixture]. All accessors are total —
/// the [MenstruationMixture.tryParse] factory guarantees the underlying
/// payload is exactly 15 bytes long.
class MenstruationParsed {
  const MenstruationParsed._(this._payload);

  final Uint8List _payload;

  /// Raw view of the 15-byte body, kept around for the [periodData] blob
  /// (which has no RE-resolvable field-by-field semantics).
  Uint8List get raw => _payload;

  /// Year of the last cycle start date, decoded from BCD at `payload[1]`.
  /// Range 0..99 — callers combine this with the watch's two-digit year
  /// convention (e.g. `2000 + year` for any modern H59MA firmware).
  int get startYear => Codec.fromBcd(_payload[1]);

  /// Cycle length in days, decoded from BCD at `payload[2]`. Range 0..99.
  int get cycleLenDays => Codec.fromBcd(_payload[2]);

  /// Day-of-month of the last cycle start date, decoded from BCD at
  /// `payload[3]`. When this is zero the firmware's cycle-phase detector
  /// (`FUN_0082aee4`) returns `3 = Unset` — use that signal in a UI
  /// instead of guessing from `startDate`.
  int get startDay => Codec.fromBcd(_payload[3]);

  /// `currentDay - record[4]` offset written by `FUN_0082aee4` as a u16 LE
  /// pair (`payload[4] = low`, `payload[5] = high`). On read-back only
  /// the low byte is returned by the firmware's copy-out — callers that
  /// want the full u16 should treat it as the *write* value and clamp to
  /// 0..255 if the high byte is zero.
  int get currentDayDelta => _payload[4] | (_payload[5] << 8);

  /// `currentMonth - record[6]` offset written by `FUN_0082aee4` as a u16
  /// LE pair. Same low-byte-only-on-read caveat as [currentDayDelta].
  int get currentMonthDelta => _payload[6] | (_payload[7] << 8);

  /// 5-byte opaque `periodData` blob (`payload[8..12]`). The RE notes do
  /// not resolve per-byte semantics; expose the raw bytes so callers
  /// can decide how to surface them (or log+ignore) without us
  /// over-promising on the layout.
  Uint8List get periodData => Uint8List.sublistView(_payload, 8, 13);
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

/// `queryDataDistribution` (`0x46`) bitmask response. The watch
/// reports a 32-bit big-endian bitmask: bit *d* set ⇒ day *d*
/// (counted from today backward) has stored health data. The
/// raw wire byte is `0x46` for a successful reply or `0xC6`
/// (`0x46 | 0x80`) when the device is reporting a per-opcode
/// error — in that case [errorFlag] is true and [mask] is
/// best-effort (only the bytes the firmware bothered to fill
/// in are meaningful; treat the rest as zero).
///
/// See `PROTOCOL.md` §4.6 and `GHIDRA_DECOMPILATION.md` §3.13
/// for the wire format.
class QueryDataDistribution {
  const QueryDataDistribution({required this.mask, required this.errorFlag});

  /// Decode the wire payload (pl[0..13]) as a 32-bit big-endian
  /// bitmask. Best-effort when the payload is short — only the
  /// bytes the firmware bothered to fill in are meaningful.
  factory QueryDataDistribution.fromPayload(
    Uint8List pl, {
    required bool errorFlag,
  }) {
    final n = pl.length < 4 ? pl.length : 4;
    var mask = 0;
    for (var i = 0; i < n; i++) {
      mask = (mask << 8) | (pl[i] & 0xFF);
    }
    return QueryDataDistribution(mask: mask, errorFlag: errorFlag);
  }

  /// True if bit [day] is set in [mask] (i.e. the device has stored
  /// health data for that day, where day 0 is today).
  bool hasData(int day) => day >= 0 && day < 32 && (mask & (1 << day)) != 0;

  final int mask;
  final bool errorFlag;
}

/// Now-playing push from the watch (`0x1d`).
///
/// The `0x1d` opcode is the only entry in the persistent
/// notify-listener registry (`PROTOCOL.md` §4.1 line 194) that is
/// **not** statically resolved to a fixed payload in H59MA v14 — every
/// other entry (`0x02` InnerCamera, `0x2f` PackageLength,
/// `0x73` DeviceNotify, `0x78` DeviceSportNotify) has a documented
/// byte shape. The wire layout we decode is inferred from the
/// symmetric host→watch `executeMusicSend` command documented in
/// `PROTOCOL.md` §4.8 (line 463 — `[(playing^1), progress, volume,
/// UTF-8 name]`), so the field order is the most plausible
/// reconstruction but should be re-validated on the first live
/// capture.
///
/// The decoder ([ChannelADispatcher._decodeMusic]) drops frames
/// shorter than 4 bytes; a sub-4-byte frame cannot carry a
/// meaningful track name and is treated as wire-level corruption.
class MusicRsp {
  const MusicRsp({
    required this.isPlaying,
    required this.progress,
    required this.volume,
    required this.track,
  });

  /// `true` when the watch says the media player is playing. The wire
  /// byte is XOR-1 inverted per `PROTOCOL.md` §3.1 — the decoder
  /// un-inverts before constructing this record.
  final bool isPlaying;

  /// Playback position 0..255. Host-side UI can map this to a fraction
  /// of the track; the actual track duration is not on the wire.
  final int progress;

  /// Media volume 0..255. The watch renders this directly in the OS
  /// volume UI; hosts may show it as a percentage.
  final int volume;

  /// Best-effort UTF-8 track title (no artist/album on the wire). Empty
  /// when the watch emits a header-only frame; the dashboard uses that
  /// as the signal to hide the card rather than render a blank row.
  final String track;
}
