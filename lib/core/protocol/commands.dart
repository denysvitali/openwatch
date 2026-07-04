import 'dart:typed_data';

import 'codec.dart';
import 'opcodes.dart';

/// Builders for the Channel-A commands the device manager uses. Each returns a
/// ready-to-send 16-byte frame. Layouts follow `PROTOCOL.md` §4 exactly.
class Commands {
  Commands._();

  static const List<bool> _noWeekdays = [
    false,
    false,
    false,
    false,
    false,
    false,
    false,
  ];

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

  /// `HeartRateSettingReq` (0x16) read: `[0x01]`.
  static Uint8List readHeartRateSetting() =>
      Codec.buildChannelA(OpA.heartRateSetting, [OpA.mixRead]);

  /// `HeartRateSettingReq` (0x16) write: `[0x02, en?1:2, interval, startInterval, tooLow, tooHigh]`.
  static Uint8List setHeartRateSetting({
    required bool enabled,
    required int interval,
    int startInterval = 0,
    int tooLow = 50,
    int tooHigh = 180,
  }) => Codec.buildChannelA(OpA.heartRateSetting, [
    OpA.mixWrite,
    enabled ? 1 : 2,
    interval & 0xFF,
    startInterval & 0xFF,
    tooLow & 0xFF,
    tooHigh & 0xFF,
  ]);

  /// `BpReadConformReq` (0x0e): advance the BP record queue and
  /// emit the next record on `0x0d`. Per `GHIDRA_DECOMPILATION.md`
  /// §3.19, the handler ignores any `sub != 0` (no advance, no
  /// response). Default sub is 0 = advance + read next.
  static Uint8List advanceBpRecord({int sub = 0x00}) =>
      Codec.buildChannelA(OpA.bpReadConform, [sub & 0xFF]);

  /// NOT IMPLEMENTED in H59MA v14 firmware. Do not call this from
  /// production code — kept for spec compatibility only. See
  /// PROTOCOL.md section 4.4.
  ///
  /// `ReadTotalSportDataReq` (0x07): `[dayOffset]` (0 = today).
  static Uint8List readTotalSport({int dayOffset = 0}) =>
      Codec.buildChannelA(OpA.readTotalSport, [dayOffset & 0xFF]);

  /// `ReadDetailSport` (`0x43`): per-segment activity detail for one day.
  ///
  /// H59MA v14 request layout (PROTOCOL.md §4.4 / GHIDRA §3.6):
  ///   byte 1 = day offset (`0` today, `1` yesterday, ...)
  ///   byte 2 = sub-opcode `0x0F` (`ReadDetailSportDataReq`)
  ///   byte 3 = start segment (`0..0x5F`, 10-minute segments)
  ///   byte 4 = end segment (`0..0x5F`, ≤ start segment)
  ///   byte 5 = fixed `0x01`
  ///
  /// [startHour] and [endHour] are converted to segment indices
  /// (`hour * 6`) before being placed on the wire.
  static Uint8List readDetailSport({
    int dayOffset = 0,
    int startHour = 0,
    int endHour = 23,
  }) {
    final startSeg = _clamp(startHour * 6, 0, 0x5F);
    final endSeg = _clamp(endHour * 6, startSeg, 0x5F);
    return Codec.buildChannelA(OpA.readDetailSport, [
      dayOffset & 0xFF,
      0x0F,
      startSeg,
      endSeg,
      0x01,
    ]);
  }

  /// `QueryDataDistribution` (0x46) — the watch pushes a 32-bit bitmask where
  /// bit *d* = "day *d* has stored data". Per PROTOCOL.md §4.6 this is a
  /// **watch→phone notify only** opcode; there is no documented host→watch
  /// request. The legacy implementation sent a bare `0x46` and the firmware
  /// replied with `0xC6 ERR 0xee`, so [HistorySync.syncAll] no longer issues
  /// this frame. Callers building a frame for tests / fuzzing should use
  /// `Codec.buildChannelA(OpA.queryDataDistribution)` directly.
  @Deprecated(
    '0x46 is watch→phone notify only — no host→watch request '
    'exists. See PROTOCOL.md §4.6.',
  )
  static Uint8List queryDataDistribution() =>
      Codec.buildChannelA(OpA.queryDataDistribution);

