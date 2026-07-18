export '../services/history_sync.dart' show HrSample;

import 'package:flutter/foundation.dart';

/// Pure parsers for the HR-bearing Channel-A opcodes (see PROTOCOL.md §4.3
/// and `firmwares/_re/health-sensor/evidence.md`).
///
/// Kept separate from services so the wire-format logic is unit-testable
/// without a live device.
class HrParser {
  HrParser._();

  /// Inclusive range shared by every HR-bearing opcode. Anything outside is
  /// treated as "not a bpm" — a warming sensor, an end-of-stream marker, or
  /// junk padding.
  static bool isPlausibleBpm(int v) => v >= 30 && v <= 240;

  /// Firmware HR store validity band (`0x28..0xDC` = 40–220).
  static bool isFirmwareHrBand(int v) => v >= 40 && v <= 220;

  /// SpO2 percent domain used by live measure + `0x2a` history.
  static bool isPlausibleSpo2(int v) => v >= 70 && v <= 100;

  /// `RealTimeHeartRate` (0x1e): `pl[0]` is the instantaneous bpm.
  static int? parseRealtime(Uint8List pl) {
    if (pl.isEmpty) return null;
    final bpm = pl[0] & 0xFF;
    return isPlausibleBpm(bpm) ? bpm : null;
  }

  /// Live / start frames on `0x69` (payload after opcode strip).
  ///
  /// H59MA v14 layouts (`health-sensor/evidence.md` §3), indices after
  /// `Codec.rxPayload`:
  ///
  /// | Phase | pl layout |
  /// |---|---|
  /// | Start ACK | `[mode, err(0=ok/1=busy), 0…]` |
  /// | Progress (tick &lt; 0x33) | `[mode, 0, 0, …, progress_lo, progress_hi, …]` |
  /// | Value (tick ≥ 0x33) | `[mode, 0, primary, aux1, aux2, progress…]` |
  /// | Mode 6 continuous | `[0x06, stream(1\|2), bpm, …]` |
  /// | Mode 0x0C multi | `[0x0C, 0, bpm, hrv, pressure, …, temp, sys, dia]` |
  static HrStartMeasureResult? parseStartMeasureReply(Uint8List pl) {
    if (pl.length < 3) return null;
    final type = pl[0] & 0xFF;
    final b1 = pl[1] & 0xFF;
    final primary = pl[2] & 0xFF;
    final progress = _readProgress(pl);

    // Mode-6 continuous stream: [mode=6, stream_flag, bpm].
    if (type == 0x06) {
      final bpm = isPlausibleBpm(primary) ? primary : null;
      return HrStartMeasureResult(
        type: type,
        err: 0,
        value: primary,
        bpm: bpm,
        phase: b1 == 2
            ? MeasureFramePhase.settled
            : MeasureFramePhase.streaming,
        streamFlag: b1,
      );
    }

    // Busy ACK: err=1, no primary yet.
    if (b1 == 0x01 && primary == 0) {
      return HrStartMeasureResult(
        type: type,
        err: 0x01,
        value: 0,
        phase: MeasureFramePhase.ack,
      );
    }

    // Progress / accepted ACK — primary still zero.
    if (primary == 0) {
      return HrStartMeasureResult(
        type: type,
        err: b1,
        value: 0,
        phase: (progress != null && progress > 0)
            ? MeasureFramePhase.progress
            : MeasureFramePhase.ack,
        progress: progress,
      );
    }

    // Non-zero err with a primary: treat as failed session (smali path).
    if (b1 != 0) {
      return HrStartMeasureResult(
        type: type,
        err: b1,
        value: primary,
        phase: MeasureFramePhase.value,
        progress: progress,
      );
    }

    return _decodeValue(type: type, err: 0, pl: pl, progress: progress);
  }

  /// Stop / result frames on `0x6a` (payload after opcode strip).
  ///
  /// | Kind | pl layout |
  /// |---|---|
  /// | Simple | `[mode, primary, 0…]` |
  /// | Multi 0x0C | `[0x0C, 0, bpm, hrv, pressure, 0, 0, temp, sys, dia]` |
  static HrStartMeasureResult? parseStopMeasureReply(Uint8List pl) {
    if (pl.isEmpty) return null;
    final type = pl[0] & 0xFF;

    if (type == 0x0c && pl.length >= 5) {
      // Multi result uses phase-B-like packing with primary at pl[2].
      return _decodeValue(
        type: type,
        err: 0,
        pl: pl,
        progress: null,
        phase: MeasureFramePhase.finalResult,
      );
    }

    if (pl.length < 2) return null;
    final primary = pl[1] & 0xFF;
    // Synthesize a phase-B layout so mode decoding stays in one place:
    // [type, 0, primary, pl[2], pl[3], …]
    final synth = Uint8List(pl.length + 1);
    synth[0] = type;
    synth[1] = 0;
    synth[2] = primary;
    for (var i = 2; i < pl.length; i++) {
      synth[i + 1] = pl[i];
    }
    return _decodeValue(
      type: type,
      err: 0,
      pl: synth,
      progress: null,
      phase: MeasureFramePhase.finalResult,
    );
  }

