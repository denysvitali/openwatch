import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:openwatch/core/services/history_sync.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
  });

  group('DateOnly', () {
    test('roundtrips through iso', () {
      final d = DateOnly(2026, 6, 20);
      expect(d.iso, '2026-06-20');
      expect(DateOnly.tryParseIso('2026-06-20'), d);
      expect(DateOnly.tryParseIso('garbage'), isNull);
    });

    test('addDays wraps across month + year boundaries', () {
      expect(DateOnly(2026, 1, 31).addDays(1), DateOnly(2026, 2, 1));
      expect(DateOnly(2026, 12, 31).addDays(1), DateOnly(2027, 1, 1));
      expect(DateOnly(2026, 6, 20).addDays(-7), DateOnly(2026, 6, 13));
    });

    test('daysTo is calendar-day difference (positive for future)', () {
      expect(DateOnly(2026, 6, 20).daysTo(DateOnly(2026, 6, 27)), 7);
      expect(DateOnly(2026, 6, 27).daysTo(DateOnly(2026, 6, 20)), -7);
    });

    test('compares lexicographically', () {
      final days = [
        DateOnly(2026, 6, 20),
        DateOnly(2026, 6, 1),
        DateOnly(2026, 7, 1),
      ]..sort();
      expect(days.first, DateOnly(2026, 6, 1));
      expect(days.last, DateOnly(2026, 7, 1));
    });

    test('fromDateTime truncates to local midnight', () {
      final dt = DateTime(2026, 6, 20, 13, 45, 12);
      expect(DateOnly.fromDateTime(dt), DateOnly(2026, 6, 20));
    });
  });

  group('DailyHistory JSON', () {
    test('roundtrips HR + sleep + totals through JSON', () {
      final original = DailyHistory(
        day: DateOnly(2026, 6, 20),
        hr: [
          HrSample(DateTime(2026, 6, 20, 7, 0), 62),
          HrSample(DateTime(2026, 6, 20, 7, 5), 64),
        ],
        sleep: [
          SleepSegment(
            DateTime(2026, 6, 20, 1, 0),
            const Duration(minutes: 30),
            SleepStage.deep,
          ),
        ],
        steps: 8421,
        energyKcal: 320,
        distanceMeters: 6700,
        lastUpdated: DateTime(2026, 6, 20, 9, 0),
      );
      final restored = DailyHistory.fromJson(
        jsonDecode(jsonEncode(original.toJson())) as Map<String, dynamic>,
      );
      expect(restored.day, original.day);
      expect(restored.hr.length, 2);
      expect(restored.hr.first.bpm, 62);
      expect(restored.hr.last.bpm, 64);
      expect(restored.sleep.single.stage, SleepStage.deep);
      expect(restored.steps, 8421);
      expect(restored.energyKcal, 320);
      expect(restored.distanceMeters, 6700);
    });

    test('unknown sleep stage name falls back to light (defensive parse)', () {
      final j = {
        'day': '2026-06-20',
        'hr': const [],
        'sleep': [
          {'start': 0, 'dur': 30, 'stage': 'mystery'},
        ],
        'steps': null,
        'kcal': null,
        'dist': null,
        'updated': null,
      };
      final parsed = DailyHistory.fromJson(j);
      expect(parsed.sleep.single.stage, SleepStage.light);
    });
  });
}
