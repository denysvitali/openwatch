import 'package:flutter/foundation.dart';

/// A single sleep segment (deep / light / awake / rem).
enum SleepStage { awake, light, deep, rem }

/// One contiguous block of a single sleep stage on the device side.
///
/// Wire format decomposes each sleep session into alternating
/// (stage, durMin) pairs (see [SleepParser]). The host stitches the
/// pairs back into a time-ordered list of [SleepSegment]s.
@immutable
class SleepSegment {
  const SleepSegment(this.start, this.duration, this.stage);
  final DateTime start;
  final Duration duration;
  final SleepStage stage;
}

/// Pure parsers for the Channel-B new-sleep-protocol responses
/// (`OpB.sleepNew = 0x27` night, `OpB.sleepLunchNew = 0x3e` lunch).
///
/// Wire format (see `PROTOCOL.md` §4.4 + `GHIDRA_DECOMPILATION.md` §2.3):
///
///   * Ch-B `[BC,27,len,crc,dayOffset, …]`
///     dayOffset = first byte of the *payload* (relative to the BC
///     container), i.e. the byte at index 0 of the parser input.
///     Always present — see `firmwares/GHIDRA_DECOMPILATION.md`
///     §2.3 (H59MA v13/v14 firmware) which packs the day-of-record as
///     the first byte of every record. After that the frame carries
///     one or more chained day blocks. Each block:
///       bytes 0..1   endMinuteOfDay (u16 **big-endian**) — wake-up
///                    minute-of-day. The Oudmon convention is BE; LE
///                    produces out-of-range values (e.g. `0x00 0x34`
///                    → 13312 instead of 52) for every observed
///                    H59MA trace.
///       bytes 2..N   alternating (stageByte, durMin) pairs
///     The block's start minute is derived: st = end - Σ(durMin).
///     `stageByte` is the Oudmon stage id; the mapping is documented
///     in [stageFor] below. Stages are emitted as [SleepStage]; pair
///     durations are minutes.
///   * Ch-B `[BC,3e,len,crc,payload]`
///     Lunch/nap payload **does not** carry the dayOffset prefix (only
///     `0x27` does). It is just the alternating shape: u16 **BE**
///     end-minute-of-day followed by (stage, durMin) pairs. We treat
///     it identically to the night shape for display purposes.
///   * Empty payload (the [OpB] byte is set but the body is empty)
///     means the watch has no sleep record for the requested day —
///     return an empty list rather than throwing.
///
/// The parser is intentionally defensive: any malformed block is
/// skipped, never partially emitted. The intent is that a host can
/// show "no data" without a crash if the watch sends an unfamiliar
/// variant (e.g. older firmware revisions).
class SleepParser {
  SleepParser._();

  /// Stage mapping from the Oudmon `type` byte. The exact byte values
  /// are not documented in the RE; this is the canonical Chinese-Oudmon
  /// convention observed across several OEM firmwares:
  ///
  ///   * `0x01` = light sleep
  ///   * `0x02` = deep sleep
  ///   * `0x03` = REM sleep
  ///   * `0x04` = awake (within the sleep window)
  ///   * anything else → inferred from the byte as a coarse
  ///     sleep-quality score (see [_toStage] below).
  ///
  /// The H59MA v13 firmware (and likely a handful of other Chinese-OEM
  /// firmwares reusing the Oudmon `SleepNewProto` wire shape — see
  /// `PROTOCOL.md` §4.4 + `firmwares/GHIDRA_DECOMPILATION.md` §2.3)
  /// emits stage bytes in the range `0x02..0x35` instead of the canonical
  /// `0x01..0x04`. Mapping those values to `awake` collapses every
  /// segment to red on the chart, which is the bug the user sees as
  /// "4h of sleep, all awake". Until a RE-grade spec lands we treat the
  /// byte as a movement/quality score:
  ///
  ///   * `0x00`          → awake (no data / explicit awake)
  ///   * `0x01..0x04`     → canonical Oudmon mapping (light/deep/rem/awake)
  ///   * `0x05..0x0f`     → deep    (low score ⇒ still)
  ///   * `0x10..0x1f`     → light   (some movement)
  ///   * `0x20..0x2f`     → rem     (more movement)
  ///   * `0x30..0xff`     → awake   (high score ⇒ moving)
  ///
  /// These ranges are deliberately conservative — the unknown case
  /// defaults to a *sleep* stage (light), which is more useful to the
  /// user than "always awake", and lets the chart show variation
  /// instead of a solid red bar.
  ///
  /// If a future firmware variant uses different ids the consumer can
  /// pass a custom mapping to [parseNightSleepSegments] /
  /// [parseLunchSleepSegments].
  static int stageFor(int typeByte) => typeByte & 0xFF;