  /// `ReadHeartRateReq` (0x15): request a stored HR record for a given day.
  ///
  /// `ReadHeartRate` (0x15): requests the 5-minute BPM history for a
  /// specific calendar day.
  ///
  /// The watch stores HR records keyed by its **local** clock's day-start
  /// epoch seconds — `setTime()` sends the host's local BCD bytes, so the
  /// firmware's day-rollover is at LOCAL midnight, not UTC. The request
  /// index must therefore be the LOCAL epoch seconds for `day.midnight`,
  /// NOT a UTC rebuild of the year/month/day components, or users in
  /// non-UTC timezones get a TZ-offset-shifted record back (e.g. UTC-12
  /// user asks for "today", watch returns yesterday, the chart shows
  /// yesterday's data anchored to today's `DateOnly` — looks like the
  /// day is "already filled" the moment it starts).
  ///
  /// * [day] — calendar day to query. Pass `DateOnly.midnight` (LOCAL
  ///   midnight) so the epoch matches what `setTime()` produced.
  /// * [slot] — optional 5-minute sample slot offset within the day.
  ///
  /// Sending `0x00000000` (all bytes zero) is the firmware's "current/latest"
  /// sentinel and bypasses the date lookup entirely — useful for a "give me
  /// whatever is freshest" probe.
  ///
  /// Multi-packet response (GHIDRA §3.12): header frame
  /// `pl[0] == 0x18`, then up to 23 chunk frames with sequence
  /// bytes `pl[0] ∈ 1..23` each carrying 13 record bytes at
  /// `pl[1..14]`. `pl[0] == 0xFF` means "no record at this index".
  /// The first u32 of the reassembled payload echoes the request
  /// index, so `HistorySync` should ignore the first 4 bytes when
  /// walking the 5-min BPM slots.
  static Uint8List readHeartRateHistory({required DateTime day, int slot = 0}) {
    final seconds = day.millisecondsSinceEpoch ~/ 1000;
    final start = seconds + (slot * 5 * 60);
    return Codec.buildChannelA(OpA.readHeartRate, Codec.u32le(start));
  }

  /// New sleep protocol (Channel-B `0x27`) for a given day offset. Sent as
  /// a framed BC/27/len/crc/payload frame; see PROTOCOL.md §4.4.
  ///
  /// The firmware handler `FUN_0082fada` (GHIDRA §2.3) expects a 2-byte
  /// payload: `[dayOffset, recordType]` where `recordType = 0x00` selects the
  /// night sleep pass. `dayOffset` is clamped to `0..6` per the spec.
  static Uint8List readSleepNewProtocol({int dayOffset = 0}) =>
      Codec.buildChannelB(OpB.sleepNew, [_clamp(dayOffset, 0, 6), 0x00]);

  /// New sleep protocol lunch/nap variant (Channel-B `0x3e`) for a given
  /// day offset. The firmware handler `FUN_0082fada` (GHIDRA §2.3) expects
  /// a 2-byte payload: `[dayOffset, recordType]` where `recordType = 0x01`
  /// selects the lunch/nap pass (`param_2 == 1`). `dayOffset` is clamped
  /// to `0..6` per the spec.
  static Uint8List readSleepLunchProtocol({int dayOffset = 0}) =>
      Codec.buildChannelB(OpB.sleepLunchNew, [_clamp(dayOffset, 0, 6), 0x01]);

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

  /// `PressureReq` / stress history (`0x37`): request the fixed-slot
  /// stress record for [dayOffset] (`0` = today).
  static Uint8List readStressHistory({int dayOffset = 0}) =>
      Codec.buildChannelA(OpA.pressure, [dayOffset & 0xFF]);

  /// `HRVReq` (`0x39`): request the fixed-slot HRV record for [dayOffset]
  /// (`0` = today).
  static Uint8List readHrvHistory({int dayOffset = 0}) =>
      Codec.buildChannelA(OpA.hrv, [dayOffset & 0xFF]);

  /// `StartHeartRateReq` (0x69): start a live measurement of [type].
  static Uint8List startMeasure(MeasureType type) =>
      Codec.buildChannelA(OpA.startMeasure, [type.id, 0x01]);

  /// `StopHeartRateReq` (0x6a): stop a measurement of [type].
  static Uint8List stopMeasure(MeasureType type) =>
      Codec.buildChannelA(OpA.stopMeasure, [type.id, 0x04, 0x00]);

