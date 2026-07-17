import 'package:flutter/foundation.dart';

import 'history_store.dart';
import 'history_sync.dart' show HrSample, HealthMetricSample;

/// One calendar month, normalised to (year, month). Hour/day are dropped so
/// two [DateOnly]s in the same wall-clock month key equal.
///
/// This mirrors [DateOnly] but at month granularity — the unit the monthly
/// trends view buckets by.
@immutable
class MonthKey implements Comparable<MonthKey> {
  const MonthKey(this.year, this.month);

  /// Wall-clock year (e.g. 2026).
  final int year;

  /// 1..12.
  final int month;

  factory MonthKey.fromDate(DateOnly day) => MonthKey(day.year, day.month);

  /// This calendar month in the local timezone.
  factory MonthKey.current() {
    final d = DateOnly.today();
    return MonthKey(d.year, d.month);
  }

  /// Returns a new [MonthKey] shifted by [months] (negative = past).
  MonthKey addMonths(int months) {
    // Convert to a 0-based absolute month index so wrap-around across year
    // boundaries falls out of plain integer arithmetic.
    final total = year * 12 + (month - 1) + months;
    return MonthKey(total ~/ 12, (total % 12) + 1);
  }

  /// Number of months from `this` to [other] (positive when [other] is
  /// later).
  int monthsTo(MonthKey other) =>
      (other.year * 12 + other.month) - (year * 12 + month);

  /// First day of the month.
  DateOnly get firstDay => DateOnly(year, month, 1);

  /// Number of calendar days in this month (handles leap Februaries).
  int get daysInMonth => DateTime(year, month + 1, 0).day;

  @override
  bool operator ==(Object other) =>
      other is MonthKey && other.year == year && other.month == month;

  @override
  int get hashCode => Object.hash(year, month);

  @override
  int compareTo(MonthKey other) {
    final c = year.compareTo(other.year);
    return c != 0 ? c : month.compareTo(other.month);
  }

  @override
  String toString() => '$year-${month.toString().padLeft(2, '0')}';
}

/// Aggregated health metrics for a single calendar month.
///
/// Every field is derived purely from the [DailyHistory] rows that fall in
/// the month — no BLE, no async, so this is unit-testable end to end. Fields
/// are null when the month has no contributing data for that metric, so the
/// UI can distinguish "no data" from a real zero.
@immutable
class MonthlyTrend {
  const MonthlyTrend({
    required this.month,
    required this.daysWithData,
    required this.stepsDays,
    required this.stepsTotal,
    required this.stepsBest,
    required this.distanceMeters,
    required this.energyKcal,
    required this.sleepNights,
    required this.sleepTotalMinutes,
    required this.hrAvg,
    required this.hrMin,
    required this.hrMax,
    required this.spo2Avg,
    required this.stressAvg,
    required this.hrvAvg,
  });

  final MonthKey month;

  /// How many distinct days in the month carried any stored data.
  final int daysWithData;

  /// How many days recorded a step total (denominator for [stepsAvg]).
  final int stepsDays;

  /// Sum of daily step totals across the month.
  final int stepsTotal;

  /// Highest single-day step total, or null if no day had steps.
  final int? stepsBest;

  /// Sum of daily distance in meters.
  final int distanceMeters;

  /// Sum of daily active energy in kcal.
  final int energyKcal;

  /// How many nights recorded any sleep (denominator for [sleepAvgMinutes]).
  final int sleepNights;

  /// Sum of all sleep minutes across the month.
  final int sleepTotalMinutes;

  /// Mean heart rate across every HR sample in the month, or null.
  final int? hrAvg;

  /// Lowest / highest single HR sample in the month, or null.
  final int? hrMin;
  final int? hrMax;

  /// Mean of each day's SpO2 mid-point (`(min+max)/2`) over days with data.
  final int? spo2Avg;

  /// Mean stress across every stress sample in the month, or null.
  final int? stressAvg;

  /// Mean HRV (ms) across every HRV sample in the month, or null.
  final int? hrvAvg;

  /// Mean daily steps over days that recorded a total, or null.
  int? get stepsAvg => stepsDays == 0 ? null : (stepsTotal / stepsDays).round();

  /// Mean nightly sleep over nights with data, or null.
  int? get sleepAvgMinutes =>
      sleepNights == 0 ? null : (sleepTotalMinutes / sleepNights).round();

  bool get hasAnyData => daysWithData > 0;
}

/// A single metric plotted across months, used to drive the bar chart.
enum TrendMetric { steps, sleep, heartRate, spo2, stress, hrv }

/// Ordered set of per-month aggregates, newest last.
@immutable
class MonthlyTrends {
  const MonthlyTrends(this.months);

  /// One entry per month that had data, sorted oldest → newest.
  final List<MonthlyTrend> months;

  bool get isEmpty => months.isEmpty;

  MonthlyTrend? get latest => months.isEmpty ? null : months.last;

  MonthlyTrend? get previous =>
      months.length < 2 ? null : months[months.length - 2];

