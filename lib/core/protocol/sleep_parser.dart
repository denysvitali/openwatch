import 'dart:typed_data';

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
///     After that the frame carries one or more chained day blocks.
///     Each block:
///       bytes 0..1   endMinuteOfDay (u16 LE) — wake-up minute-of-day
///       bytes 2..N   alternating (stageByte, durMin) pairs
///     The block's start minute is derived: st = end - Σ(durMin).
///     `stageByte` is the Oudmon stage id; the mapping is documented
///     in [stageFor] below. Stages are emitted as [SleepStage]; pair
///     durations are minutes.
///   * Ch-B `[BC,3e,len,crc, …]`
///     Lunch/nap payload follows the same alternating shape: a u16 LE
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
  ///   * anything else (incl. `0x00`) → [SleepStage.awake] (defensive)
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
  /// Returns an empty list when [pl] is empty or shorter than the
  /// minimum block (2 B end-minute + 2 B one pair).
  static List<SleepSegment> parseNightSleepSegments(
    Uint8List pl, {
    required DateTime anchor,
  }) =>
      _parseChained(pl, anchor: anchor);

  /// Parses a `0x3e` lunch/nap-sleep payload. Same wire shape as the
  /// night variant; the only difference is the channel-B cmd id.
  static List<SleepSegment> parseLunchSleepSegments(
    Uint8List pl, {
    required DateTime anchor,
  }) =>
      _parseChained(pl, anchor: anchor);

  /// Walks [pl] as a sequence of chained day blocks; each block is
  /// `u16 LE endMin` + `(stageByte, durMin)*`. The first block may
  /// be preceded by a single day-offset byte (per PROTOCOL.md §4.4
  /// for the night frame) — we detect that heuristically by
  /// attempting to align the cursor on a `endMin ∈ 0..1439` bound.
  ///
  /// Alignment rule (defensive): if the very first byte would
  /// produce an out-of-range `endMin` when interpreted as u16 LE,
  /// we treat it as a day-offset prefix and skip one byte. This
  /// matches the v14 firmware behaviour (which DOES emit the
  /// leading dayOffset byte) without breaking older firmwares that
  /// omit it.
  static List<SleepSegment> _parseChained(
    Uint8List pl, {
    required DateTime anchor,
  }) {
    final out = <SleepSegment>[];
    if (pl.length < 4) return out;

    var i = 0;

    // Heuristic dayOffset skip: if reading a u16 LE at offset 0
    // produces an endMin outside the day window, treat the first
    // byte as a day-offset prefix and start at offset 1. We bound
    // the skip at 1 byte because the dayOffset field is exactly
    // 1 byte per PROTOCOL.md §4.4.
    final firstEnd = pl[0] | (pl[1] << 8);
    if (firstEnd > 24 * 60 - 1) {
      i = 1;
    }

    while (i + 2 <= pl.length) {
      final endMin = pl[i] | (pl[i + 1] << 8);
      i += 2;
      if (endMin > 24 * 60 - 1) {
        // Malformed end-minute — bail out cleanly so we don't
        // emit a garbage segment.
        break;
      }
      final pairs = <_SleepPair>[];
      while (i + 2 <= pl.length) {
        final stage = pl[i] & 0xFF;
        final dur = pl[i + 1] & 0xFF;
        i += 2;
        // A zero/zero pair is the natural terminator — older
        // firmwares pad the tail with NULs.
        if (stage == 0 && dur == 0) break;
        pairs.add(_SleepPair(stage, dur));
      }
      if (pairs.isEmpty) continue;

      // Compute the block's start minute by walking the pairs in
      // reverse (the wire order goes from wake → earlier segments
      // per Oudmon convention; total = endMin - startMin ⇒ startMin
      // = endMin - Σdur).
      var totalMin = 0;
      for (final p in pairs) {
        totalMin += p.durMin;
      }
      var stMin = endMin - totalMin;
      if (stMin < 0) stMin += 24 * 60; // wrap across midnight

      final dayBase = DateTime(anchor.year, anchor.month, anchor.day);
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
      default:
        return SleepStage.awake;
    }
  }
}

class _SleepPair {
  const _SleepPair(this.stageByte, this.durMin);
  final int stageByte;
  final int durMin;
}
