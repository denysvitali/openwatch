import 'package:flutter_test/flutter_test.dart';

import 'package:openwatch/core/services/history_debug_export.dart';
import 'package:openwatch/core/services/history_sync.dart';

void main() {
  group('HistoryDebugExport.formatDay', () {
    test('empty day renders all sections + falls well under 100 kB', () {
      // Every section header must be present even when the day has no
      // data — recipients rely on these to align diffs.
      final day = DailyHistory(day: DateOnly(2026, 6, 23));
      final out = HistoryDebugExport.formatDay(day);
      expect(out, contains('day=2026-06-23'));
      expect(out, contains('## hr (288 slots, 0 samples)'));
      expect(out, contains('## sleep (0 segments)'));
      expect(out, contains('## stress (288 slots, 0 samples)'));
      expect(out, contains('## hrv (288 slots, 0 samples)'));
      expect(out, contains('## bp (0 samples)'));
      expect(out, contains('## totals'));
      expect(out.length, lessThan(1024));
    });

    test('includes min/max/avg summary for HR', () {
      final day = DailyHistory(
        day: DateOnly(2026, 6, 23),
        hr: [
          HrSample(DateTime(2026, 6, 23, 0, 0), 60),
          HrSample(DateTime(2026, 6, 23, 6, 30), 80),
          HrSample(DateTime(2026, 6, 23, 23, 55), 100),
        ],
      );
      final out = HistoryDebugExport.formatDay(day);
      expect(out, contains('# min=60 max=100 avg=80'));
      expect(out, contains('00:00 60'));
      expect(out, contains('06:30 80'));
      expect(out, contains('23:55 100'));
    });

    test('fully populated day fits the 100 kB share budget', () {
      // Realistic worst case: HR every 5 min for 24 h (288 samples)
      // plus stress + HRV every 30 min (48 samples) plus a handful of
      // sleep segments and BP samples. Each sample line is ~9–12 bytes,
      // so the package is ~5–6 kB.
      final hr = <HrSample>[
        for (var i = 0; i < 288; i++)
          HrSample(
            DateTime(2026, 6, 23, 0, 0).add(Duration(minutes: i * 5)),
            50 + (i % 60),
          ),
      ];
      final stress = <HealthMetricSample>[
        for (var i = 0; i < 48; i++)
          HealthMetricSample(
            DateTime(2026, 6, 23, 0, 0).add(Duration(minutes: i * 30)),
            30 + (i % 50),
          ),
      ];
      final hrv = <HealthMetricSample>[
        for (var i = 0; i < 48; i++)
          HealthMetricSample(
            DateTime(2026, 6, 23, 0, 0).add(Duration(minutes: i * 30)),
            20 + (i % 50),
          ),
      ];
      final bp = <BloodPressureSample>[
        for (var i = 0; i < 5; i++)
          BloodPressureSample(
            timestamp: DateTime(2026, 6, 23, 8, 0).add(Duration(hours: i * 3)),
            systolic: 110 + i,
            diastolic: 70 + i,
          ),
      ];
      final sleep = <SleepSegment>[
        SleepSegment(
          DateTime(2026, 6, 23, 0, 30),
          const Duration(hours: 6),
          SleepStage.light,
        ),
        SleepSegment(
          DateTime(2026, 6, 23, 6, 30),
          const Duration(minutes: 20),
          SleepStage.awake,
        ),
      ];
      final day = DailyHistory(
        day: DateOnly(2026, 6, 23),
        hr: hr,
        sleep: sleep,
        stress: stress,
        hrv: hrv,
        bloodPressure: bp,
        steps: 12345,
        energyKcal: 567,
        distanceMeters: 8901,
        lastUpdated: DateTime(2026, 6, 23, 0, 18, 35),
      );
      final out = HistoryDebugExport.formatDay(day);
      // Far below the 100 kB cap; cap is the *upper* bound for the
      // 1-tap-share path so this guard catches accidental regressions.
      expect(out.length, lessThan(100 * 1024));
      // Sanity: every section populated.
      expect(out, contains('steps=12345'));
      expect(out, contains('kcal=567'));
      expect(out, contains('dist_m=8901'));
      expect(out, contains('00:00 50'));
      expect(out, contains('08:00 110/70'));
      expect(out, contains('# total=6h20m'));
    });

    test('context fields show up in the header when supplied', () {
      final day = DailyHistory(day: DateOnly(2026, 6, 23));
      final out = HistoryDebugExport.formatDay(
        day,
        context: const HistoryDebugContext(
          firmware: 'H59MA_1.00.13_251230',
          hardware: 'H59MA_V1.0',
          linkState: 'ready',
          tzOffset: 'UTC+02:00',
          fetched: true,
        ),
      );
      expect(out, contains('firmware=H59MA_1.00.13_251230'));
      expect(out, contains('hardware=H59MA_V1.0'));
      expect(out, contains('link=ready'));
      expect(out, contains('tz=UTC+02:00'));
      expect(out, contains('freshly_fetched=true'));
    });
  });
}