  /// Parses a `0x27` night-sleep payload into [SleepStage] segments.
  ///
  /// [anchor] is the calendar day the record refers to — typically
  /// `DateTime.now()` truncated to midnight for the current day, or
  /// `today − dayOffset × 24 h` for an older record. The host is
  /// responsible for picking the right anchor; the parser only uses
  /// it to attach absolute timestamps to the segments.
  ///
  /// The night frame carries a 1-byte `dayOffset` prefix at
  /// `pl[0]` (per `PROTOCOL.md` §4.4 + H59MA v13/v14 RE — see
  /// `firmwares/GHIDRA_DECOMPILATION.md` §2.3). It is always
  /// present on H59MA firmware and is unconditionally stripped
  /// here so the chained-block walker sees a pure
  /// `(endMin, pairs…)` stream.
  ///
  /// Returns an empty list when [pl] is empty or shorter than the
  /// minimum block (1 B dayOffset + 2 B end-minute + 2 B one pair).
  static List<SleepSegment> parseNightSleepSegments(
    Uint8List pl, {
    required DateTime anchor,
  }) {
    if (pl.isEmpty) return const [];
    return _parseChained(pl.sublist(1), anchor: anchor);
  }

  /// Parses a `0x3e` lunch/nap-sleep payload. Same wire shape as the
  /// night variant; the only difference is the channel-B cmd id.
  static List<SleepSegment> parseLunchSleepSegments(
    Uint8List pl, {
    required DateTime anchor,
  }) => _parseChained(pl, anchor: anchor);