  /// `RealTimeHeartRate` (0x1e): sub `[action]` (1 = start, 2 = stop,
  /// 3 = reset — see `GHIDRA_DECOMPILATION.md` §3.13 / `FUN_0082d20c`).
  /// On H59MA v14 this is **fire-and-forget** — the handler never
  /// sends a response. The continuous bpm stream travels on
  /// `0x73 deviceNotify` / `0x78 deviceSportNotify`, NOT on `0x1e`
  /// (the pre-RE APK-derived assumption was wrong for v14).
  static Uint8List startContinuousHr() =>
      Codec.buildChannelA(OpA.realTimeHeartRate, [0x01]);

  /// `RealTimeHeartRate` (0x1e) with action=2: stop the continuous stream.
  static Uint8List stopContinuousHr() =>
      Codec.buildChannelA(OpA.realTimeHeartRate, [0x02]);

  /// `RealTimeHeartRate` (0x1e) with action=3: extend the 60 s window.
  static Uint8List resetContinuousHrWindow() =>
      Codec.buildChannelA(OpA.realTimeHeartRate, [0x03]);

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
  /// The enable byte follows the watch's common toggle convention:
  /// `1 = enabled`, `2 = disabled`.
  static Uint8List setAlarm({
    required int index,
    required bool enabled,
    required int hour,
    required int minute,
    List<bool> weekdays = _noWeekdays,
  }) => Codec.buildChannelA(
    OpA.setAlarm,
    _alarmSlotPayload(
      index: index & 0xFF,
      enabled: enabled,
      hour: hour,
      minute: minute,
      weekdays: weekdays,
    ),
  );

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

  // ---------------------------------------------------------------------------
  // Display / theme / wallpaper / unit settings (Channel A — `0x12..0x3f`).
  // All layouts follow `PROTOCOL.md` §4.2 exactly. The default boolean
  // encoding is the documented `1 = on, 2 = off` — see `OpA.mixWrite`.
  // ---------------------------------------------------------------------------

  /// `DeviceThemeReq` (0x3d): get or set the active UI theme id.
  ///
  /// `theme` is an opaque device-defined id (e.g. `0` = default, `1..N` =
  /// vendor themes). The read response layout is `[01, pl[1] = type]`
  /// followed by a UTF-8 name when `type == 1`.
  static Uint8List readTheme() =>
      Codec.buildChannelA(OpA.deviceTheme, [OpA.mixRead]);
  static Uint8List setTheme(int theme) =>
      Codec.buildChannelA(OpA.deviceTheme, [OpA.mixWrite, theme & 0xFF]);

  /// `DeviceWallpaperReq` (0x3f): get or set the active wallpaper id.
  /// Same shape as [readTheme]/[setTheme].
  static Uint8List readWallpaper() =>
      Codec.buildChannelA(OpA.deviceWallpaper, [OpA.mixRead]);
  static Uint8List setWallpaper(int wallpaper) => Codec.buildChannelA(
    OpA.deviceWallpaper,
    [OpA.mixWrite, wallpaper & 0xFF],
  );

  /// `DeviceAvatarReq` (0x32): query the on-device avatar canvas
  /// geometry. Bare-opcode read; response is
  /// `[screenType, widthLo, widthHi, heightLo, heightHi]` (LE).
  static Uint8List readAvatar() => Codec.buildChannelA(OpA.deviceAvatar);

  /// `DisplayClockReq` (0x12): toggle the always-on / display clock.
  /// `enabled` is a plain bool; the wire byte is `1 = on, 2 = off`.
  static Uint8List setDisplayClock({required bool enabled}) =>
      Codec.buildChannelA(OpA.displayClock, [OpA.mixWrite, enabled ? 1 : 2]);

  /// `DisplayOrientationReq` (0x29): set screen orientation /
  /// auto-rotate. When [autoRotate] is `true`, the watch chooses
  /// between portrait (`p1 = 0`) and landscape (`p1 = 1`) based on
  /// its accelerometer.
  static Uint8List setDisplayOrientation({
    required bool autoRotate,
    bool landscape = false,
  }) => Codec.buildChannelA(OpA.displayOrientation, [
    OpA.mixWrite,
    autoRotate ? 1 : 2,
    landscape ? 1 : 2,
  ]);

