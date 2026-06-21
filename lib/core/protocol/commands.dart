import 'dart:typed_data';

import 'codec.dart';
import 'opcodes.dart';

/// Builders for the Channel-A commands the device manager uses. Each returns a
/// ready-to-send 16-byte frame. Layouts follow `PROTOCOL.md` §4 exactly.
class Commands {
  Commands._();

  /// `SetTimeReq` (0x01): `[BCD y,mo,d,h,mi,s][flags]` where `flags`:
  ///   * `0xFF` → skip the seconds-tick re-init at the end of the handler
  ///     (`FUN_0082bb4e` skips `FUN_00827956()`/`FUN_008276d2()`).
  ///   * anything else → re-arm the live counter + seconds tick.
  ///
  /// Bytes 8..14 are unused per the firmware RE (see
  /// `GHIDRA_DECOMPILATION.md` §3.4). The old APK-derived layout
  /// (`[lang][tzHalfHour+1]`) is not honoured by H59MA v14.
  ///
  /// The reply is the capability manifest, so this is also the first thing
  /// to send after `ready`.
  static Uint8List setTime(DateTime t, {int flags = 0xff}) {
    return Codec.buildChannelA(OpA.setTime, [
      Codec.toBcd(t.year % 100),
      Codec.toBcd(t.month),
      Codec.toBcd(t.day),
      Codec.toBcd(t.hour),
      Codec.toBcd(t.minute),
      Codec.toBcd(t.second),
      flags & 0xFF,
    ]);
  }

  /// `DeviceSupportReq` (0x3c): empty subData; reply is the support bitmap.
  static Uint8List deviceSupport() => Codec.buildChannelA(OpA.deviceSupport);

  /// Battery query (0x03): bare opcode; reply `BatteryRsp` = `[percent, charging]`.
  static Uint8List readBattery() => Codec.buildChannelA(OpA.battery);

  /// `FindDeviceReq` (0x50): ring/vibrate the watch (`[0x55, 0xAA]` magic).
  /// This is the legacy Channel-A path — preserved for compatibility
  /// with the original APK-derived `PROTOCOL.md`. The H59MA v14
  /// firmware uses `0x08` (see [deviceFind] and
  /// `GHIDRA_DECOMPILATION.md` §3.15) instead.
  static Uint8List findDevice() =>
      Codec.buildChannelA(OpA.findDevice, const [0x55, 0xAA]);

  /// `DeviceFindReq` (`0x08`): inline-dispatched find / cancel /
  /// long-press trigger (see `GHIDRA_DECOMPILATION.md` §3.15,
  /// `FUN_0082d2dc`). Sub-cmd layout:
  ///   `0x00`        — cancel find + reset BLE + stop motor.
  ///   `0x01`        — start find (1 s ceiling; bails if HR step
  ///                   counter is running).
  ///   `0xAB 0xDC`   — long-press magic (power-off).
  ///   any other     — set motor mode (no-op when screen-state
  ///                   byte at `DAT_0082810c - 0x3c == 2`).
  ///
  /// The handler is fire-and-forget — no response frame. Defaults
  /// to [sub = 0x01] (start find).
  static Uint8List deviceFind({int sub = 0x01, int modifier = 0x00}) {
    if (sub == 0xab) {
      // Long-press magic requires both magic bytes; caller passes
      // [sub = 0xAB, modifier = 0xDC].
      return Codec.buildChannelA(OpA.deviceFind, const [0xab, 0xdc]);
    }
    return Codec.buildChannelA(OpA.deviceFind, [sub & 0xFF, modifier & 0xFF]);
  }

  /// `FactoryResetReq` (`0xff`): triggers `FUN_0082cde8` — wipes the
  /// 164-byte user-config block at `0x00208c8c`, re-initialises the BLE
  /// stack, and arms a 1000 ms one-shot timer. The handler sends NO
  /// response frame — the host must optimistically treat the send
  /// completing as "reset accepted". See
  /// `GHIDRA_DECOMPILATION.md` §3.8.
  static Uint8List factoryReset() => Codec.buildChannelA(
    OpA.factoryReset,
    const [0x66, 0x66, 0x66], // "fff" magic
  );

  /// `RestoreKeyReq` (`0x66`): restore-key sequence (separate from the
  /// factory reset above — this is the "send restore confirm" path).
  static Uint8List restoreKey() =>
      Codec.buildChannelA(OpA.restoreKey, const [0x66]);

