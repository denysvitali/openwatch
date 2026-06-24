import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../protocol/sleep_parser.dart';
import 'app_log.dart';
import 'history_sync.dart'
    show BloodPressureSample, HealthMetricSample, HrSample;
import 'opentelemetry_service.dart';

/// One calendar day, normalised to local midnight.
///
/// `HistoryStore` keys everything by [DateOnly] — hour/minute/second are
/// always zero, so two timestamps on the same wall-clock day compare equal
/// regardless of the timezone of construction. Local-midnight is what the
/// rest of the app already uses for "today" / "yesterday" labels.
@immutable
class DateOnly implements Comparable<DateOnly> {
  const DateOnly(this.year, this.month, this.day);

  /// Wall-clock year (e.g. 2026).
  final int year;

  /// 1..12.
  final int month;

  /// 1..31.
  final int day;

  /// Construct from any [DateTime], truncating to local midnight.
  factory DateOnly.fromDateTime(DateTime dt) {
    final local = dt.toLocal();
    return DateOnly(local.year, local.month, local.day);
  }

  /// Today's [DateOnly] in the local timezone.
  factory DateOnly.today() => DateOnly.fromDateTime(DateTime.now());

  /// Returns a new [DateOnly] shifted by [days] (negative = past).
  DateOnly addDays(int days) {
    final dt = DateTime(year, month, day).add(Duration(days: days));
    return DateOnly(dt.year, dt.month, dt.day);
  }

  /// Days between two [DateOnly]s, computed in the calendar sense
  /// (midnight-to-midnight). `b - a` so `a.daysTo(b)` is positive when
  /// `b` is in the future relative to `a`.
  int daysTo(DateOnly other) {
    final a = DateTime(year, month, day);
    final b = DateTime(other.year, other.month, other.day);
    return b.difference(a).inDays;
  }

  DateTime get midnight => DateTime(year, month, day);

  /// "yyyy-mm-dd" — the file-name key used by [HistoryStore].
  String get iso => '${_pad4(year)}-${_pad2(month)}-${_pad2(day)}';

  /// Reverse of [iso]; returns null if [s] is malformed.
  static DateOnly? tryParseIso(String s) {
    final m = RegExp(r'^(\d{4})-(\d{2})-(\d{2})$').firstMatch(s);
    if (m == null) return null;
    return DateOnly(
      int.parse(m.group(1)!),
      int.parse(m.group(2)!),
      int.parse(m.group(3)!),
    );
  }

  static String _pad2(int v) => v.toString().padLeft(2, '0');
  static String _pad4(int v) => v.toString().padLeft(4, '0');

  @override
  bool operator ==(Object other) =>
      other is DateOnly &&
      other.year == year &&
      other.month == month &&
      other.day == day;

  @override
  int get hashCode => Object.hash(year, month, day);

  @override
  int compareTo(DateOnly other) {
    final c = year.compareTo(other.year);
    if (c != 0) return c;
    final m = month.compareTo(other.month);
    if (m != 0) return m;
    return day.compareTo(other.day);
  }

  @override
  String toString() => iso;
}

/// A single day's worth of locally-stored history.
///
/// All four lists are independently nullable — a freshly-paired device may
/// only ever push HR for a few days before sleep lands; the store must
/// surface what it has without fabricating missing data.
///
/// [syncedMetrics] tracks which metrics have been explicitly fetched from
/// the watch for this day, including fetches that returned no samples. This
/// lets [HistorySync] skip confirmed-empty days on subsequent syncs instead
/// of re-polling them forever. Old on-disk rows that lack this field are
/// treated as if no metric has been synced yet, so the next sync will
/// re-ask once and then mark them.
@immutable
class DailyHistory {
  const DailyHistory({
    required this.day,
    this.hr = const [],
    this.sleep = const [],
    this.stress = const [],
    this.hrv = const [],
    this.bloodPressure = const [],
    this.steps,
    this.energyKcal,
    this.distanceMeters,
    this.lastUpdated,
    this.syncedMetrics = const {},
  });

  final DateOnly day;
  final List<HrSample> hr;
  final List<SleepSegment> sleep;
  final List<HealthMetricSample> stress;
  final List<HealthMetricSample> hrv;
  final List<BloodPressureSample> bloodPressure;

