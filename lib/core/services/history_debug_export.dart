import 'history_sync.dart';

/// Render a single [DailyHistory] as a compact, human-readable plain-text
/// "debug package" that fits in a chat paste (<10 kB for a typical day).
///
/// Designed so users can paste one day into a bug report without sharing
/// screenshots — covers HR samples, sleep segments, stress / HRV / BP
/// scalars, day totals, and any available context (firmware / device /
/// sync watermark) the caller wants to attach.
///
/// The output is stable and round-trippable by humans (key=value, one
/// record per line, blank line between sections) — no JSON, no quotes
/// unless the value contains a space. The format is *not* parsed by the
/// app anywhere; treat it as a one-way serialisation aimed at humans.
class HistoryDebugExport {
  HistoryDebugExport._();

  /// Optional context the formatter folds into the header so the
  /// recipient can correlate the day with watch state.
  static String formatDay(DailyHistory day, {HistoryDebugContext? context}) {
    final b = StringBuffer();
    final generated = DateTime.now();
    b.writeln('# openwatch-day-debug');
    b.writeln('schema=1');
    b.writeln('day=${day.day.iso}');
    b.writeln('generated=${_iso(generated)}');
    b.writeln('tz=${context?.tzOffset ?? _localTzOffset()}');
    if (context != null) {
      final firmware = context.firmware;
      if (firmware != null) b.writeln('firmware=$firmware');
      if (context.hardware != null) b.writeln('hardware=${context.hardware}');
      if (context.linkState != null) b.writeln('link=${context.linkState}');
      if (context.lastSyncedAt != null) {
        b.writeln('last_synced=${_iso(context.lastSyncedAt!)}');
      }
      if (context.lastSyncedDayIso != null) {
        b.writeln('last_synced_day=${context.lastSyncedDayIso}');
      }
      if (context.fetched) b.writeln('freshly_fetched=true');
    }
    b.writeln();

    // The watch stores a fixed 288-slot 24h record per day; on a freshly-
    // started day the raw list contains "future" timestamps the watch
    // hasn't measured yet, plus duplicate-per-slot entries from earlier
    // sync runs that anchored on different byte offsets. Snap to the
    // 5-min slot grid (HH:MM:00 LOCAL), keep the latest sample per slot,
    // and clip anything > now so the exported text reflects what the user
    // can plausibly have measured.
    final clippedHr = _clipAndDedupeHr(day.hr, generated);
    final clippedStress = _clipScalar(day.stress, generated);
    final clippedHrv = _clipScalar(day.hrv, generated);
    final clippedBp = _clipBp(day.bloodPressure, generated);

    _writeHr(b, clippedHr);
    _writeSleep(b, day.sleep);
    _writeStress(b, clippedStress);
    _writeHrv(b, clippedHrv);
    _writeBp(b, clippedBp);
    _writeTotals(b, day);
    return b.toString();
  }

  // -- sections -----------------------------------------------------------

  static void _writeHr(StringBuffer b, List<HrSample> samples) {
    b.writeln('## hr (${_hrSlotCount()} slots, ${samples.length} samples)');
    if (samples.isEmpty) {
      b.writeln('(none)');
      b.writeln();
      return;
    }
    int? lo;
    int? hi;
    int sum = 0;
    for (final s in samples) {
      b.writeln('${_clock(s.timestamp)} ${s.bpm}');
      if (lo == null || s.bpm < lo) lo = s.bpm;
      if (hi == null || s.bpm > hi) hi = s.bpm;
      sum += s.bpm;
    }
    final avg = samples.isEmpty ? 0 : (sum / samples.length).round();
    b.writeln('# min=$lo max=$hi avg=$avg');
    b.writeln();
  }

  static void _writeSleep(StringBuffer b, List<SleepSegment> segs) {
    b.writeln('## sleep (${segs.length} segments)');
    if (segs.isEmpty) {
      b.writeln('(none)');
      b.writeln();
      return;
    }
    int totalMinutes = 0;
    for (final s in segs) {
      totalMinutes += s.duration.inMinutes;
      b.writeln(
        '${_clock(s.start)}-${_clock(s.start.add(s.duration))} '
        '${s.stage.name} ${_dur(s.duration)}',
      );
    }
    b.writeln('# total=${_dur(Duration(minutes: totalMinutes))}');
    b.writeln();
  }

  static void _writeStress(StringBuffer b, List<HealthMetricSample> samples) {
    _writeScalarSlots(b, 'stress', samples);
  }

  static void _writeHrv(StringBuffer b, List<HealthMetricSample> samples) {
    _writeScalarSlots(b, 'hrv', samples);
  }

  static void _writeScalarSlots(
    StringBuffer b,
    String name,
    List<HealthMetricSample> samples,
  ) {
    b.writeln('## $name (${_hrSlotCount()} slots, ${samples.length} samples)');
    if (samples.isEmpty) {
      b.writeln('(none)');
      b.writeln();
      return;
    }
    for (final s in samples) {
      b.writeln('${_clock(s.timestamp)} ${s.value}');
    }
    b.writeln();
  }

