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
      // Use a fixed past day so all samples fall before the export's
      // `generated` and none get clipped.
      final day0 = DateTime(2020, 6, 23);
      final day = DailyHistory(
        day: DateOnly(2020, 6, 23),
        hr: [
          HrSample(day0.add(const Duration(hours: 0)), 60),
          HrSample(day0.add(const Duration(hours: 6, minutes: 30)), 80),
          HrSample(day0.add(const Duration(hours: 23, minutes: 55)), 100),
        ],
      );
      final out = HistoryDebugExport.formatDay(day);
      expect(out, contains('# min=60 max=100 avg=80'));
      expect(out, contains('00:00 60'));
      expect(out, contains('06:30 80'));
      expect(out, contains('23:55 100'));
    });

    test('clips HR samples with timestamps after now and dedupes by slot', () {
      // The watch stores a fixed 288-slot 24h record; on a freshly-started
      // day the raw list contains "future" timestamps the watch hasn't
      // measured yet. Snap each to its 5-min slot, dedupe by slot, and
      // drop anything past the export's `generated` (which doubles as the
      // clip anchor) — so this 11-duplicates-per-slot input collapses to
      // a clean per-slot list once clipped. Use a fixed past day so the
      // early-morning samples fall before "now" and survive the clip.
      final day0 = DateTime(2020, 6, 23);
      final hr = <HrSample>[
        // 11 duplicate readings at minute 12 → snap to slot 00:10
        for (var i = 0; i < 11; i++)
          HrSample(day0.add(const Duration(minutes: 12)), 93),
        // 11 duplicate readings at minute 17 → snap to slot 00:15
        for (var i = 0; i < 11; i++)
          HrSample(day0.add(const Duration(minutes: 17)), 66),
        // late-evening sample — well before the next day's 00:00 anchor,
        // so it must survive and snap to 23:55.
        HrSample(day0.add(const Duration(hours: 23, minutes: 55)), 120),
      ];
      final day = DailyHistory(day: const DateOnly(2020, 6, 23), hr: hr);
      final out = HistoryDebugExport.formatDay(day);
      // Two unique slots from the duplicates + the late-evening one.
      expect(out, contains('00:10 93'));
      expect(out, contains('00:15 66'));
      expect(out, contains('23:55 120'));
      // The duplicates collapsed — only one line per snapped slot.
      final slotLines = out.split('\n').where((l) => l == '00:10 93').length;
      expect(slotLines, 1);
    });

    test('fully populated day fits the 100 kB share budget', () {
      // Realistic worst case: HR every 5 min for 24 h (288 samples)
      // plus stress + HRV every 30 min (48 samples) plus a handful of
      // sleep segments and BP samples. Each sample line is ~9–12 bytes,
      // so the package is ~5–6 kB. Use a fixed past date so the export
      // `generated` (real-time now) is after every sample and nothing
      // gets clipped by the future-timestamp guard.
      const dayIso = '2020-06-23';
      final day0 = DateTime(2020, 6, 23);
      final hr = <HrSample>[
        for (var i = 0; i < 288; i++)
          HrSample(day0.add(Duration(minutes: i * 5)), 50 + (i % 60)),
      ];
      final stress = <HealthMetricSample>[
        for (var i = 0; i < 48; i++)
          HealthMetricSample(
            day0.add(Duration(minutes: i * 30)),
            30 + (i % 50),
          ),
      ];
      final hrv = <HealthMetricSample>[
        for (var i = 0; i < 48; i++)
          HealthMetricSample(
            day0.add(Duration(minutes: i * 30)),
            20 + (i % 50),
          ),
      ];
      final bp = <BloodPressureSample>[
        for (var i = 0; i < 5; i++)
          BloodPressureSample(
            timestamp: day0.add(Duration(hours: 8 + i * 3)),
            systolic: 110 + i,
            diastolic: 70 + i,
          ),
      ];
      final sleep = <SleepSegment>[
        SleepSegment(
          day0.add(const Duration(minutes: 30)),
          const Duration(hours: 6),
          SleepStage.light,
        ),
        SleepSegment(
          day0.add(const Duration(hours: 6, minutes: 30)),
          const Duration(minutes: 20),
          SleepStage.awake,
        ),
      ];
      final day = DailyHistory(
        day: const DateOnly(2020, 6, 23),
        hr: hr,
        sleep: sleep,
        stress: stress,
        hrv: hrv,
        bloodPressure: bp,
        steps: 12345,
        energyKcal: 567,
        distanceMeters: 8901,
        lastUpdated: day0.add(const Duration(minutes: 18, seconds: 35)),
      );
      final out = HistoryDebugExport.formatDay(day);
      // Far below the 100 kB cap; cap is the *upper* bound for the
      // 1-tap-share path so this guard catches accidental regressions.
      expect(out.length, lessThan(100 * 1024));
      // Sanity: every section populated.
      expect(out, contains('day=$dayIso'));
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
