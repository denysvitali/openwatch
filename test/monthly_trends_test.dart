import 'package:flutter_test/flutter_test.dart';
import 'package:openwatch/core/services/history_sync.dart';
import 'package:openwatch/core/services/monthly_trends.dart';

DailyHistory _day(
  DateOnly d, {
  List<int> hr = const [],
  int? steps,
  int? kcal,
  int? distance,
  int sleepMinutes = 0,
  List<int> stress = const [],
  List<int> hrv = const [],
  int? spo2Max,
  int? spo2Min,
}) {
  return DailyHistory(
    day: d,
    hr: [
      for (final b in hr) HrSample(d.midnight.add(const Duration(hours: 8)), b),
    ],
    steps: steps,
    energyKcal: kcal,
    distanceMeters: distance,
    sleep: sleepMinutes <= 0
        ? const []
        : [
            SleepSegment(
              d.midnight.add(const Duration(hours: 1)),
              Duration(minutes: sleepMinutes),
              SleepStage.deep,
            ),
          ],
    stress: [for (final v in stress) HealthMetricSample(d.midnight, v)],
    hrv: [for (final v in hrv) HealthMetricSample(d.midnight, v)],
    spo2Max: spo2Max,
    spo2Min: spo2Min,
  );
}

void main() {
  group('MonthKey', () {
    test('addMonths wraps across year boundaries', () {
      expect(MonthKey(2026, 1).addMonths(-1), MonthKey(2025, 12));
      expect(MonthKey(2026, 11).addMonths(3), MonthKey(2027, 2));
      expect(MonthKey(2026, 6).addMonths(0), MonthKey(2026, 6));
    });

    test('monthsTo counts signed distance', () {
      expect(MonthKey(2026, 1).monthsTo(MonthKey(2026, 4)), 3);
      expect(MonthKey(2026, 4).monthsTo(MonthKey(2026, 1)), -3);
    });

    test('daysInMonth handles leap February', () {
      expect(MonthKey(2024, 2).daysInMonth, 29);
      expect(MonthKey(2026, 2).daysInMonth, 28);
      expect(MonthKey(2026, 4).daysInMonth, 30);
    });

    test('fromDate drops the day component', () {
      expect(MonthKey.fromDate(DateOnly(2026, 7, 17)), MonthKey(2026, 7));
    });
  });

  group('MonthlyTrends.fromDays', () {
    test('is empty when no day carries data', () {
      final trends = MonthlyTrends.fromDays([
        DailyHistory(day: DateOnly(2026, 6, 1)),
        DailyHistory(day: DateOnly(2026, 6, 2)),
      ]);
      expect(trends.isEmpty, isTrue);
      expect(trends.latest, isNull);
    });

    test('buckets days by month and sorts oldest first', () {
      final trends = MonthlyTrends.fromDays([
        _day(DateOnly(2026, 7, 2), steps: 100),
        _day(DateOnly(2026, 5, 9), steps: 200),
        _day(DateOnly(2026, 6, 1), steps: 300),
      ]);
      expect(trends.months.map((m) => m.month).toList(), [
        MonthKey(2026, 5),
        MonthKey(2026, 6),
        MonthKey(2026, 7),
      ]);
      expect(trends.latest!.month, MonthKey(2026, 7));
      expect(trends.previous!.month, MonthKey(2026, 6));
    });

    test('averages steps only over days that recorded a total', () {
      final trends = MonthlyTrends.fromDays([
        _day(DateOnly(2026, 6, 1), steps: 1000),
        _day(DateOnly(2026, 6, 2), steps: 3000),
        // A day with HR but no step total must not dilute the step average.
        _day(DateOnly(2026, 6, 3), hr: [70]),
      ]);
      final june = trends.latest!;
      expect(june.stepsDays, 2);
      expect(june.stepsTotal, 4000);
      expect(june.stepsAvg, 2000);
      expect(june.stepsBest, 3000);
      expect(june.daysWithData, 3);
    });

    test('aggregates HR min/avg/max across all samples in the month', () {
      final trends = MonthlyTrends.fromDays([
        _day(DateOnly(2026, 6, 1), hr: [60, 80]),
        _day(DateOnly(2026, 6, 2), hr: [100]),
      ]);
      final june = trends.latest!;
      expect(june.hrMin, 60);
      expect(june.hrMax, 100);
      expect(june.hrAvg, 80);
    });

    test('averages sleep over nights with sleep only', () {
      final trends = MonthlyTrends.fromDays([
        _day(DateOnly(2026, 6, 1), sleepMinutes: 400),
        _day(DateOnly(2026, 6, 2), sleepMinutes: 500),
        _day(DateOnly(2026, 6, 3), steps: 10),
      ]);
      final june = trends.latest!;
      expect(june.sleepNights, 2);
      expect(june.sleepTotalMinutes, 900);
      expect(june.sleepAvgMinutes, 450);
    });

    test('spo2 uses the daily mid-point when both bounds present', () {
      final trends = MonthlyTrends.fromDays([
        _day(DateOnly(2026, 6, 1), spo2Max: 98, spo2Min: 94),
        _day(DateOnly(2026, 6, 2), spo2Max: 96, spo2Min: 92),
      ]);
      // mids: 96, 94 -> avg 95
      expect(trends.latest!.spo2Avg, 95);
    });

    test('spo2 falls back to a single bound when only one is present', () {
      final trends = MonthlyTrends.fromDays([
        _day(DateOnly(2026, 6, 1), spo2Min: 90),
        _day(DateOnly(2026, 6, 2), spo2Max: 98),
      ]);
      // Both days contribute their sole bound -> mean(90, 98) = 94.
      expect(trends.latest!.spo2Avg, 94);
    });

    test('a day with only distance/energy still counts as data', () {
      final trends = MonthlyTrends.fromDays([
        _day(DateOnly(2026, 6, 1), distance: 5000, kcal: 300),
      ]);
      expect(trends.isEmpty, isFalse);
      final june = trends.latest!;
      expect(june.daysWithData, 1);
      expect(june.distanceMeters, 5000);
      expect(june.energyKcal, 300);
    });

    test('null metrics stay null rather than zero', () {
      final trends = MonthlyTrends.fromDays([
        _day(DateOnly(2026, 6, 1), steps: 500),
      ]);
      final june = trends.latest!;
      expect(june.hrAvg, isNull);
      expect(june.sleepAvgMinutes, isNull);
      expect(june.spo2Avg, isNull);
      expect(june.stressAvg, isNull);
      expect(june.hrvAvg, isNull);
    });
  });

  group('MonthlyTrends.recent', () {
    test('pads missing months with empty placeholders', () {
      final trends = MonthlyTrends.fromDays([
        _day(DateOnly(2026, 4, 1), steps: 100),
        _day(DateOnly(2026, 7, 1), steps: 200),
      ]);
      final recent = trends.recent(count: 4);
      expect(recent.map((m) => m.month).toList(), [
        MonthKey(2026, 4),
        MonthKey(2026, 5),
        MonthKey(2026, 6),
        MonthKey(2026, 7),
      ]);
      // The filler months carry no data.
      expect(recent[1].hasAnyData, isFalse);
      expect(recent[2].hasAnyData, isFalse);
      expect(recent[3].stepsAvg, 200);
    });

    test('returns empty when there is no data', () {
      expect(const MonthlyTrends([]).recent(), isEmpty);
    });
  });
}
