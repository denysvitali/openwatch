import '../../core/protocol/sleep_parser.dart';

/// A contiguous sleep window derived from staged sleep segments.
class SleepSessionSummary {
  const SleepSessionSummary({
    required this.start,
    required this.end,
    required this.duration,
  });

  final DateTime start;
  final DateTime end;
  final Duration duration;

  static List<SleepSessionSummary> fromSegments(
    Iterable<SleepSegment> segments, {
    Duration maxGap = const Duration(minutes: 90),
  }) {
    final sorted = segments.toList()
      ..sort((a, b) => a.start.compareTo(b.start));
    if (sorted.isEmpty) return const [];

    final sessions = <SleepSessionSummary>[];
    var start = sorted.first.start;
    var end = _segmentEnd(sorted.first);
    var duration = sorted.first.duration;

    for (final segment in sorted.skip(1)) {
      final segmentEnd = _segmentEnd(segment);
      final gap = segment.start.difference(end);
      if (gap > maxGap) {
        sessions.add(
          SleepSessionSummary(start: start, end: end, duration: duration),
        );
        start = segment.start;
        end = segmentEnd;
        duration = segment.duration;
        continue;
      }

      if (segmentEnd.isAfter(end)) end = segmentEnd;
      duration += segment.duration;
    }

    sessions.add(
      SleepSessionSummary(start: start, end: end, duration: duration),
    );
    return sessions;
  }

  static DateTime _segmentEnd(SleepSegment segment) {
    return segment.start.add(segment.duration);
  }
}