  /// `DeviceRebootReq` (`0xc6`): inline-dispatched reboot trigger. The
  /// sub-byte at pl[1] selects the reboot flavour; the firmware RE
  /// defines `0x6C` as the "full reboot, no in-RAM state survives" path
  /// (see `GHIDRA_DECOMPILATION.md` §3.14, `FUN_0082d2dc`). The BLE
  /// stack is torn down before any response frame can be parsed, so
  /// the host treats the loss of the link as the success indicator.
  static Uint8List deviceReboot({int sub = 0x6c}) =>
      Codec.buildChannelA(OpA.deviceReboot, [sub & 0xFF]);

  /// `BrightnessSettingsReq` (0x1b) write: `[0x02, level]`.
  static Uint8List setBrightness(int level) =>
      Codec.buildChannelA(OpA.brightness, [OpA.mixWrite, level & 0xFF]);

  /// `BpReadConformReq` (0x0e): advance the BP record queue and
  /// emit the next record on `0x0d`. Per `GHIDRA_DECOMPILATION.md`
  /// §3.19, the handler ignores any `sub != 0` (no advance, no
  /// response). Default sub is 0 = advance + read next.
  static Uint8List advanceBpRecord({int sub = 0x00}) =>
      Codec.buildChannelA(OpA.bpReadConform, [sub & 0xFF]);

  /// `ReadTotalSportDataReq` (0x07): `[dayOffset]` (0 = today).
  static Uint8List readTotalSport({int dayOffset = 0}) =>
      Codec.buildChannelA(OpA.readTotalSport, [dayOffset & 0xFF]);

  /// `ReadDetailSport` (`0x43`): per-hour activity detail for one day.
  ///
  /// H59MA v14 request layout (GHIDRA §3.6):
  ///   byte 1 = day offset (`0` today, `1` yesterday, ...)
  ///   byte 2 = reserved
  ///   byte 3 = start hour (`0..23`)
  ///   byte 4 = end hour (`0..23`)
  ///   byte 5 = unit flag (`1` = seconds, `0` = 10-second units)
  static Uint8List readDetailSport({
    int dayOffset = 0,
    int startHour = 0,
    int endHour = 23,
    bool oneSecondUnits = true,
  }) {
    final start = _clamp(startHour, 0, 23);
    final end = _clamp(endHour, start, 23);
    return Codec.buildChannelA(OpA.readDetailSport, [
      dayOffset & 0xFF,
      0x00,
      start,
      end,
      oneSecondUnits ? 1 : 0,
    ]);
  }

  /// `QueryDataDistribution` (0x46) — the watch pushes a 32-bit bitmask where
  /// bit *d* = "day *d* has stored data". Trigger a re-emit by sending the bare
  /// opcode; the response is a one-shot notify on 0x46.
  static Uint8List queryDataDistribution() =>
      Codec.buildChannelA(OpA.queryDataDistribution);

  /// `ReadHeartRateReq` (0x15): request a stored HR record for a given day.
  ///
  /// **Wire format is a packed BCD date index, NOT a unix timestamp**
  /// (see `GHIDRA_DECOMPILATION.md` §3.12, `FUN_0082cf48` +
  /// `FUN_008279c4`). The 4-byte index is laid out as
  /// `year_lo_bcd | (month_bcd << 8) | (day_bcd << 16) | (slot << 24)`,
  /// matching the byte layout of `setTime`'s BCD date bytes so the
  /// firmware's shared month-index → epoch helper can decode it
  /// without any endianness or field-width ambiguity.
  ///
  /// * [day] — calendar day the record belongs to. The handler ignores
  ///   the hour/minute/second components; only year/month/day
  ///   participate in the lookup.
  /// * [slot] — record index within that day (`0..N`); `0` is the
  ///   most-recent record. Sending `0x00000000` (all bytes zero) is
  ///   the firmware's "current/latest" sentinel and bypasses the
  ///   date lookup entirely — useful for a "give me whatever is
  ///   freshest" probe.
  ///
  /// Multi-packet response (GHIDRA §3.12): header frame
  /// `pl[0] == 0x18`, then up to 23 chunk frames with sequence
  /// bytes `pl[0] ∈ 1..23` each carrying 13 record bytes at
  /// `pl[1..14]`. `pl[0] == 0xFF` means "no record at this index".
  /// The first u32 of the reassembled payload echoes the request
  /// index, so `HistorySync` should ignore the first 4 bytes when
  /// walking the 5-min BPM slots.
  static Uint8List readHeartRateHistory({required DateTime day, int slot = 0}) {
    final yearBcd = Codec.toBcd(day.year % 100) & 0xFF;
    final monthBcd = Codec.toBcd(day.month) & 0xFF;
    final dayBcd = Codec.toBcd(day.day) & 0xFF;
    final packed =
        yearBcd | (monthBcd << 8) | (dayBcd << 16) | ((slot & 0xFF) << 24);
    return Codec.buildChannelA(OpA.readHeartRate, Codec.u32le(packed));
  }