  /// `DisplayStyleReq` (0x2a): set the display style id. The id space
  /// is device-defined; the same ids the legacy Oudmon SDK exposes.
  static Uint8List setDisplayStyle(int style) =>
      Codec.buildChannelA(OpA.displayStyle, [OpA.mixWrite, style & 0xFF]);

  /// `DisplayTimeReq` (0x1f): screen-on duration / brightness profile
  /// (read / write / delete).
  ///
  /// The H59MA handler treats this as a Mixture sub-cmd (1=read,
  /// 2=write, 3=delete) with a small fixed-shape payload.
  /// [displayTime] and [displayType] are 1-byte fields; [alpha] is the
  /// brightness 0..255; [total] and [current] are the active index
  /// for a multi-profile dial.
  static Uint8List readDisplayTime() =>
      Codec.buildChannelA(OpA.displayTime, [OpA.mixRead]);
  static Uint8List setDisplayTime({
    required int displayTime,
    required int displayType,
    required int alpha,
    int total = 0,
    int current = 0,
  }) => Codec.buildChannelA(OpA.displayTime, [
    OpA.mixWrite,
    displayTime & 0xFF,
    displayType & 0xFF,
    alpha & 0xFF,
    0x00, // reserved (idx4 per PROTOCOL §4.2)
    total & 0xFF,
    current & 0xFF,
  ]);

  /// `DegreeSwitchReq` (0x19): temperature unit + display style.
  /// [isCelsius] is the canonical "show in C" toggle; some firmwares
  /// also gate a Fahrenheit secondary display behind the same byte.
  static Uint8List setDegreeSwitch({
    required bool enabled,
    required bool isCelsius,
  }) => Codec.buildChannelA(OpA.degreeSwitch, [
    OpA.mixWrite,
    enabled ? 1 : 2,
    isCelsius ? 1 : 2,
  ]);

  /// `TimeFormatReq` (0x0a): 12/24-hour + metric toggle. Per
  /// `PROTOCOL.md` §3.1 the `is24` boolean is **inverted** on the
  /// wire (`is24^1`), so we XOR here.
  static Uint8List setTimeFormat({required bool is24, required bool metric}) =>
      Codec.buildChannelA(OpA.timeFormat, [
        OpA.mixWrite,
        is24 ? 0 : 1, // XOR-1
        metric ? 0 : 1, // XOR-1 (only on the $3 profile variant)
      ]);

  /// `DndReq` (0x06) write: enable/disable the do-not-disturb window.
  /// Mirrors the read response layout: `[02, en?1:2, sH, sM, eH, eM]`.
  static Uint8List setDnd({
    required bool enabled,
    required int startHour,
    required int startMinute,
    required int endHour,
    required int endMinute,
  }) => Codec.buildChannelA(OpA.dnd, [
    OpA.mixWrite,
    enabled ? 1 : 2,
    _clamp(startHour, 0, 23),
    _clamp(startMinute, 0, 59),
    _clamp(endHour, 0, 23),
    _clamp(endMinute, 0, 59),
  ]);
  static Uint8List readDnd() => Codec.buildChannelA(OpA.dnd, [OpA.mixRead]);

  /// `PalmScreenReq` (0x05) write: palm/cover gesture config.
  /// [p3] is the "always commit" flag (factory default is `true`).
  static Uint8List setPalmScreen({
    required bool enabled,
    bool p2 = false,
    bool p3 = true,
  }) => Codec.buildChannelA(OpA.palmScreen, [
    OpA.mixWrite,
    enabled ? 1 : 2,
    p2 ? 1 : 2,
    (p2 ? 1 : 2) | (p3 ? 4 : 0),
  ]);

  /// `IntellReq` (0x09) write: smart-feature toggle + delay (seconds).
  static Uint8List setIntell({required bool enabled, int delaySeconds = 5}) =>
      Codec.buildChannelA(OpA.intell, [
        OpA.mixWrite,
        enabled ? 1 : 2,
        delaySeconds & 0xFF,
      ]);

  // ---------------------------------------------------------------------------
  // Targets (0x21) — daily step / calorie / distance / sport / sleep goals.
  // 24-bit LE for s/c/d; 16-bit LE for sport/sleep minutes.
  // ---------------------------------------------------------------------------

