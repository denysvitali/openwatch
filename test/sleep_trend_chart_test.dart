import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openwatch/core/protocol/sleep_parser.dart';
import 'package:openwatch/core/services/history_store.dart';
import 'package:openwatch/features/history/widgets/sleep_trend_chart.dart';

void main() {
  group('SleepTrendSummary', () {
    test('averages recorded sleep days and reports latest trend', () {
      final monday = DateOnly(2026, 6, 15);
      final days = [
        _day(monday, const Duration(hours: 6)),
        DailyHistory(day: monday.addDays(1)),
        _day(monday.addDays(2), const Duration(hours: 8, minutes: 30)),
      ];

      final summary = SleepTrendSummary.fromDays(days);

      expect(summary.hasData, isTrue);
      expect(summary.average, const Duration(hours: 7, minutes: 15));
      expect(summary.latest, const Duration(hours: 8, minutes: 30));
      expect(summary.previous, const Duration(hours: 6));
      expect(summary.trendMinutes, 150);
    });

    test('is empty when no day has sleep data', () {
      final summary = SleepTrendSummary.fromDays([
        const DailyHistory(day: DateOnly(2026, 6, 15)),
      ]);

      expect(summary.hasData, isFalse);
      expect(summary.average, Duration.zero);
      expect(summary.trendMinutes, isNull);
    });
  });

  testWidgets('SleepTrendChart paints without dashboard providers', (
    tester,
  ) async {
    final monday = DateOnly(2026, 6, 15);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 320,
            height: 140,
            child: SleepTrendChart(
              days: [
                _day(monday, const Duration(hours: 6)),
                _day(monday.addDays(1), const Duration(hours: 7)),
                _day(monday.addDays(2), const Duration(hours: 8)),
              ],
            ),
          ),
        ),
      ),
    );

    expect(find.byType(SleepTrendChart), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}

DailyHistory _day(DateOnly day, Duration sleep) {
  return DailyHistory(
    day: day,
    sleep: [
      SleepSegment(
        day.midnight.add(const Duration(hours: 22)),
        sleep,
        SleepStage.light,
      ),
    ],
  );
}