  /// New sleep protocol (Channel-B `0x27`) for a given day offset. Sent as
  /// a framed BC/27/len/crc/payload frame; see PROTOCOL.md §4.4.
  static Uint8List readSleepNewProtocol({int dayOffset = 0}) =>
      Codec.buildChannelB(OpB.sleepNew, [dayOffset & 0xFF]);

  /// New sleep protocol lunch/nap variant (Channel-B `0x3e`) for a given
  /// day offset. Same wire shape as [readSleepNewProtocol] but the firmware
  /// reads from the lunch-sleep store via `FUN_0082fada` (GHIDRA §2.3).
  static Uint8List readSleepLunchProtocol({int dayOffset = 0}) =>
      Codec.buildChannelB(OpB.sleepLunchNew, [dayOffset & 0xFF]);

  /// Activity / sport summary (Channel-B `0x2a`) for today through
  /// [dayOffset]. The firmware clamps the offset to `2` and returns
  /// 49-byte entries (`dayOffset` + 48-byte body) for each day with data;
  /// see `GHIDRA_DECOMPILATION.md` §2.8.
  static Uint8List readActivitySummary({int dayOffset = 2}) =>
      Codec.buildChannelB(OpB.activitySummary, [_clamp(dayOffset, 0, 2)]);

  /// `TodaySportData` (0x48): read today's running step total (bare opcode).
  static Uint8List readTodaySport() => Codec.buildChannelA(OpA.todaySport);

  /// `ReadHeartRateReq` (0x15): request the **latest** HR record.
  ///
  /// Wire format is the all-zero `0x00000000` packed index — the
  /// firmware's "current/latest" sentinel (see
  /// `GHIDRA_DECOMPILATION.md` §3.12, `FUN_0082cf48`:
  /// `if (local_13c == 0) { timestamp = 0; }`). Useful when the host
  /// just wants whatever the watch last cached without caring which
  /// day it belongs to.
  static Uint8List readLatestHeartRate() =>
      Codec.buildChannelA(OpA.readHeartRate, Codec.u32le(0));

  /// `StartHeartRateReq` (0x69): start a live measurement of [type].
  static Uint8List startMeasure(MeasureType type) =>
      Codec.buildChannelA(OpA.startMeasure, [type.id, 0x01]);

  /// `StopHeartRateReq` (0x6a): stop a measurement of [type].
  static Uint8List stopMeasure(MeasureType type) =>
      Codec.buildChannelA(OpA.stopMeasure, [type.id, 0x00, 0x00]);

  /// `RealTimeHeartRate` (0x1e): sub `[type]` (1 = start, 2 = stop,
  /// 3 = reset — see `GHIDRA_DECOMPILATION.md` §3.13 / `FUN_0082d20c`).
  /// On H59MA v14 this is **fire-and-forget** — the handler never
  /// sends a response. The continuous bpm stream travels on
  /// `0x73 deviceNotify` / `0x78 deviceSportNotify`, NOT on `0x1e`
  /// (the pre-RE APK-derived assumption was wrong for v14).
  static Uint8List startContinuousHr(MeasureType type) =>
      Codec.buildChannelA(OpA.realTimeHeartRate, [type.id]);

  /// `RealTimeHeartRate` (0x1e) with type=0: stop the continuous stream.
  static Uint8List stopContinuousHr() =>
      Codec.buildChannelA(OpA.realTimeHeartRate, [0x00]);

  /// `SetANCSReq` (0x60): subscribe to (near-)all ANCS categories.
  static Uint8List enableAncs() =>
      Codec.buildChannelA(OpA.setAncs, const [0xFF, 0x9F, 0xFF, 0xFF]);

  /// `BindAncsReq` (0x04): register the phone identity for ANCS parsing.
  /// [verBucket] encodes the Android SDK level bucket (see §4.5).
  static Uint8List bindAncs(String model, {int verBucket = 0x0a}) {
    final bytes = utf8Clamp(model, 13);
    return Codec.buildChannelA(OpA.bindAncs, [
      OpA.mixWrite,
      verBucket,
      ...bytes,
    ]);
  }

  /// `ReadAlarmReq` (0x24): read clock-alarm slot [index] (0..4).
  static Uint8List readAlarm(int index) =>
      Codec.buildChannelA(OpA.readAlarm, [index & 0xFF]);