  /// Buckets [days] by calendar month and computes an aggregate per month.
  ///
  /// Only months that contain at least one day with data are emitted. The
  /// result is sorted oldest → newest so a bar chart reads left-to-right in
  /// time order.
  factory MonthlyTrends.fromDays(Iterable<DailyHistory> days) {
    final buckets = <MonthKey, List<DailyHistory>>{};
    for (final day in days) {
      buckets.putIfAbsent(MonthKey.fromDate(day.day), () => []).add(day);
    }
    final out = <MonthlyTrend>[];
    for (final entry in buckets.entries) {
      final trend = _aggregate(entry.key, entry.value);
      if (trend.hasAnyData) out.add(trend);
    }
    out.sort((a, b) => a.month.compareTo(b.month));
    return MonthlyTrends(out);
  }

  /// Returns the last [count] months ending at the latest recorded month,
  /// inserting empty placeholders for months that had no data so the chart
  /// keeps a continuous time axis. Returns an empty list when there is no
  /// data at all.
  List<MonthlyTrend> recent({int count = 6}) {
    if (months.isEmpty) return const [];
    final byMonth = {for (final m in months) m.month: m};
    final end = months.last.month;
    return [
      for (var offset = -count + 1; offset <= 0; offset++)
        byMonth[end.addMonths(offset)] ?? _empty(end.addMonths(offset)),
    ];
  }

  static MonthlyTrend _empty(MonthKey month) => MonthlyTrend(
    month: month,
    daysWithData: 0,
    stepsDays: 0,
    stepsTotal: 0,
    stepsBest: null,
    distanceMeters: 0,
    energyKcal: 0,
    sleepNights: 0,
    sleepTotalMinutes: 0,
    hrAvg: null,
    hrMin: null,
    hrMax: null,
    spo2Avg: null,
    stressAvg: null,
    hrvAvg: null,
  );

  static MonthlyTrend _aggregate(MonthKey month, List<DailyHistory> days) {
    var daysWithData = 0;
    var stepsDays = 0;
    var stepsTotal = 0;
    int? stepsBest;
    var distance = 0;
    var kcal = 0;
    var sleepNights = 0;
    var sleepMinutes = 0;

    final hr = <int>[];
    final stress = <int>[];
    final hrv = <int>[];
    final spo2Mids = <int>[];

    for (final day in days) {
      if (_dayHasData(day)) daysWithData++;

      final steps = day.steps;
      if (steps != null) {
        stepsDays++;
        stepsTotal += steps;
        if (stepsBest == null || steps > stepsBest) stepsBest = steps;
      }
      if (day.distanceMeters != null) distance += day.distanceMeters!;
      if (day.energyKcal != null) kcal += day.energyKcal!;

      final nightMinutes = day.sleep.fold<int>(
        0,
        (a, s) => a + s.duration.inMinutes,
      );
      if (nightMinutes > 0) {
        sleepNights++;
        sleepMinutes += nightMinutes;
      }

      hr.addAll(day.hr.map(_bpm));
      stress.addAll(day.stress.map(_value));
      hrv.addAll(day.hrv.map(_value));

      // Prefer the (min+max)/2 mid-point, but fall back to whichever bound
      // is present so a day that only stored one side still counts.
      final spo2Max = day.spo2Max;
      final spo2Min = day.spo2Min;
      if (spo2Max != null && spo2Min != null) {
        spo2Mids.add(((spo2Max + spo2Min) / 2).round());
      } else if (spo2Max != null) {
        spo2Mids.add(spo2Max);
      } else if (spo2Min != null) {
        spo2Mids.add(spo2Min);
      }
    }

    return MonthlyTrend(
      month: month,
      daysWithData: daysWithData,
      stepsDays: stepsDays,
      stepsTotal: stepsTotal,
      stepsBest: stepsBest,
      distanceMeters: distance,
      energyKcal: kcal,
      sleepNights: sleepNights,
      sleepTotalMinutes: sleepMinutes,
      hrAvg: _mean(hr),
      hrMin: hr.isEmpty ? null : hr.reduce((a, b) => a < b ? a : b),
      hrMax: hr.isEmpty ? null : hr.reduce((a, b) => a > b ? a : b),
      spo2Avg: _mean(spo2Mids),
      stressAvg: _mean(stress),
      hrvAvg: _mean(hrv),
    );
  }

  static bool _dayHasData(DailyHistory day) =>
      day.hr.isNotEmpty ||
      day.sleep.isNotEmpty ||
      day.stress.isNotEmpty ||
      day.hrv.isNotEmpty ||
      day.bloodPressure.isNotEmpty ||
      day.spo2Max != null ||
      day.spo2Min != null ||
      day.steps != null ||
      day.distanceMeters != null ||
      day.energyKcal != null;

  static int _bpm(HrSample s) => s.bpm;
  static int _value(HealthMetricSample s) => s.value;

  static int? _mean(List<int> values) {
    if (values.isEmpty) return null;
    return (values.reduce((a, b) => a + b) / values.length).round();
  }
}
