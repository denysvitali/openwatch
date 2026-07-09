import 'dart:typed_data';

import 'sleep_parser.dart';

/// A decoded H59MA Channel-B `0x11` sleep-summary record.
class H59SleepSummary {
  const H59SleepSummary({
    required this.dayOffset,
    required this.startMinute,
    required this.endMinute,
    required this.segments,
  });

  final int dayOffset;
  final int startMinute;
  final int endMinute;
  final List<SleepSegment> segments;
}

/// Totals from one H59MA Channel-B `0x12` hourly-detail record.
class H59SleepDetail {
  const H59SleepDetail({
    required this.dayOffset,
    required this.steps,
    required this.calories,
    required this.distanceMeters,
    required this.durationSeconds,
  });

  final int dayOffset;
  final int steps;
  final int calories;
  final int distanceMeters;
  final int durationSeconds;
}

/// Pure decoders for the H59MA-specific Channel-B sleep history records.
class H59HistoryParser {
  H59HistoryParser._();

  static const int summaryBodyLength = 100;
  static const int detailBodyLength = 288;

  /// Decodes `[dayOffset][100-byte summary]` from Channel-B `0x11`.
  ///
  /// Type ids are preserved through the repository's established display
  /// mapping: 0/4 → awake, 2 → deep, 3 → REM, and 5 → light. The firmware
  /// does not prove clinical labels for these ids, but this keeps the result
  /// consistent with the newer `0x27` parser.
  static H59SleepSummary? parseSummary(Uint8List payload) {
    if (payload.length < 1 + summaryBodyLength) return null;
    final dayOffset = payload[0];
    final body = payload.sublist(1, 1 + summaryBodyLength);
    final count = body[0x13];
    if (count > 40) return null;
    if (0x14 + count > body.length || 0x3c + count > body.length) {
      return null;
    }

    final start = _u16le(body, 0x0e);
    final end = _u16le(body, 0x10);
    if (start >= 1440 || end >= 1440) return null;
    var cursor = start;
    var base = DateTime(2000, 1, 1);
    // The actual calendar anchor is supplied by HistorySync after decoding;
    // this temporary date keeps the parser pure and lets callers shift the
    // segment dates without losing the midnight crossing.
    if (end < start) base = base.subtract(const Duration(days: 1));

    final segments = <SleepSegment>[];
    for (var i = 0; i < count; i++) {
      final duration = body[0x3c + i];
      if (duration == 0) continue;
      final type = body[0x14 + i];
      final startAt = base.add(Duration(minutes: cursor));
      segments.add(
        SleepSegment(startAt, Duration(minutes: duration), _stageFor(type)),
      );
      cursor += duration;
      if (cursor >= 1440) {
        cursor -= 1440;
        base = base.add(const Duration(days: 1));
      }
    }
    return H59SleepSummary(
      dayOffset: dayOffset,
      startMinute: start,
      endMinute: end,
      segments: segments,
    );
  }

  /// Re-anchors a summary parsed by [parseSummary] to the supplied wake day.
  static H59SleepSummary anchorSummary(
    H59SleepSummary summary,
    DateTime wakeDay,
  ) {
    final sourceBase = DateTime(2000, 1, 1);
    final targetBase = DateTime(wakeDay.year, wakeDay.month, wakeDay.day);
    final delta = targetBase.difference(sourceBase);
    return H59SleepSummary(
      dayOffset: summary.dayOffset,
      startMinute: summary.startMinute,
      endMinute: summary.endMinute,
      segments: [
        for (final segment in summary.segments)
          SleepSegment(
            segment.start.add(delta),
            segment.duration,
            segment.stage,
          ),
      ],
    );
  }

  /// Decodes `[dayOffset][288-byte 24×12 detail]` from Channel-B `0x12`.
  static H59SleepDetail? parseDetail(Uint8List payload) {
    if (payload.length < 1 + detailBodyLength) return null;
    final dayOffset = payload[0];
    final body = payload.sublist(1, 1 + detailBodyLength);
    var steps = 0;
    var calories = 0;
    var distance = 0;
    var durationSeconds = 0;
    for (var hour = 0; hour < 24; hour++) {
      final off = hour * 12;
      final slotSteps = _u16le(body, off);
      if (slotSteps == 0xffff) continue;
      steps += slotSteps;
      calories += _u16le(body, off + 4);
      // The firmware stores distance deltas in decameters (/10); the app's
      // DailyTotals contract is meters.
      distance += _u16le(body, off + 6) * 10;
      durationSeconds += body[off + 8];
    }
    return H59SleepDetail(
      dayOffset: dayOffset,
      steps: steps,
      calories: calories,
      distanceMeters: distance,
      durationSeconds: durationSeconds,
    );
  }

  static SleepStage _stageFor(int type) {
    switch (type) {
      case 2:
        return SleepStage.deep;
      case 3:
        return SleepStage.rem;
      case 5:
        return SleepStage.light;
      case 0:
      case 4:
      default:
        return SleepStage.awake;
    }
  }

  static int _u16le(Uint8List bytes, int offset) =>
      bytes[offset] | (bytes[offset + 1] << 8);
}
