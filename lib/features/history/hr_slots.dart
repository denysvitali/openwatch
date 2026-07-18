import 'package:openwatch/core/protocol/hr_parser.dart';

/// Returns a deduplicated, slot-snapped view of [samples] covering
/// [start]..[end] (inclusive day boundaries). Slots are 5-minute
/// aligned. When multiple samples land in the same slot, the latest
/// is kept.
List<HrSample> clipAndDedupeHr(
  List<HrSample> samples,
  DateTime start,
  DateTime end,
) {
  final bySlot = <int, HrSample>{};
  for (final sample in samples) {
    final snapped = _snapToHrSlot(sample.timestamp);
    if (snapped.isBefore(start) || snapped.isAfter(end)) continue;
    final key = snapped.millisecondsSinceEpoch;
    final existing = bySlot[key];
    if (existing == null || sample.timestamp.isAfter(existing.timestamp)) {
      bySlot[key] = HrSample(snapped, sample.bpm);
    }
  }
  return bySlot.values.toList()
    ..sort((a, b) => a.timestamp.compareTo(b.timestamp));
}

DateTime _snapToHrSlot(DateTime t) =>
    DateTime(t.year, t.month, t.day, t.hour, (t.minute ~/ 5) * 5);
