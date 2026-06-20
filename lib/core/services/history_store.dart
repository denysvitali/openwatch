import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../protocol/sleep_parser.dart';
import 'app_log.dart';
import 'history_sync.dart' show HrSample;

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
@immutable
class DailyHistory {
  const DailyHistory({
    required this.day,
    this.hr = const [],
    this.sleep = const [],
    this.steps,
    this.energyKcal,
    this.distanceMeters,
    this.lastUpdated,
  });

  final DateOnly day;
  final List<HrSample> hr;
  final List<SleepSegment> sleep;

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
    'steps': steps,
    'kcal': energyKcal,
    'dist': distanceMeters,
    'updated': lastUpdated?.toUtc().millisecondsSinceEpoch,
  };

  static DailyHistory fromJson(Map<String, dynamic> j) {
    final iso = j['day'] as String? ?? '';
    final parsed = DateOnly.tryParseIso(iso);
    if (parsed == null) {
      throw FormatException('DailyHistory: invalid day "$iso"');
    }
    final hrRaw = (j['hr'] as List?) ?? const [];
    final sleepRaw = (j['sleep'] as List?) ?? const [];
    final updatedRaw = j['updated'];
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
      sleep: [
        for (final s in sleepRaw.cast<Map>())
          SleepSegment(
            DateTime.fromMillisecondsSinceEpoch(
              (s['start'] as num).toInt(),
              isUtc: true,
            ).toLocal(),
            Duration(minutes: (s['dur'] as num).toInt()),
            _stageFromName(s['stage'] as String?),
          ),
      ],
      steps: (j['steps'] as num?)?.toInt(),
      energyKcal: (j['kcal'] as num?)?.toInt(),
      distanceMeters: (j['dist'] as num?)?.toInt(),
      lastUpdated: updatedRaw == null
          ? null
          : DateTime.fromMillisecondsSinceEpoch(
              (updatedRaw as num).toInt(),
              isUtc: true,
            ).toLocal(),
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
    final f = _fileFor(day);
    if (!await f.exists()) return DailyHistory(day: day);
    try {
      final raw = await f.readAsString();
      if (raw.isEmpty) return DailyHistory(day: day);
      final j = jsonDecode(raw) as Map<String, dynamic>;
      return DailyHistory.fromJson(j);
    } catch (e) {
      AppLog.instance.warn(
        'history',
        'readDay(${day.iso}) failed: $e — treating as empty',
      );
      return DailyHistory(day: day);
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

  // ---------------------------------------------------------------------------
  // Day writes
  // ---------------------------------------------------------------------------

  /// Persists [history]. Uses [lastUpdated] = now when omitted.
  Future<void> writeDay(DailyHistory history, {DateTime? lastUpdated}) async {
    final stamped = DailyHistory(
      day: history.day,
      hr: history.hr,
      sleep: history.sleep,
      steps: history.steps,
      energyKcal: history.energyKcal,
      distanceMeters: history.distanceMeters,
      lastUpdated: lastUpdated ?? DateTime.now(),
    );
    final raw = jsonEncode(stamped.toJson());
    await _fileFor(history.day).writeAsString(raw, flush: true);
  }

  /// Merges [hrSamples] into the existing HR list for [day], dedupes by
  /// timestamp, sorts ascending, and writes the file back. Samples with
  /// identical `timestamp` are replaced by the new value (a re-fetched
  /// slot supersedes the previous read).
  Future<DailyHistory> mergeHr(
    DateOnly day,
    Iterable<HrSample> hrSamples,
  ) async {
    final current = await readDay(day);
    final byTs = <int, HrSample>{
      for (final h in current.hr) h.timestamp.millisecondsSinceEpoch: h,
    };
    for (final h in hrSamples) {
      byTs[h.timestamp.millisecondsSinceEpoch] = h;
    }
    final merged = byTs.values.toList()
      ..sort((a, b) => a.timestamp.compareTo(b.timestamp));
    final next = DailyHistory(
      day: day,
      hr: merged,
      sleep: current.sleep,
      steps: current.steps,
      energyKcal: current.energyKcal,
      distanceMeters: current.distanceMeters,
      lastUpdated: current.lastUpdated,
    );
    await writeDay(next);
    return next;
  }

  /// Merges [segments] into the existing sleep list for [day] and writes
  /// back. Sleep segments are deduped by `start` minute — re-fetching a
  /// day with the new-protocol `0x27` shouldn't produce ghost segments.
  Future<DailyHistory> mergeSleep(
    DateOnly day,
    Iterable<SleepSegment> segments,
  ) async {
    final current = await readDay(day);
    final byStart = <int, SleepSegment>{
      for (final s in current.sleep) s.start.millisecondsSinceEpoch: s,
    };
    for (final s in segments) {
      byStart[s.start.millisecondsSinceEpoch] = s;
    }
    final merged = byStart.values.toList()
      ..sort((a, b) => a.start.compareTo(b.start));
    final next = DailyHistory(
      day: day,
      hr: current.hr,
      sleep: merged,
      steps: current.steps,
      energyKcal: current.energyKcal,
      distanceMeters: current.distanceMeters,
      lastUpdated: current.lastUpdated,
    );
    await writeDay(next);
    return next;
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
    final current = await readDay(day);
    final next = DailyHistory(
      day: day,
      hr: current.hr,
      sleep: current.sleep,
      steps: steps,
      energyKcal: energyKcal,
      distanceMeters: distanceMeters,
      lastUpdated: current.lastUpdated,
    );
    await writeDay(next);
    return next;
  }

  /// Updates the sync watermark. Called by [HistorySync] only after a
  /// complete pass (or after a definitive "no data on any day" probe).
  Future<void> markSynced(DateTime at) => _writeWatermark(at: at);

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