  /// Today's step total (from `0x48 todaySport`). Stored alongside HR so
  /// the day-summary card doesn't have to make a second IPC round-trip.
  final int? steps;

  /// Calories for the day (from `0x48 todaySport`).
  final int? energyKcal;

  /// Distance walked, in meters (from `0x48 todaySport`).
  final int? distanceMeters;

  /// When this row was last refreshed from the watch. Null for rows that
  /// were never touched (not currently reachable but reserved).
  final DateTime? lastUpdated;

  /// Metrics that have been fetched for this day, including fetches that
  /// returned an empty sample list. Used by [HistorySync] to avoid
  /// re-polling confirmed-empty days. The set contains lowercase metric
  /// names: `'hr'`, `'stress'`, `'hrv'`, `'sleep'`, `'bp'`.
  final Set<String> syncedMetrics;

  DailyHistory copyWith({
    List<HrSample>? hr,
    List<SleepSegment>? sleep,
    List<HealthMetricSample>? stress,
    List<HealthMetricSample>? hrv,
    List<BloodPressureSample>? bloodPressure,
    int? steps,
    bool clearSteps = false,
    int? energyKcal,
    bool clearEnergyKcal = false,
    int? distanceMeters,
    bool clearDistanceMeters = false,
    DateTime? lastUpdated,
    Set<String>? syncedMetrics,
  }) => DailyHistory(
    day: day,
    hr: hr ?? this.hr,
    sleep: sleep ?? this.sleep,
    stress: stress ?? this.stress,
    hrv: hrv ?? this.hrv,
    bloodPressure: bloodPressure ?? this.bloodPressure,
    steps: clearSteps ? null : steps ?? this.steps,
    energyKcal: clearEnergyKcal ? null : energyKcal ?? this.energyKcal,
    distanceMeters: clearDistanceMeters
        ? null
        : distanceMeters ?? this.distanceMeters,
    lastUpdated: lastUpdated ?? this.lastUpdated,
    syncedMetrics: syncedMetrics ?? this.syncedMetrics,
  );

  Map<String, dynamic> toJson() => {
    'day': day.iso,
    'hr': [
      for (final h in hr)
        {'t': h.timestamp.toUtc().millisecondsSinceEpoch, 'bpm': h.bpm},
    ],
    'sleep': [
      for (final s in sleep)
        {
          'start': s.start.toUtc().millisecondsSinceEpoch,
          'dur': s.duration.inMinutes,
          'stage': s.stage.name,
        },
    ],
    'stress': [
      for (final s in stress)
        {'t': s.timestamp.toUtc().millisecondsSinceEpoch, 'v': s.value},
    ],
    'hrv': [
      for (final s in hrv)
        {'t': s.timestamp.toUtc().millisecondsSinceEpoch, 'v': s.value},
    ],
    'bp': [
      for (final b in bloodPressure)
        {
          't': b.timestamp.toUtc().millisecondsSinceEpoch,
          'sbp': b.systolic,
          'dbp': b.diastolic,
        },
    ],
    'steps': steps,
    'kcal': energyKcal,
    'dist': distanceMeters,
    'updated': lastUpdated?.toUtc().millisecondsSinceEpoch,
    'synced': syncedMetrics.toList()..sort(),
  };