  /// `TargetSettingReq` (0x21) read: query the current daily goals.
  static Uint8List readTarget() =>
      Codec.buildChannelA(OpA.targetSetting, [OpA.mixRead]);

  /// `TargetSettingReq` (0x21) write: 24-bit LE step/calorie/distance.
  /// The watch echoes the request back on success.
  static Uint8List setTarget({
    required int steps,
    required int calories,
    required int distanceMeters,
  }) => Codec.buildChannelA(OpA.targetSetting, [
    OpA.mixWrite,
    ...Codec.u24le(steps),
    ...Codec.u24le(calories),
    ...Codec.u24le(distanceMeters),
  ]);

  // ---------------------------------------------------------------------------
  // Phone-side sport / GPS sync (0x74, 0x77).
  // ---------------------------------------------------------------------------

  /// `PhoneSportReq` (0x77): tell the watch the phone's app-side
  /// sport status. [sportType] is the legacy Oudmon sport-id enum
  /// (`0 = idle, 1 = running, 2 = cycling, ...`).
  static Uint8List phoneSport({required int status, required int sportType}) =>
      Codec.buildChannelA(OpA.phoneSport, [status & 0xFF, sportType & 0xFF]);

  /// `PhoneGpsReq` (0x74) gps sync request: `[status, 0x00]`.
  static Uint8List phoneGpsStatus(int status) =>
      Codec.buildChannelA(OpA.phoneGps, [status & 0xFF, 0x00]);

  /// `PhoneGpsReq` (0x74) phone data push: `[0x05, 0x00] + dist LE u32 +
  /// cal LE u32` (the protocol packs 4-byte LE fields per §3.1).
  static Uint8List phoneGpsData({
    required int distanceMeters,
    required int calories,
  }) => Codec.buildChannelA(OpA.phoneGps, [
    0x05,
    0x00,
    ...Codec.u32le(distanceMeters),
    ...Codec.u32le(calories),
  ]);

  // ---------------------------------------------------------------------------
  // Daily history (Channel A read only — 0x13 / 0x14 / 0x15 / 0x37 / 0x39).
  // ---------------------------------------------------------------------------

  /// `ReadBandSportReq` (0x13): one stored exercise session,
  /// identified by 32-bit LE start timestamp.
  static Uint8List readBandSport(DateTime startUtc) => Codec.buildChannelA(
    OpA.readBandSport,
    Codec.u32le(startUtc.toUtc().millisecondsSinceEpoch ~/ 1000),
  );

  /// `ReadPressureReq` (0x14): historical BLE-pressure measured
  /// values. `[ts u32 LE, 0x00, 0x32]` — the last byte is the
  /// protocol-defined page-size hint (50 records max).
  static Uint8List readPressureHistory(DateTime startUtc) =>
      Codec.buildChannelA(OpA.readPressure, [
        ...Codec.u32le(startUtc.toUtc().millisecondsSinceEpoch ~/ 1000),
        0x00,
        0x32,
      ]);

  /// `UltraVioletReq` (0x7d): historical UV-index samples for
  /// [dayOffset] (0 = today, 1 = yesterday, ...).
  static Uint8List readUvHistory({int dayOffset = 0}) =>
      Codec.buildChannelA(OpA.ultraViolet, [dayOffset & 0xFF]);

  /// `BpReadConformReq` (0x0e): advance the BP record queue.
  /// Sub-byte 0 = next record; 0xFF = fail. See [advanceBpRecord].
  static Uint8List ackBpRecord({bool ok = true}) =>
      Codec.buildChannelA(OpA.bpReadConform, [ok ? 0x00 : 0xFF]);

  // ---------------------------------------------------------------------------
  // Settings (0x2c / 0x38 / 0x3e — feature enable bits).
  // ---------------------------------------------------------------------------

  /// `BloodOxygenSettingReq` (0x2c) write: enable the SpO2
  /// auto-measure. The handler stores the bit at `DAT_0082d1c2`
  /// (see `GHIDRA_DECOMPILATION.md` §3.10).
  static Uint8List setBloodOxygenSetting({required bool enabled}) =>
      Codec.buildChannelA(OpA.bloodOxygenSetting, [
        OpA.mixWrite,
        enabled ? 1 : 0,
      ]);
  static Uint8List readBloodOxygenSetting() =>
      Codec.buildChannelA(OpA.bloodOxygenSetting, [OpA.mixRead]);