  static int? _readProgress(Uint8List pl) {
    if (pl.length < 7) return null;
    return (pl[5] & 0xFF) | ((pl[6] & 0xFF) << 8);
  }

  static HrStartMeasureResult _decodeValue({
    required int type,
    required int err,
    required Uint8List pl,
    required int? progress,
    MeasureFramePhase phase = MeasureFramePhase.value,
  }) {
    final primary = pl.length > 2 ? pl[2] & 0xFF : 0;
    final aux1 = pl.length > 3 ? pl[3] & 0xFF : null;
    final aux2 = pl.length > 4 ? pl[4] & 0xFF : null;

    int? bpm;
    int? spo2;
    int? stress;
    int? hrv;
    int? sugar;
    int? temperature;
    int? systolic;
    int? diastolic;
    bool? spo2Ready;

    if (type == 0x02 || type == 0x05) {
      // BP / health-check: primary bpm + synthetic sys/dia.
      bpm = isPlausibleBpm(primary) ? primary : null;
      systolic = aux1;
      diastolic = aux2;
    } else if (type == 0x03 || type == 0x0e) {
      spo2 = isPlausibleSpo2(primary) ? primary : null;
      spo2Ready = aux1 == 1;
    } else if (type == 0x08) {
      stress = primary > 0 ? primary : null;
    } else if (type == 0x09) {
      sugar = primary > 0 ? primary : null;
    } else if (type == 0x0a) {
      hrv = primary > 0 ? primary : null;
    } else if (type == 0x0b) {
      temperature = primary > 0 ? primary : null;
    } else if (type == 0x0c) {
      bpm = isPlausibleBpm(primary) ? primary : null;
      hrv = aux1;
      stress = aux2;
      temperature = pl.length > 7 ? pl[7] & 0xFF : null;
      systolic = pl.length > 8 ? pl[8] & 0xFF : null;
      diastolic = pl.length > 9 ? pl[9] & 0xFF : null;
    } else {
      // HR and other modes that surface a bpm primary.
      bpm = isPlausibleBpm(primary) ? primary : null;
    }

    if (err != 0) {
      bpm = null;
      spo2 = null;
    }

    return HrStartMeasureResult(
      type: type,
      err: err,
      value: primary,
      bpm: bpm,
      spo2: spo2,
      spo2Ready: spo2Ready,
      stress: stress,
      hrv: hrv,
      bloodSugar: sugar,
      temperature: temperature,
      systolic: systolic,
      diastolic: diastolic,
      progress: progress,
      phase: phase,
    );
  }

  /// `deviceNotify` (0x73) / `deviceSportNotify` (0x78) carry
  /// `dataType + loadData`. Probe known offsets for a plausible bpm.
  static int? parseDeviceNotify(Uint8List pl) {
    if (pl.length < 2) return null;
    for (final off in const [1, 2, 3, 4]) {
      if (pl.length <= off) continue;
      final bpm = pl[off] & 0xFF;
      if (isPlausibleBpm(bpm)) return bpm;
    }
    return null;
  }
}

/// Which portion of a measure session a frame represents.
enum MeasureFramePhase {
  /// Start ACK (accepted or busy).
  ack,

  /// Early progress ticks (no primary value yet).
  progress,

  /// Live value ticks during the session.
  value,

  /// Mode-6 continuous streaming sample.
  streaming,

  /// Mode-6 end-of-burst / settled sample.
  settled,

  /// `0x6a` stop / final result.
  finalResult,
}

/// Parsed shape of a `0x69` live frame or `0x6a` stop frame.
@immutable
class HrStartMeasureResult {
  const HrStartMeasureResult({
    required this.type,
    required this.err,
    required this.value,
    this.bpm,
    this.spo2,
    this.spo2Ready,
    this.stress,
    this.hrv,
    this.bloodSugar,
    this.temperature,
    this.systolic,
    this.diastolic,
    this.progress,
    this.streamFlag,
    this.phase = MeasureFramePhase.value,
  });

  final int type;
  final int err;
  final int value;

  /// Heart-rate bpm when present and plausible.
  final int? bpm;

  /// SpO2 percent when mode is blood-oxygen.
  final int? spo2;

  /// Firmware "ready" flag on SpO2 value frames (`pl[3] == 1`).
  final bool? spo2Ready;

  /// Stress / pressure score.
  final int? stress;

  /// HRV score.
  final int? hrv;

  /// Synthetic blood-sugar value.
  final int? bloodSugar;

  /// Body temperature byte (stub/PRNG on H59MA v14).
  final int? temperature;

  /// Synthetic systolic (BP / multi modes).
  final int? systolic;

  /// Synthetic diastolic (BP / multi modes).
  final int? diastolic;

  /// Optional progress u16 from sensor state.
  final int? progress;

  /// Mode-6 stream flag (`1` streaming, `2` settled).
  final int? streamFlag;

  final MeasureFramePhase phase;

  /// True when this frame carries a finalisable metric value.
  bool get hasMetricValue =>
      bpm != null ||
      spo2 != null ||
      stress != null ||
      hrv != null ||
      bloodSugar != null ||
      (systolic != null && diastolic != null);
}