  static DailyHistory fromJson(Map<String, dynamic> j) {
    final iso = j['day'] as String? ?? '';
    final parsed = DateOnly.tryParseIso(iso);
    if (parsed == null) {
      throw FormatException('DailyHistory: invalid day "$iso"');
    }
    final hrRaw = (j['hr'] as List?) ?? const [];
    final sleepRaw = (j['sleep'] as List?) ?? const [];
    final stressRaw = (j['stress'] as List?) ?? const [];
    final hrvRaw = (j['hrv'] as List?) ?? const [];
    final bpRaw = (j['bp'] as List?) ?? const [];
    final updatedRaw = j['updated'];
    // Sanitize the totals at the read boundary — old app versions
    // (before commit fd28b07 added the WRITE-time clamp in
    // `_activityTotalsFromBody`) may have persisted absurd values
    // like 6,381,923 kcal from mis-reading body[6..8] as the
    // calorie field on H59MA v13. `_upsertTotals` keeps
    // `previous.energyKcal` when the new sync reads 0, so an
    // absurd old value would survive forever otherwise. Same
    // applies to steps + distance when the firmware repacks the
    // body between builds. Out-of-range values are coerced to null
    // (= "no data") rather than 0 so the UI can distinguish.
    const kMaxSaneSteps = 200000;
    const kMaxSaneKcal = 20000;
    const kMaxSaneMeters = 200000;
    // Sleep: a day cannot meaningfully contain more than ~20 hours of
    // sleep. The H59MA v13 firmware sometimes echoes a previous day's
    // record into the current response, which the old parser filed as a
    // single block producing 24+ hour totals. Coerce those back to no
    // data on read so the bogus entries clear without a manual wipe.
    const kMaxSaneSleepMinutes = 20 * 60;
    final rawSteps = (j['steps'] as num?)?.toInt();
    final rawKcal = (j['kcal'] as num?)?.toInt();
    final rawDist = (j['dist'] as num?)?.toInt();
    final sleepSegments = [
      for (final s in sleepRaw.cast<Map>())
        SleepSegment(
          DateTime.fromMillisecondsSinceEpoch(
            (s['start'] as num).toInt(),
            isUtc: true,
          ).toLocal(),
          Duration(minutes: (s['dur'] as num).toInt()),
          _stageFromName(s['stage'] as String?),
        ),
    ];
    final sleepTotalMinutes = sleepSegments.fold(
      0,
      (a, s) => a + s.duration.inMinutes,
    );
    return DailyHistory(
      day: parsed,
      hr: [
        for (final h in hrRaw.cast<Map>())
          HrSample(
            DateTime.fromMillisecondsSinceEpoch(
              (h['t'] as num).toInt(),
              isUtc: true,
            ).toLocal(),
            (h['bpm'] as num).toInt(),
          ),
      ],
      sleep: sleepTotalMinutes > kMaxSaneSleepMinutes
          ? const <SleepSegment>[]
          : sleepSegments,
      stress: _parseScalarSamples(stressRaw),
      hrv: _parseScalarSamples(hrvRaw),
      bloodPressure: [
        for (final b in bpRaw.cast<Map>())
          BloodPressureSample(
            timestamp: DateTime.fromMillisecondsSinceEpoch(
              (b['t'] as num).toInt(),
              isUtc: true,
            ).toLocal(),
            systolic: (b['sbp'] as num).toInt(),
            diastolic: (b['dbp'] as num).toInt(),
          ),
      ],
      steps: (rawSteps != null && rawSteps > kMaxSaneSteps) ? null : rawSteps,
      energyKcal: (rawKcal != null && rawKcal > kMaxSaneKcal) ? null : rawKcal,
      distanceMeters: (rawDist != null && rawDist > kMaxSaneMeters)
          ? null
          : rawDist,
      lastUpdated: updatedRaw == null
          ? null
          : DateTime.fromMillisecondsSinceEpoch(
              (updatedRaw as num).toInt(),
              isUtc: true,
            ).toLocal(),
      syncedMetrics: {
        for (final m in ((j['synced'] as List?) ?? const []).cast<String>()) m,
      },
    );
  }
}

SleepStage _stageFromName(String? name) {
  switch (name) {
    case 'light':
      return SleepStage.light;
    case 'deep':
      return SleepStage.deep;
    case 'rem':
      return SleepStage.rem;
    case 'awake':
      return SleepStage.awake;
    default:
      return SleepStage.light;
  }
}

List<HealthMetricSample> _parseScalarSamples(List raw) => [
  for (final s in raw.cast<Map>())
    HealthMetricSample(
      DateTime.fromMillisecondsSinceEpoch(
        (s['t'] as num).toInt(),
        isUtc: true,
      ).toLocal(),
      (s['v'] as num).toInt(),
    ),
];

DailyHistory _withoutFutureSamples(DailyHistory history, DateTime now) {
  return history.copyWith(
    hr: _clipHrSamples(history.hr, now),
    stress: _clipScalarSamples(history.stress, now),
    hrv: _clipScalarSamples(history.hrv, now),
    bloodPressure: _clipBpSamples(history.bloodPressure, now),
  );
}