  /// `HrvSettingReq` (0x38) write: HRV auto-measure toggle + interval.
  static Uint8List setHrvSetting({
    required bool enabled,
    int intervalMinutes = 30,
  }) => Codec.buildChannelA(OpA.hrvSetting, [
    OpA.mixWrite,
    enabled ? 1 : 0,
    intervalMinutes & 0xFF,
  ]);
  static Uint8List readHrvSetting() =>
      Codec.buildChannelA(OpA.hrvSetting, [OpA.mixRead]);

  /// `PressureSettingReq` (0x36) write: stress (pressure) auto-measure.
  static Uint8List setPressureSetting({required bool enabled}) =>
      Codec.buildChannelA(OpA.pressureSetting, [OpA.mixWrite, enabled ? 1 : 0]);
  static Uint8List readPressureSetting() =>
      Codec.buildChannelA(OpA.pressureSetting, [OpA.mixRead]);

  /// `UVSettingReq` (0x3e) write: UV auto-measure toggle.
  static Uint8List setUvSetting({required bool enabled}) =>
      Codec.buildChannelA(OpA.uvSetting, [OpA.mixWrite, enabled ? 1 : 0]);
  static Uint8List readUvSetting() =>
      Codec.buildChannelA(OpA.uvSetting, [OpA.mixRead]);

  // ---------------------------------------------------------------------------
  // BP / DND / SitLong / Drink-alarm setters — full Mixture write path.
  // ---------------------------------------------------------------------------

  /// `BpSettingReq` (0x0c) write: configure the BP auto-measure window
  /// and "multiple" (samples per window). [multiple] must be `1`, `2`,
  /// or `3` per the legacy Oudmon SDK.
  static Uint8List setBpSetting({
    required bool enabled,
    required int startHour,
    required int startMinute,
    required int endHour,
    required int endMinute,
    int multiple = 1,
  }) => Codec.buildChannelA(OpA.bpSetting, [
    OpA.mixWrite,
    enabled ? 1 : 0,
    _clamp(startHour, 0, 23),
    _clamp(startMinute, 0, 59),
    _clamp(endHour, 0, 23),
    _clamp(endMinute, 0, 59),
    _clamp(multiple, 1, 3),
  ]);
  static Uint8List readBpSetting() =>
      Codec.buildChannelA(OpA.bpSetting, [OpA.mixRead]);

  /// `SetSitLongReq` (0x25): sedentary reminder window. BCD time
  /// fields + a 7-bit weekday mask + a cycle byte. The protocol
  /// clamps the cycle to {30, 60, 90} s; anything else falls back to
  /// 30 s in the firmware.
  static Uint8List setSitLong({
    required bool enabled,
    required int startHour,
    required int startMinute,
    required int endHour,
    required int endMinute,
    int weekMask = 0,
    int cycleSeconds = 30,
  }) {
    final c = (cycleSeconds == 60 || cycleSeconds == 90) ? cycleSeconds : 30;
    return Codec.buildChannelA(OpA.setSitLong, [
      Codec.toBcd(_clamp(startHour, 0, 23)),
      Codec.toBcd(_clamp(startMinute, 0, 59)),
      Codec.toBcd(_clamp(endHour, 0, 23)),
      Codec.toBcd(_clamp(endMinute, 0, 59)),
      weekMask & 0x7F,
      c,
    ]);
  }

  /// `SetDrinkAlarmReq` (0x27): drink/sedentary reminder slot.
  /// Same 11-byte layout as [setAlarm] but with an extended index
  /// range (0..7). ⚠ Channel-B sleep also uses cmd `0x27` —
  /// this builder targets the Channel-A alarm path.
  static Uint8List setDrinkAlarm({
    required int index,
    required bool enabled,
    required int hour,
    required int minute,
    List<bool> weekdays = _noWeekdays,
  }) => Codec.buildChannelA(
    OpA.setDrinkAlarm,
    _alarmSlotPayload(
      index: _clamp(index, 0, 7),
      enabled: enabled,
      hour: hour,
      minute: minute,
      weekdays: weekdays,
    ),
  );

  static Uint8List readDrinkAlarm(int index) =>
      Codec.buildChannelA(OpA.readDrinkAlarm, [_clamp(index, 0, 7)]);