  /// Walks [pl] as a sequence of chained day blocks; each block is
  /// `u16 BE endMin` + `(stageByte, durMin)*`.
  ///
  /// For the night frame (`0x27`) the very first byte of [pl] is the
  /// `dayOffset` prefix from `PROTOCOL.md` §4.4 (always present on
  /// H59MA v13/v14 — see `firmwares/GHIDRA_DECOMPILATION.md` §2.3)
  /// and is unconditionally skipped. The lunch frame (`0x3e`) has
  /// **no** dayOffset prefix, so the caller (`parseNightSleepSegments`)
  /// must NOT strip the leading byte — `parseLunchSleepSegments`
  /// therefore just delegates here with the byte still in place
  /// (its payload is a pure endMin+pairs blob).
  static List<SleepSegment> _parseChained(
    Uint8List pl, {
    required DateTime anchor,
  }) {
    final out = <SleepSegment>[];
    if (pl.length < 4) return out;

    var i = 0;

    while (i + 2 <= pl.length) {
      // u16 big-endian: high byte first. The Oudmon SDK and the
      // H59MA firmware both pack the wake-up minute-of-day in BE;
      // reading LE here produces nonsense values (e.g. `0x00 0x34`
      // would decode to 13312 instead of the valid 52).
      final endMin = (pl[i] << 8) | pl[i + 1];
      i += 2;
      if (endMin > 24 * 60 - 1) {
        // Malformed end-minute — bail out cleanly so we don't
        // emit a garbage segment.
        break;
      }
      final pairs = <_SleepPair>[];
      var terminated = false;
      while (i + 2 <= pl.length) {
        final stage = pl[i] & 0xFF;
        final dur = pl[i + 1] & 0xFF;
        i += 2;
        // A zero/zero pair is the natural terminator — older
        // firmwares pad the tail with NULs.
        if (stage == 0 && dur == 0) {
          terminated = true;
          break;
        }
        pairs.add(_SleepPair(stage, dur));
      }
      // If we ran out of bytes before reading any pairs (and did not
      // hit a zero/zero terminator), the remaining bytes are trailing
      // garbage — do NOT continue and re-align on them, which would
      // misinterpret pair bytes as a new endMin. (SP-1)
      if (pairs.isEmpty) {
        if (!terminated) break;
        continue;
      }

      // Compute the block's start minute by walking the pairs in
      // reverse (the wire order goes from wake → earlier segments
      // per Oudmon convention; total = endMin - startMin ⇒ startMin
      // = endMin - Σdur).
      var totalMin = 0;
      for (final p in pairs) {
        totalMin += p.durMin;
      }
      // Defensive clamp: the H59MA v13 firmware sometimes echoes the
      // previous day's record into the current response (stale buffer),
      // producing a single "block" with 14+ hours of sleep. Reject the
      // whole block rather than filing a day with an impossible total.
      // 20 hours is well above normal human sleep and catches the
      // observed echo without clipping legitimate long sleeps.
      const kMaxSleepSessionMinutes = 20 * 60;
      if (totalMin > kMaxSleepSessionMinutes) {
        continue;
      }
      var stMin = endMin - totalMin;
      // Wrap across midnight AND shift the segment date to the
      // bedtime day. The H59MA v13 firmware stores night sleep on
      // the wake-up day (the morning the user wakes up), so a block
      // ending at 01:23 with 290 min of total duration starts at
      // 20:33 the previous evening. Users expect this to be the
      // "night of <bedtime day>" — without the shift, the segment
      // shows up under the wake-up day with a start timestamp that
      // belongs to the previous calendar date.
      //
      // All sleep timestamps are in local wall-clock time.  When
      // wrapping midnight we must account for DST transitions: a day
      // can be 23 h or 25 h long, so we compute the actual minute
      // count of the previous calendar day instead of assuming a
      // fixed 1440-minute day.
      var dayBase = DateTime(anchor.year, anchor.month, anchor.day);
      if (stMin < 0) {
        final prevDay = dayBase.subtract(const Duration(days: 1));
        final prevDayMinutes = dayBase.difference(prevDay).inMinutes;
        stMin += prevDayMinutes;
        dayBase = prevDay;
      }
      for (final p in pairs) {
        final start = dayBase.add(Duration(minutes: stMin));
        out.add(
          SleepSegment(
            start,
            Duration(minutes: p.durMin),
            _toStage(p.stageByte),
          ),
        );
        stMin += p.durMin;
      }

      // Chained-block terminator: if we exited the pair loop on a
      // zero/zero terminator, advance past it. Otherwise the
      // outer while will re-attempt alignment with the next
      // two-byte window — which works as long as the firmware
      // actually emits the (stage, dur) tuples contiguously.
    }
    return out;
  }

  static SleepStage _toStage(int typeByte) {
    switch (typeByte) {
      case 0x01:
        return SleepStage.light;
      case 0x02:
        return SleepStage.deep;
      case 0x03:
        return SleepStage.rem;
      case 0x04:
        return SleepStage.awake;
      // Defensive default for stage bytes outside the canonical
      // Oudmon 0x01..0x04 set. The H59MA v13 firmware uses
      // 0x05..0x35 to encode a coarse sleep-quality score; we
      // map by range rather than collapsing every unknown to
      // awake (which previously made the sleep chart a solid red
      // bar). See the [stageFor] doc-comment above for the full
      // rationale.
      case 0x00:
        return SleepStage.awake;
      default:
        if (typeByte <= 0x0f) return SleepStage.deep;
        if (typeByte <= 0x1f) return SleepStage.light;
        if (typeByte <= 0x2f) return SleepStage.rem;
        return SleepStage.awake;
    }
  }
}

class _SleepPair {
  const _SleepPair(this.stageByte, this.durMin);
  final int stageByte;
  final int durMin;
}