List<HrSample> _clipHrSamples(Iterable<HrSample> samples, DateTime now) {
  final bySlot = <int, HrSample>{};
  for (final sample in samples) {
    final snapped = _snapToHrSlot(sample.timestamp);
    if (snapped.isAfter(now)) continue;
    final key = snapped.millisecondsSinceEpoch;
    final existing = bySlot[key];
    if (existing == null || sample.timestamp.isAfter(existing.timestamp)) {
      bySlot[key] = HrSample(snapped, sample.bpm);
    }
  }
  return bySlot.values.toList()
    ..sort((a, b) => a.timestamp.compareTo(b.timestamp));
}

List<HealthMetricSample> _clipScalarSamples(
  Iterable<HealthMetricSample> samples,
  DateTime now,
) {
  return [
    for (final sample in samples)
      if (!sample.timestamp.isAfter(now)) sample,
  ];
}

List<BloodPressureSample> _clipBpSamples(
  Iterable<BloodPressureSample> samples,
  DateTime now,
) {
  return [
    for (final sample in samples)
      if (!sample.timestamp.isAfter(now)) sample,
  ];
}

DateTime _snapToHrSlot(DateTime timestamp) => DateTime(
  timestamp.year,
  timestamp.month,
  timestamp.day,
  timestamp.hour,
  (timestamp.minute ~/ 5) * 5,
);

/// On-device persistent store for daily health data.
///
/// Files are written under `<app docs>/history/<yyyy-mm-dd>.json` — one
/// file per calendar day keeps individual writes small (HR alone is
/// ~288 bytes / day, sleep is small, so even a year of data is well
/// under 1 MB) and makes a partial wipe trivial: deleting a single file
/// invalidates just that day.
///
/// A `SharedPreferences`-backed index tracks [lastSyncedAt] so
/// [HistorySync] can decide what to fetch without re-walking the file
/// tree on every launch.
class HistoryStore {
  HistoryStore._(this._prefs, this._dir);

  final SharedPreferences _prefs;
  final Directory _dir;

  static const _kLastSync = 'history.lastSyncedAt';
  static const _kLastSyncDay = 'history.lastSyncedDay';

  /// Per-day serialization queue. Without this, two concurrent
  /// `writeAsString(flush: true)` calls on the same `<day>.json` race at
  /// the OS level — the second writer truncates the first mid-write and
  /// the resulting file has torn JSON (e.g. `..."updated":<ts>}64}` with
  /// a stray byte from the second writer past the close brace). The
  /// next `readDay` then throws `FormatException` on the bad JSON.
  ///
  /// Each day-keyed task chains onto the previous future for that day
  /// so they run strictly sequentially while still allowing different
  /// days to interleave. A failed task is swallowed (logged) so a
  /// transient disk error doesn't poison the queue for every
  /// subsequent write on the same day.
  final Map<String, Future<void>> _writeQueue = {};

  /// Run [task] sequentially after the previously-enqueued task for
  /// the same [dayKey] completes. The returned future resolves when
  /// [task] finishes (success or logged failure).
  Future<void> _enqueueForDay(String dayKey, Future<void> Function() task) {
    final previous = _writeQueue[dayKey] ?? Future<void>.value();
    final next = previous.then((_) async {
      try {
        await task();
      } catch (e, st) {
        AppLog.instance.warn(
          'history',
          '_enqueueForDay($dayKey) task failed: $e',
        );
        // Surface the error in the trace layer without breaking the
        // queue for subsequent writes — the caller may still be able
        // to retry the same operation.
        OpenTelemetryService().startChildSpan(
            'store.history.write_task_error',
            attributes: {'store.day.iso': dayKey},
          )
          ?..recordError(e, st)
          ..end();
      }
    });
    _writeQueue[dayKey] = next;
    // Drop the slot once the chain drains so the map doesn't grow
    // unbounded for users who sync hundreds of distinct days.
    next.whenComplete(() {
      if (identical(_writeQueue[dayKey], next)) {
        _writeQueue.remove(dayKey);
      }
    });
    return next;
  }

