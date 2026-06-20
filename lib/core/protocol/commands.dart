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
  static Uint8List findDevice() =>
      Codec.buildChannelA(OpA.findDevice, const [0x55, 0xAA]);

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

  /// `ReadTotalSportDataReq` (0x07): `[dayOffset]` (0 = today).
  static Uint8List readTotalSport({int dayOffset = 0}) =>
      Codec.buildChannelA(OpA.readTotalSport, [dayOffset & 0xFF]);

  /// `QueryDataDistribution` (0x46) — the watch pushes a 32-bit bitmask where
  /// bit *d* = "day *d* has stored data". Trigger a re-emit by sending the bare
  /// opcode; the response is a one-shot notify on 0x46.
  static Uint8List queryDataDistribution() =>
      Codec.buildChannelA(OpA.queryDataDistribution);

  /// `ReadHeartRateReq` (0x15): `[utcStart i32 LE]`. Multi-packet response:
  /// hdr `[0]=00`{size, range}, data `[0]=01`{ts i32 LE + samples}, `0xFF`=end.
  /// Samples are 13-byte stride (per §4.3).
  static Uint8List readHeartRateHistory(DateTime since) => Codec.buildChannelA(
    OpA.readHeartRate,
    Codec.u32le(since.toUtc().millisecondsSinceEpoch ~/ 1000),
  );

  /// New sleep protocol (Channel-B `0x27`) for a given day offset. Sent as
  /// a framed BC/27/len/crc/payload frame; see PROTOCOL.md §4.4.
  static Uint8List readSleepNewProtocol({int dayOffset = 0}) =>
      Codec.buildChannelB(OpB.sleepNew, [dayOffset & 0xFF]);

  /// `TodaySportData` (0x48): read today's running step total (bare opcode).
  static Uint8List readTodaySport() => Codec.buildChannelA(OpA.todaySport);

  /// `ReadHeartRateReq` (0x15): `[utcStart i32 LE]`.
  ///
  /// Identical wire format to [readHeartRateHistory] — kept for API stability
  /// but new callers should use [readHeartRateHistory] (the name that matches
  /// `PROTOCOL.md` §4.3).
  @Deprecated('Use readHeartRateHistory; wire format is identical.')
  static Uint8List readHeartRate(DateTime since) => Codec.buildChannelA(
    OpA.readHeartRate,
    Codec.u32le(since.toUtc().millisecondsSinceEpoch ~/ 1000),
  );

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

  /// Clamp a string to [max] UTF-8 bytes without splitting a code unit.
  static List<int> utf8Clamp(String s, int max) {
    final bytes = s.codeUnits.where((c) => c < 0x80).take(max).toList();
    return bytes;
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
