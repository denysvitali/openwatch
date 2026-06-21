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

    test('absurd totals from older app versions are coerced to null on read '
        '(regression for kcal=108543 surviving a sync upgrade)', () {
      // 108543 was an actual user export from a pre-fd28b07 build
      // where _activityTotalsFromBody had no clamp and the v13
      // firmware's 0x2a body[6..8] decoded to wildly-wrong values.
      // The fix in `fromJson` keeps the read surface honest even
      // when older files are still on disk.
      final j = {
        'day': '2026-06-21',
        'hr': const [],
        'sleep': const [],
        'steps': 3816,
        'kcal': 108543, // obviously impossible
        'dist': 2434,
        'updated': 1782044197754,
      };
      final parsed = DailyHistory.fromJson(j);
      expect(parsed.steps, 3816, reason: 'sane step value should survive');
      expect(
        parsed.energyKcal,
        isNull,
        reason: '108543 kcal is impossible — must be nulled on read',
      );
      expect(
        parsed.distanceMeters,
        2434,
        reason: 'sane distance value should survive',
      );
    });

    test('sane totals pass through the read clamp unchanged', () {
      // 1800 kcal, 12000 steps, 8500 m are all within kMaxSane* so
      // they must NOT be nulled — only absurd values are.
      final j = {
        'day': '2026-06-21',
        'hr': const [],
        'sleep': const [],
        'steps': 12000,
        'kcal': 1800,
        'dist': 8500,
        'updated': 1782044197754,
      };
      final parsed = DailyHistory.fromJson(j);
      expect(parsed.steps, 12000);
      expect(parsed.energyKcal, 1800);
      expect(parsed.distanceMeters, 8500);
    });

    test('boundary at kMaxSaneKcal (20000) is the inclusive cap', () {
      // Exactly at the cap must survive; one over must be nulled.
      final atCap = DailyHistory.fromJson({
        'day': '2026-06-21',
        'hr': const [],
        'sleep': const [],
        'steps': null,
        'kcal': 20000,
        'dist': null,
        'updated': null,
      });
      final overCap = DailyHistory.fromJson({
        'day': '2026-06-21',
        'hr': const [],
        'sleep': const [],
        'steps': null,
        'kcal': 20001,
        'dist': null,
        'updated': null,
      });
      expect(atCap.energyKcal, 20000);
      expect(overCap.energyKcal, isNull);
    });

    test('absurd sleep totals from echoed firmware records are cleared on read '
        '(regression for "25 hours of sleep" bug)', () {
      // Old on-disk files may contain 24+ hours of sleep after the
      // H59MA v13 firmware echoed a previous day's record into the
      // current response. fromJson must coerce those back to empty.
      final j = {
        'day': '2026-06-19',
        'hr': const [],
        'sleep': [
          // 25 one-hour segments = 1500 min = 25 h
          for (var i = 0; i < 25; i++)
            {'start': 1781785320000 + i * 3600000, 'dur': 60, 'stage': 'deep'},
        ],
        'steps': null,
        'kcal': null,
        'dist': null,
        'updated': null,
      };
      final parsed = DailyHistory.fromJson(j);
      expect(parsed.sleep, isEmpty);
    });

    test('sane sleep totals pass through the read clamp unchanged', () {
      // 10 hours of sleep must survive; only absurd totals are cleared.
      final j = {
        'day': '2026-06-19',
        'hr': const [],
        'sleep': [
          {'start': 1781785320000, 'dur': 600, 'stage': 'deep'},
        ],
        'steps': null,
        'kcal': null,
        'dist': null,
        'updated': null,
      };
      final parsed = DailyHistory.fromJson(j);
      expect(parsed.sleep.length, 1);
      expect(parsed.sleep.single.duration.inMinutes, 600);
    });
  });
}