  /// Same as [_enqueueForDay] but propagates [task]'s return value and
  /// any exception through to the caller. Use this for read-modify-write
  /// helpers (`mergeHr`, `mergeSleep`) that need the resulting
  /// [DailyHistory] back so the in-memory state can mirror disk.
  Future<T> _enqueueForDayReturning<T>(
    String dayKey,
    Future<T> Function() task,
  ) async {
    final previous = _writeQueue[dayKey] ?? Future<void>.value();
    // Build a completer so we can hand the caller the task's return
    // value once the chain reaches it.
    final completer = Completer<T>();
    final next = previous.then((_) async {
      try {
        completer.complete(await task());
      } catch (e, st) {
        completer.completeError(e, st);
      }
    });
    _writeQueue[dayKey] = next;
    next.whenComplete(() {
      if (identical(_writeQueue[dayKey], next)) {
        _writeQueue.remove(dayKey);
      }
    });
    return completer.future;
  }

  /// Open the store. Resolves `<app docs>/history/` and ensures it exists.
  static Future<HistoryStore> open() async {
    final prefs = await SharedPreferences.getInstance();
    final base = await getApplicationDocumentsDirectory();
    final dir = Directory('${base.path}/history');
    if (!await dir.exists()) await dir.create(recursive: true);
    return HistoryStore._(prefs, dir);
  }

  /// When the last sync attempt **completed**. Null until the first sync.
  DateTime? get lastSyncedAt {
    final raw = _prefs.getInt(_kLastSync);
    if (raw == null) return null;
    return DateTime.fromMillisecondsSinceEpoch(raw, isUtc: true).toLocal();
  }

  /// `lastSyncedAt` truncated to local midnight — used as the cheap
  /// "skip already-fetched days" guard in [HistorySync]. The watch's
  /// 32-day distribution bitmask only tells us which days have any
  /// data, not whether we've already pulled them, so we also need our
  /// own per-day set (see [persistedDays]).
  DateOnly? get lastSyncedDay {
    final iso = _prefs.getString(_kLastSyncDay);
    if (iso == null) return null;
    return DateOnly.tryParseIso(iso);
  }

  Future<void> _writeWatermark({required DateTime at}) async {
    final day = DateOnly.fromDateTime(at);
    await _prefs.setInt(_kLastSync, at.toUtc().millisecondsSinceEpoch);
    await _prefs.setString(_kLastSyncDay, day.iso);
  }

  File _fileFor(DateOnly day) => File('${_dir.path}/${day.iso}.json');

  // ---------------------------------------------------------------------------
  // Day reads
  // ---------------------------------------------------------------------------

  /// Loads a single day. Returns an empty [DailyHistory] when the file
  /// doesn't exist or fails to parse — sync code can then safely merge
  /// fresh samples into it.
  Future<DailyHistory> readDay(DateOnly day) async {
    // Spans the disk read + parse so we can spot slow file IO or a
    // bad JSON file from a trace alone.
    final span = OpenTelemetryService().startChildSpan(
      'store.history.read_day',
      attributes: {'store.day.iso': day.iso, 'store.op': 'read_day'},
    );
    try {
      final f = _fileFor(day);
      if (!await f.exists()) return DailyHistory(day: day);
      try {
        final raw = await f.readAsString();
        if (raw.isEmpty) return DailyHistory(day: day);
        final j = jsonDecode(raw) as Map<String, dynamic>;
        return _withoutFutureSamples(DailyHistory.fromJson(j), DateTime.now());
      } catch (e) {
        AppLog.instance.warn(
          'history',
          'readDay(${day.iso}) failed: $e — treating as empty',
        );
        return DailyHistory(day: day);
      }
    } catch (e, st) {
      span?.recordError(e, st);
      rethrow;
    } finally {
      span?.end();
    }
  }

  /// Loads a contiguous range of days (inclusive) sorted oldest → newest.
  Future<List<DailyHistory>> readRange(DateOnly from, DateOnly to) async {
    final days = from.daysTo(to);
    final out = <DailyHistory>[];
    for (var i = 0; i <= days; i++) {
      out.add(await readDay(from.addDays(i)));
    }
    return out;
  }

