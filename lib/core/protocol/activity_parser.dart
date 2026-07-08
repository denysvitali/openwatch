import 'package:flutter/foundation.dart';

/// One hour of SpO2 max/min from Channel-B `0x2a` (H59MA v14).
///
/// Firmware producer (`history-layouts/evidence.md` §3): each sample is a
/// pair of independent u8s `(max, min)` in the SpO2 percent domain (≤100),
/// **not** a u16 step count or u24 sport total.
@immutable
class Spo2HourSample {
  const Spo2HourSample({
    required this.hour,
    required this.max,
    required this.min,
  });

  /// Local hour of day `0..23`.
  final int hour;

  /// Running max SpO2 % for the hour (`0` = no sample / hole).
  final int max;

  /// Running min SpO2 % for the hour (`0` = no sample / hole).
  final int min;

  bool get hasData => max > 0 || min > 0;
}

/// Pure parsers for Channel-B activity / SpO2 day summaries
/// (`OpB.activitySummary = 0x2a`).
class ActivityParser {
  ActivityParser._();

  /// Entry size: 1 B dayOffset + 48 B body (24 × 2 B).
  static const int entrySize = 49;

  /// Body length after the day-offset byte.
  static const int bodySize = 48;

  /// Parse a full Channel-B `0x2a` payload into per-day entries.
  ///
  /// Payload is one or more `[dayOffset][48 B body]` groups. Firmware emits
  /// at most 3 entries (`dayOffset` 2, 1, 0). `0xFF` body bytes are holes
  /// and become `0` (firmware reader does the same).
  static List<ActivityDayEntry> parsePayload(Uint8List payload) {
    final out = <ActivityDayEntry>[];
    var offset = 0;
    while (offset + entrySize <= payload.length) {
      final dayOffset = payload[offset] & 0xFF;
      final body = Uint8List(bodySize);
      for (var i = 0; i < bodySize; i++) {
        final b = payload[offset + 1 + i] & 0xFF;
        body[i] = b == 0xff ? 0x00 : b;
      }
      if (dayOffset <= 31) {
        out.add(
          ActivityDayEntry(
            dayOffset: dayOffset,
            samples: parseHourlyBody(body),
          ),
        );
      }
      offset += entrySize;
    }
    return out;
  }

  /// Decode a 48-byte body as 24 × (max, min) hourly SpO2 samples.
  static List<Spo2HourSample> parseHourlyBody(Uint8List body) {
    if (body.length < bodySize) {
      final padded = Uint8List(bodySize);
      padded.setRange(0, body.length, body);
      return _parse24(padded);
    }
    return _parse24(Uint8List.sublistView(body, 0, bodySize));
  }

  static List<Spo2HourSample> _parse24(Uint8List body) {
    return [
      for (var h = 0; h < 24; h++)
        Spo2HourSample(
          hour: h,
          max: body[h * 2] & 0xFF,
          min: body[h * 2 + 1] & 0xFF,
        ),
    ];
  }

  /// Day-level max/min over hours that have data; both null when empty.
  static ({int? max, int? min}) dayRange(List<Spo2HourSample> samples) {
    var maxV = 0;
    var minV = 0xFF;
    var any = false;
    for (final s in samples) {
      for (final v in [s.max, s.min]) {
        if (v <= 0) continue;
        if (!any) {
          maxV = v;
          minV = v;
          any = true;
        } else {
          if (v > maxV) maxV = v;
          if (v < minV) minV = v;
        }
      }
    }
    if (!any) return (max: null, min: null);
    return (max: maxV, min: minV);
  }
}

/// One `0x2a` day entry after parse.
@immutable
class ActivityDayEntry {
  const ActivityDayEntry({required this.dayOffset, required this.samples});

  final int dayOffset;
  final List<Spo2HourSample> samples;
}