  static List<int> _alarmSlotPayload({
    required int index,
    required bool enabled,
    required int hour,
    required int minute,
    required List<bool> weekdays,
  }) => [
    index,
    enabled ? 1 : 2,
    Codec.toBcd(hour),
    Codec.toBcd(minute),
    for (var i = 0; i < 7; i++) (i < weekdays.length && weekdays[i]) ? 1 : 0,
  ];

  // ---------------------------------------------------------------------------
  // Channel-B helpers — DIY watch face and other LargeData actions.
  // ---------------------------------------------------------------------------

  /// `readCustomWatch` (0x3a, action `0x01`): read the current
  /// DIY watch-face definition. See `PROTOCOL.md` §4.7 / §5.2.
  /// Response is dispatched to `respMap[0x3a]` and contains
  /// `N × {type, x u16 LE, y u16 LE, R, G, B}` elements.
  static Uint8List readCustomWatchFace() =>
      Codec.buildChannelB(OpB.customWatchFace, [0x01]);

  /// `writeCustomWatch` (0x3a, action `0x02`): upload a DIY
  /// watch-face definition. Each element is 8 bytes:
  ///   `[type, x u16 LE, y u16 LE, R, G, B]`.
  ///
  /// [elements] is a list of (type, x, y, r, g, b) tuples. The
  /// firmware caps the count at 32; longer lists are silently
  /// truncated by the Oudmon SDK.
  static Uint8List writeCustomWatchFace(
    List<({int type, int x, int y, int r, int g, int b})> elements,
  ) {
    final body = <int>[0x02];
    for (final e in elements.take(32)) {
      body.add(e.type & 0xFF);
      body.addAll(Codec.u16le(e.x));
      body.addAll(Codec.u16le(e.y));
      body.add(e.r & 0xFF);
      body.add(e.g & 0xFF);
      body.add(e.b & 0xFF);
    }
    return Codec.buildChannelB(OpB.customWatchFace, body);
  }

  // ---------------------------------------------------------------------------
  // Channel-B device-info / config TLVs (0x5a — H59MA v14 only).
  // ---------------------------------------------------------------------------

  /// `DeviceInfoConfig` sub-cmd `0x01`: query enabled TLV slots.
  ///
  /// Response payload begins with `[0x01, 0x01, count, ...tlvs]` where each
  /// TLV is `[id, len, data...]`. See `PROTOCOL.md` §4.8 and
  /// `GHIDRA_DECOMPILATION.md` §2.7.
  static Uint8List deviceInfoQuery() =>
      Codec.buildChannelB(OpB.deviceInfoConfig, [0x01]);

  /// `DeviceInfoConfig` sub-cmd `0x02`: write one or more TLV slots and
  /// commit the settings blob0.
  ///
  /// Each entry is encoded as `[id, len, data...]`; the on-wire body is
  /// `[0x02, count, ...encoded]`. The handler is commit-only — there is no
  /// visible response payload, so callers must not wait for a reply.
  ///
  /// Maximum lengths per id (per `GHIDRA_DECOMPILATION.md` §2.7):
  /// `1` 0x18 (name prefix), `2` 6 (BLE addr), `3` 0x14, `4` 0x10,
  /// `5` 0x10, `6` 0x08, `7` 1 (name-format control byte). The writer
  /// does not visibly clamp — callers must enforce.
  static Uint8List deviceInfoWrite(List<({int id, List<int> data})> entries) {
    final body = <int>[0x02, entries.length & 0xFF];
    for (final e in entries) {
      body.add(e.id & 0xFF);
      body.add(e.data.length & 0xFF);
      body.addAll(e.data);
    }
    return Codec.buildChannelB(OpB.deviceInfoConfig, body);
  }

  /// `DeviceInfoConfig` sub-cmd `0x04`: clear blob0 device-info / config
  /// slots and commit settings blob0. See `PROTOCOL.md` §4.8.
  static Uint8List deviceInfoClear() =>
      Codec.buildChannelB(OpB.deviceInfoConfig, [0x04]);

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

  /// Resolves a wire-level measurement type id, or `null` if unknown.
  static MeasureType? fromId(int id) {
    for (final t in values) {
      if (t.id == id) return t;
    }
    return null;
  }
}