  /// Returns every day for which a file exists, sorted oldest → newest.
  Future<List<DateOnly>> persistedDays() async {
    if (!await _dir.exists()) return const [];
    final files = await _dir
        .list()
        .where((e) => e is File && e.path.endsWith('.json'))
        .cast<File>()
        .toList();
    final out = <DateOnly>[];
    for (final f in files) {
      final name = f.uri.pathSegments.last.replaceAll('.json', '');
      final parsed = DateOnly.tryParseIso(name);
      if (parsed != null) out.add(parsed);
    }
    out.sort();
    return out;
  }

  /// Exports every persisted day + the sync watermarks as a single
  /// JSON-serializable bundle. Used by the Diagnostics → 📤 Export
  /// history button so a user (or a tester on the bus) can paste the
  /// whole store into a bug report without needing adb.
  ///
  /// Shape:
  /// ```
  /// {
  ///   "schemaVersion": 1,
  ///   "exportedAt": "<UTC ISO-8601>",
  ///   "watermarks": {
  ///     "lastSyncedAt": "<UTC ISO-8601>" | null,
  ///     "lastSyncedDay": "yyyy-mm-dd" | null
  ///   },
  ///   "days": [
  ///     { "date": "yyyy-mm-dd", "data": <DailyHistory.toJson()> },
  ///     ...
  ///   ]
  /// }
  /// ```
  ///
  /// The schema is forward-compatible — bumping [schemaVersion] signals
  /// to importers that field meanings may have shifted. Days are emitted
  /// oldest → newest for a deterministic diff against the on-disk layout.
  Future<Map<String, dynamic>> exportAll() async {
    final days = await persistedDays();
    final entries = <Map<String, dynamic>>[];
    for (final d in days) {
      entries.add({'date': d.iso, 'data': (await readDay(d)).toJson()});
    }
    return {
      'schemaVersion': 1,
      'exportedAt': DateTime.now().toUtc().toIso8601String(),
      'watermarks': {
        'lastSyncedAt': lastSyncedAt?.toUtc().toIso8601String(),
        'lastSyncedDay': lastSyncedDay?.iso,
      },
      'days': entries,
    };
  }

  // ---------------------------------------------------------------------------
  // Day writes
  // ---------------------------------------------------------------------------

  /// Persists [history]. Uses [lastUpdated] = now when omitted.
  Future<void> writeDay(DailyHistory history, {DateTime? lastUpdated}) async {
    // Spans the encode + writeAsString for a single day file.
    final span = OpenTelemetryService().startChildSpan(
      'store.history.write_day',
      attributes: {'store.day.iso': history.day.iso, 'store.op': 'write_day'},
    );
    try {
      final stamped = _withoutFutureSamples(
        history,
        DateTime.now(),
      ).copyWith(lastUpdated: lastUpdated ?? DateTime.now());
      final raw = jsonEncode(stamped.toJson());
      // Serialize the file write per day so concurrent callers
      // (e.g. `_upsertTotals` for the 0x2a activity summary and
      // `_flushHrChunks` for the 0x15 HR history) don't truncate
      // each other's JSON mid-flush. See [_enqueueForDay].
      await _enqueueForDay(history.day.iso, () async {
        await _fileFor(history.day).writeAsString(raw, flush: true);
      });
    } catch (e, st) {
      span?.recordError(e, st);
      rethrow;
    } finally {
      span?.end();
    }
  }