  static void _writeBp(StringBuffer b, List<BloodPressureSample> samples) {
    b.writeln('## bp (${samples.length} samples)');
    if (samples.isEmpty) {
      b.writeln('(none)');
      b.writeln();
      return;
    }
    for (final s in samples) {
      final value = _isRawBpSlot(s)
          ? 'raw-compact-slot'
          : '${s.systolic}/${s.diastolic}';
      b.writeln('${_clock(s.timestamp)} $value');
    }
    b.writeln();
  }

  static void _writeTotals(StringBuffer b, DailyHistory day) {
    b.writeln('## totals');
    if (day.steps != null) b.writeln('steps=${day.steps}');
    if (day.energyKcal != null) b.writeln('kcal=${day.energyKcal}');
    if (day.distanceMeters != null) b.writeln('dist_m=${day.distanceMeters}');
    if (day.steps == null &&
        day.energyKcal == null &&
        day.distanceMeters == null) {
      b.writeln('(none)');
    }
    if (day.lastUpdated != null) {
      b.writeln('updated=${_iso(day.lastUpdated!)}');
    }
  }

  // -- helpers ------------------------------------------------------------

  /// A day has 288 five-minute HR slots and 48 thirty-minute
  /// stress / HRV slots — keep the header annotation honest.
  static int _hrSlotCount() => 24 * 12;

  static String _clock(DateTime t) =>
      '${t.hour.toString().padLeft(2, '0')}:'
      '${t.minute.toString().padLeft(2, '0')}';

  static bool _isRawBpSlot(BloodPressureSample sample) =>
      sample.systolic == 0 && sample.diastolic == 0;

  static String _dur(Duration d) {
    final h = d.inHours;
    final m = d.inMinutes.remainder(60);
    if (h == 0) return '${m}m';
    if (m == 0) return '${h}h';
    return '${h}h${m}m';
  }

  static String _iso(DateTime t) => t.toIso8601String();

  /// `[UTC+01:00]` style offset for the host's local timezone — purely
  /// informational, the format is keyed by `day=` ISO strings which are
  /// timezone-naive by design.
  static String _localTzOffset() {
    final now = DateTime.now();
    final offset = now.timeZoneOffset;
    final sign = offset.isNegative ? '-' : '+';
    final abs = offset.abs();
    return 'UTC$sign'
        '${abs.inHours.toString().padLeft(2, '0')}:'
        '${abs.inMinutes.remainder(60).toString().padLeft(2, '0')}';
  }

  /// Snap each HR timestamp down to its 5-min slot start (HH:MM:00 LOCAL),
  /// drop samples whose slot is in the future relative to [now], and
  /// dedupe by snapped timestamp keeping the latest bpm — this collapses
  /// the per-slot 11x duplicates that accumulate when the disk holds
  /// records anchored on multiple byte offsets from earlier syncs.
  static List<HrSample> _clipAndDedupeHr(List<HrSample> samples, DateTime now) {
    final bySlot = <int, HrSample>{};
    for (final s in samples) {
      final snapped = _snapToSlot(s.timestamp);
      if (snapped.isAfter(now)) continue;
      final key = snapped.millisecondsSinceEpoch;
      final existing = bySlot[key];
      if (existing == null || s.timestamp.isAfter(existing.timestamp)) {
        bySlot[key] = HrSample(snapped, s.bpm);
      }
    }
    final out = bySlot.values.toList()
      ..sort((a, b) => a.timestamp.compareTo(b.timestamp));
    return out;
  }

  /// Drop scalar samples (stress/HRV) whose timestamp is after [now].
  static List<HealthMetricSample> _clipScalar(
    List<HealthMetricSample> samples,
    DateTime now,
  ) {
    return [
      for (final s in samples)
        if (!s.timestamp.isAfter(now)) s,
    ];
  }

  /// Drop BP samples whose timestamp is after [now].
  static List<BloodPressureSample> _clipBp(
    List<BloodPressureSample> samples,
    DateTime now,
  ) {
    return [
      for (final s in samples)
        if (!s.timestamp.isAfter(now)) s,
    ];
  }

  static DateTime _snapToSlot(DateTime t) {
    // DateOnly.midnight convention is local-midnight with zero h/m/s/ms;
    // mirror that by constructing from components so the snapped value
    // compares equal across merge keys.
    return DateTime(t.year, t.month, t.day, t.hour, (t.minute ~/ 5) * 5);
  }
}

/// Caller-supplied context the [HistoryDebugExport] folds into the
/// header so the recipient can correlate the day with watch state.
///
/// Every field is optional — the formatter degrades gracefully to a
/// day-only header when nothing is supplied.
class HistoryDebugContext {
  const HistoryDebugContext({
    this.firmware,
    this.hardware,
    this.linkState,
    this.tzOffset,
    this.lastSyncedAt,
    this.lastSyncedDayIso,
    this.fetched = false,
  });

  /// e.g. `H59MA_1.00.13_251230`.
  final String? firmware;

  /// e.g. `H59MA_V1.0`.
  final String? hardware;

  /// `ready`, `connecting`, ... (whatever the BLE state machine reports).
  final String? linkState;

  /// Already-formatted offset like `UTC+02:00`. Defaults to the host's
  /// local offset when omitted.
  final String? tzOffset;

  final DateTime? lastSyncedAt;

  final String? lastSyncedDayIso;

  /// `true` if this day was re-fetched in the most recent sync — useful
  /// when debugging "why is today empty?".
  final bool fetched;
}
