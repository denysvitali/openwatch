import 'package:flutter_test/flutter_test.dart';
import 'package:openwatch/core/protocol/sleep_parser.dart';
import 'package:openwatch/features/history/sleep_session_summary.dart';

void main() {
  test('builds one session from contiguous staged sleep segments', () {
    final start = DateTime(2026, 6, 22, 22, 15);

    final sessions = SleepSessionSummary.fromSegments([
      SleepSegment(start, const Duration(hours: 2), SleepStage.light),
      SleepSegment(
        start.add(const Duration(hours: 2)),
        const Duration(hours: 3, minutes: 30),
        SleepStage.deep,
      ),
      SleepSegment(
        start.add(const Duration(hours: 5, minutes: 30)),
        const Duration(hours: 1),
        SleepStage.rem,
      ),
    ]);

    expect(sessions, hasLength(1));
    expect(sessions.single.start, start);
    expect(
      sessions.single.end,
      start.add(const Duration(hours: 6, minutes: 30)),
    );
    expect(sessions.single.duration, const Duration(hours: 6, minutes: 30));
  });

  test('splits sessions across large gaps', () {
    final nap = DateTime(2026, 6, 22, 13);
    final night = DateTime(2026, 6, 22, 22);

    final sessions = SleepSessionSummary.fromSegments([
      SleepSegment(night, const Duration(hours: 7), SleepStage.light),
      SleepSegment(nap, const Duration(minutes: 45), SleepStage.light),
    ]);

    expect(sessions, hasLength(2));
    expect(sessions[0].start, nap);
    expect(sessions[0].end, nap.add(const Duration(minutes: 45)));
    expect(sessions[0].duration, const Duration(minutes: 45));
    expect(sessions[1].start, night);
    expect(sessions[1].end, night.add(const Duration(hours: 7)));
    expect(sessions[1].duration, const Duration(hours: 7));
  });
}