  /// Merges [hrSamples] into the existing HR list for [day], dedupes by
  /// timestamp, sorts ascending, and writes the file back. Samples with
  /// identical `timestamp` are replaced by the new value (a re-fetched
  /// slot supersedes the previous read).
  Future<DailyHistory> mergeHr(
    DateOnly day,
    Iterable<HrSample> hrSamples,
  ) async {
    // Spans the read + dedupe + write pass for HR.
    final span = OpenTelemetryService().startChildSpan(
      'store.history.merge_hr',
      attributes: {'store.day.iso': day.iso, 'store.op': 'merge_hr'},
    );
    try {
      // Read-modify-write must be atomic per-day; otherwise a parallel
      // mergeSleep/mergeHr can interleave a write between our read and
      // our write, losing the parallel call's updates. See the
      // [_writeQueue] rationale.
      return await _enqueueForDayReturning<DailyHistory>(day.iso, () async {
        final now = DateTime.now();
        final current = await readDay(day);
        final byTs = <int, HrSample>{
          for (final h in _clipHrSamples(current.hr, now))
            h.timestamp.millisecondsSinceEpoch: h,
        };
        for (final h in _clipHrSamples(hrSamples, now)) {
          byTs[h.timestamp.millisecondsSinceEpoch] = h;
        }
        final merged = byTs.values.toList()
          ..sort((a, b) => a.timestamp.compareTo(b.timestamp));
        final stamped = current.copyWith(
          hr: merged,
          lastUpdated: DateTime.now(),
          syncedMetrics: {...current.syncedMetrics, 'hr'},
        );
        final raw = jsonEncode(stamped.toJson());
        await _fileFor(day).writeAsString(raw, flush: true);
        return stamped;
      });
    } catch (e, st) {
      span?.recordError(e, st);
      rethrow;
    } finally {
      span?.end();
    }
  }

  /// Merges [segments] into the existing sleep list for [day] and writes
  /// back. Sleep segments are deduped by `start` minute — re-fetching a
  /// day with the new-protocol `0x27` shouldn't produce ghost segments.
  Future<DailyHistory> mergeSleep(
    DateOnly day,
    Iterable<SleepSegment> segments,
  ) async {
    // Spans the read + dedupe + write pass for sleep.
    final span = OpenTelemetryService().startChildSpan(
      'store.history.merge_sleep',
      attributes: {'store.day.iso': day.iso, 'store.op': 'merge_sleep'},
    );
    try {
      return await _enqueueForDayReturning<DailyHistory>(day.iso, () async {
        final current = await readDay(day);
        final byStart = <int, SleepSegment>{
          for (final s in current.sleep) s.start.millisecondsSinceEpoch: s,
        };
        for (final s in segments) {
          byStart[s.start.millisecondsSinceEpoch] = s;
        }
        final merged = byStart.values.toList()
          ..sort((a, b) => a.start.compareTo(b.start));
        final stamped = current.copyWith(
          sleep: merged,
          lastUpdated: DateTime.now(),
          syncedMetrics: {...current.syncedMetrics, 'sleep'},
        );
        final raw = jsonEncode(stamped.toJson());
        await _fileFor(day).writeAsString(raw, flush: true);
        return stamped;
      });
    } catch (e, st) {
      span?.recordError(e, st);
      rethrow;
    } finally {
      span?.end();
    }
  }

  /// Records today's totals from `0x48 todaySport` onto [day]. Overwrites
  /// any prior step count for the day — the watch only emits one total
  /// per day so a later (more accurate) value should win.
  Future<DailyHistory> recordTotals(
    DateOnly day, {
    required int steps,
    required int energyKcal,
    required int distanceMeters,
  }) async {
    // Spans the read + overwrite pass when the watch pushes a new
    // today-sport total.
    final span = OpenTelemetryService().startChildSpan(
      'store.history.record_totals',
      attributes: {'store.day.iso': day.iso, 'store.op': 'record_totals'},
    );
    try {
      return await _enqueueForDayReturning<DailyHistory>(day.iso, () async {
        final current = await readDay(day);
        final stamped = current.copyWith(
          steps: steps,
          energyKcal: energyKcal,
          distanceMeters: distanceMeters,
        );
        final raw = jsonEncode(stamped.toJson());
        await _fileFor(day).writeAsString(raw, flush: true);
        return stamped;
      });
    } catch (e, st) {
      span?.recordError(e, st);
      rethrow;
    } finally {
      span?.end();
    }
  }

  Future<DailyHistory> mergeStress(
    DateOnly day,
    Iterable<HealthMetricSample> samples,
  ) => _mergeScalarSamples(
    day,
    samples,
    metricName: 'stress',
    select: (h) => h.stress,
    copy: (h, merged) => h.copyWith(stress: merged),
  );

  Future<DailyHistory> mergeHrv(
    DateOnly day,
    Iterable<HealthMetricSample> samples,
  ) => _mergeScalarSamples(
    day,
    samples,
    metricName: 'hrv',
    select: (h) => h.hrv,
    copy: (h, merged) => h.copyWith(hrv: merged),
  );