  /// `SetAlarmReq` (0x23): `[idx, enabled, hourBCD, minBCD, day0..day6]`.
  static Uint8List setAlarm({
    required int index,
    required bool enabled,
    required int hour,
    required int minute,
    List<bool> weekdays = const [
      false,
      false,
      false,
      false,
      false,
      false,
      false,
    ],
  }) {
    final days = List<int>.generate(7, (i) => (weekdays[i]) ? 1 : 0);
    return Codec.buildChannelA(OpA.setAlarm, [
      index & 0xFF,
      enabled ? 1 : 0,
      Codec.toBcd(hour),
      Codec.toBcd(minute),
      ...days,
    ]);
  }

  /// `WeatherForecastReq` (0x1a): push one day of weather.
  static Uint8List weather({
    required int index,
    required DateTime time,
    required int weatherType,
    required int minDeg,
    required int maxDeg,
    int humidity = 0,
    bool umbrella = false,
  }) => Codec.buildChannelA(OpA.weatherForecast, [
    index & 0xFF,
    ...Codec.u32le(time.toUtc().millisecondsSinceEpoch ~/ 1000),
    weatherType & 0xFF,
    minDeg & 0xFF,
    maxDeg & 0xFF,
    humidity & 0xFF,
    umbrella ? 1 : 2,
  ]);

  /// `SwitchOTARsp` trigger (0x0f): ask the device to enter OTA mode before
  /// the Channel-B DFU flow.
  static Uint8List switchToOta() => Codec.buildChannelA(OpA.switchOta);

  /// `SugarLipidsSetting` read (`0x3a`): asks the watch to read one of the
  /// two 1-bit flags packed into the shared config byte at
  /// `DAT_008277f0 + 0x2D` (sugar = bit 5, lipids = bit 7). Per
  /// `GHIDRA_DECOMPILATION.md` §3.22 the response carries
  /// `[0x3A, 0x03|0x04, 0x01, value, 0…0, cksum]`.
  ///
  /// [isLipids] selects the feature: `false` (default) reads sugar
  /// (`sub = 0x03`), `true` reads lipids (`sub = 0x04`). Sub-cmd is
  /// always `0x01` (read).
  static Uint8List readSugarLipids({bool isLipids = false}) {
    final sub = isLipids ? 0x04 : 0x03;
    return Codec.buildChannelA(OpA.sugarLipidsSetting, [sub, 0x01]);
  }

  /// `SugarLipidsSetting` write (`0x3a`): sets one of the two 1-bit flags
  /// in the shared config byte. Per `GHIDRA_DECOMPILATION.md` §3.22 the
  /// two features use **different ack shapes**:
  ///   * sugar (`sub = 0x03`) — the watch echoes the 16-byte request
  ///     frame unchanged.
  ///   * lipids (`sub = 0x04`) — the watch sends a 1-byte-cmd ack
  ///     `[0x3A, 0, 0, 0, 0…0, cksum]`.
  ///
  /// A host that wants to confirm a lipids write should follow up with
  /// [readSugarLipids](isLipids: true) — the lipids ack itself is
  /// feature-value-free.
  ///
  /// [isLipids] selects the feature (`false` → sugar / sub `0x03`,
  /// `true` → lipids / sub `0x04`); [enabled] is the bit value. Sub-cmd
  /// is always `0x02` (write).
  static Uint8List setSugarEnabled({
    required bool enabled,
    required bool isLipids,
  }) {
    final sub = isLipids ? 0x04 : 0x03;
    return Codec.buildChannelA(OpA.sugarLipidsSetting, [
      sub,
      0x02,
      enabled ? 1 : 0,
    ]);
  }

  /// Clamp a string to [max] UTF-8 bytes without splitting a code unit.
  static List<int> utf8Clamp(String s, int max) {
    final bytes = s.codeUnits.where((c) => c < 0x80).take(max).toList();
    return bytes;
  }

  static int _clamp(int value, int min, int max) {
    if (value < min) return min;
    if (value > max) return max;
    return value;
  }
}

/// Measurement session types for `StartHeartRateReq` (§4.3).
enum MeasureType {
  heartRate(1),
  bloodPressure(2),
  bloodOxygen(3),
  fatigue(4),
  healthCheck(5),
  realtimeHeartRate(6),
  ecg(7),
  pressure(8),
  bloodSugar(9),
  hrv(0x0a),
  bodyTemperature(0x0b);

  const MeasureType(this.id);
  final int id;
}