  Future<DailyHistory> mergeBloodPressure(
    DateOnly day,
    Iterable<BloodPressureSample> samples,
  ) async {
    final span = OpenTelemetryService().startChildSpan(
      'store.history.merge_bp',
      attributes: {'store.day.iso': day.iso, 'store.op': 'merge_bp'},
    );
    try {
      return await _enqueueForDayReturning<DailyHistory>(day.iso, () async {
        final now = DateTime.now();
        final current = await readDay(day);
        final byTs = <int, BloodPressureSample>{
          for (final b in _clipBpSamples(current.bloodPressure, now))
            b.timestamp.millisecondsSinceEpoch: b,
        };
        for (final b in _clipBpSamples(samples, now)) {
          byTs[b.timestamp.millisecondsSinceEpoch] = b;
        }
        final merged = byTs.values.toList()
          ..sort((a, b) => a.timestamp.compareTo(b.timestamp));
        final stamped = current.copyWith(
          bloodPressure: merged,
          lastUpdated: DateTime.now(),
          syncedMetrics: {...current.syncedMetrics, 'bp'},
        );
        final raw = jsonEncode(stamped.toJson());
        await _fileFor(day).writeAsString(raw, flush: true);
        return stamped;
      });
    } catch (e, st) {
      span?.recordError(e, st);
      rethrow;
    } finally {
      span?.end();
    }
  }

  Future<DailyHistory> _mergeScalarSamples(
    DateOnly day,
    Iterable<HealthMetricSample> samples, {
    required String metricName,
    required List<HealthMetricSample> Function(DailyHistory) select,
    required DailyHistory Function(DailyHistory, List<HealthMetricSample>) copy,
  }) async {
    final span = OpenTelemetryService().startChildSpan(
      'store.history.merge_$metricName',
      attributes: {'store.day.iso': day.iso, 'store.op': 'merge_$metricName'},
    );
    try {
      return await _enqueueForDayReturning<DailyHistory>(day.iso, () async {
        final now = DateTime.now();
        final current = await readDay(day);
        final byTs = <int, HealthMetricSample>{
          for (final s in _clipScalarSamples(select(current), now))
            s.timestamp.millisecondsSinceEpoch: s,
        };
        for (final s in _clipScalarSamples(samples, now)) {
          byTs[s.timestamp.millisecondsSinceEpoch] = s;
        }
        final merged = byTs.values.toList()
          ..sort((a, b) => a.timestamp.compareTo(b.timestamp));
        final stamped = copy(
          current.copyWith(
            lastUpdated: DateTime.now(),
            syncedMetrics: {...current.syncedMetrics, metricName},
          ),
          merged,
        );
        final raw = jsonEncode(stamped.toJson());
        await _fileFor(day).writeAsString(raw, flush: true);
        return stamped;
      });
    } catch (e, st) {
      span?.recordError(e, st);
      rethrow;
    } finally {
      span?.end();
    }
  }

  /// Updates the sync watermark. Called by [HistorySync] only after a
  /// complete pass (or after a definitive "no data on any day" probe).
  Future<void> markSynced(DateTime at) async {
    // Spans the SharedPreferences write so we can correlate a slow
    // "sync complete" with a lagging watermark flush.
    final day = DateOnly.fromDateTime(at);
    final span = OpenTelemetryService().startChildSpan(
      'store.history.mark_synced',
      attributes: {'store.day.iso': day.iso, 'store.op': 'mark_synced'},
    );
    try {
      await _writeWatermark(at: at);
    } catch (e, st) {
      span?.recordError(e, st);
      rethrow;
    } finally {
      span?.end();
    }
  }

  /// Wipes all stored history. Not currently wired into the UI — left
  /// here so a future "Reset app data" affordance can call it without
  /// reaching into `SharedPreferences` directly.
  Future<void> clearAll() async {
    if (await _dir.exists()) {
      await _dir.delete(recursive: true);
      await _dir.create(recursive: true);
    }
    await _prefs.remove(_kLastSync);
    await _prefs.remove(_kLastSyncDay);
  }
}
