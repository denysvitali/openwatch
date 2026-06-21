import 'package:flutter/foundation.dart';

import '../services/app_log.dart';

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
    if (pl.isEmpty) {
      AppLog.instance.debug('sleep', 'night payload empty — no sleep record');
      return const [];
    }
    return _parseChained(pl.sublist(1), anchor: anchor, source: 'night');
  }

  /// Parses a `0x3e` lunch/nap-sleep payload. Same wire shape as the
  /// night variant; the only difference is the channel-B cmd id.
  static List<SleepSegment> parseLunchSleepSegments(
    Uint8List pl, {
    required DateTime anchor,
  }) => _parseChained(pl, anchor: anchor, source: 'lunch');

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
    required String source,
  }) {
    final out = <SleepSegment>[];
    if (pl.length < 2) {
      // The shortest possible block is just a u16 endMinute with no
      // pairs. Anything shorter cannot even contain the header.
      // Log at warn so telemetry can detect firmware sending unexpectedly
      // short sleep payloads (SP-4).
      AppLog.instance.warn(
        'sleep',
        '$source payload too short for chained block '
            '(len=${pl.length}, need>=2)',
      );
      return out;
    }

    var i = 0;

    // Track the most recent non-empty block so we can detect a stale
    // echo that has been concatenated without a terminator. The H59MA
    // v13 firmware sometimes appends yesterday's record to today's
    // response; the bogus block starts with an endMin that is earlier
    // than the genuine block's endMin and is not preceded by NUL/NUL.
    int? lastBlockEndMin;
    var lastBlockWasTerminated = false;

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

      // Detect concatenated stale echoes: a new block that starts
      // without a terminator and has an endMin earlier than the
      // previous real block is almost certainly leaked data.
      final prevEndMin = lastBlockEndMin;
      if (prevEndMin != null &&
          endMin < prevEndMin &&
          !lastBlockWasTerminated) {
        // Skip the stale block entirely, but still consume its bytes
        // so the loop terminates.
        final consumed = _skipStaleBlock(pl, i);
        if (consumed == null) {
          // Could not determine where the stale block ends — stop
          // parsing to avoid emitting garbage.
          break;
        }
        i += consumed;
        continue;
      }

      final pairs = <_SleepPair>[];
      var terminated = false;
      while (i + 2 <= pl.length) {
        final stage = pl[i] & 0xFF;
        final dur = pl[i + 1] & 0xFF;

        // A zero/zero pair is the natural terminator — older
        // firmwares pad the tail with NULs.
        if (stage == 0 && dur == 0) {
          terminated = true;
          i += 2;
          break;
        }

        final candidateEndMin = (stage << 8) | dur;
        if (candidateEndMin <= 24 * 60 - 1) {
          // The next two bytes could be a pair, or they could be the
          // start of a new day block. Decide based on context:
          //
          //  * If we have not read any pairs yet, this current "block"
          //    is empty. Treat the bytes as the next block only when
          //    their endMin is later than ours — otherwise a block
          //    that legitimately starts with a short awake segment
          //    would be swallowed. (SP-1 / SP-5)
          //
          //  * If we have already read pairs, treat the bytes as a
          //    new block only when their endMin is earlier than ours.
          //    That is the signature of a stale echo concatenated
          //    onto a genuine block. (SP-2)
          if (pairs.isEmpty) {
            // Empty-block re-alignment: the next two bytes could be a
            // pair (stage=0..N, dur) or the header of the next block.
            // We only treat them as a header when the high byte is 0
            // (so the value is a small endMinute) and the value is
            // later than the current block's endMin. This avoids
            // swallowing legitimate blocks whose first pair happens
            // to decode to a u16 > endMin.
            if (pl[i] == 0 && candidateEndMin > endMin) {
              // Empty block followed by a later block — skip the empty
              // one and re-align on the next header.
              break;
            }
          } else if (candidateEndMin < endMin) {
            // Genuine block followed by an earlier endMin without a
            // terminator — stale echo. Stop the current block here.
            break;
          }
        }

        pairs.add(_SleepPair(stage, dur));
        i += 2;
      }

      // Empty block: either a no-data sentinel (endMin == 0) or a
      // malformed block with no pairs. Skip it and keep walking the
      // chain so a subsequent valid block is still parsed. (SP-1, SP-5)
      if (pairs.isEmpty) {
        lastBlockWasTerminated = terminated;
        // lastBlockEndMin is intentionally left unchanged — an empty
        // block should not influence stale-echo detection.
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
      if (totalMin >= kMaxSleepSessionMinutes) {
        lastBlockEndMin = endMin;
        lastBlockWasTerminated = terminated;
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
      // wrapping midnight we account for DST transitions by computing
      // the actual minute count of the previous calendar day instead
      // of assuming a fixed 1440-minute day. On hosts without DST
      // (e.g. CI) this naturally falls back to 1440.
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

      lastBlockEndMin = endMin;
      lastBlockWasTerminated = terminated;
    }
    return out;
  }

  /// Consumes a stale-echo block starting at [offset] in [pl].
  ///
  /// Returns the number of bytes to advance past the stale block, or
  /// `null` if the block cannot be bounded safely. The stale block is
  /// parsed like a normal block: it runs until the next plausible
  /// block header that is earlier than the current one, a terminator,
  /// or the end of the payload.
  static int? _skipStaleBlock(Uint8List pl, int offset) {
    var i = offset;
    var lastEndMin = -1;
    while (i + 2 <= pl.length) {
      final endMin = (pl[i] << 8) | pl[i + 1];
      if (endMin > 24 * 60 - 1) return null;
      if (lastEndMin >= 0 && endMin < lastEndMin) {
        // Next stale block starts here; stop before it.
        return i - offset;
      }
      lastEndMin = endMin;
      i += 2;

      var terminated = false;
      while (i + 2 <= pl.length) {
        final stage = pl[i] & 0xFF;
        final dur = pl[i + 1] & 0xFF;
        if (stage == 0 && dur == 0) {
          terminated = true;
          i += 2;
          break;
        }
        final candidate = (stage << 8) | dur;
        if (candidate <= 24 * 60 - 1 && candidate < endMin) {
          break;
        }
        i += 2;
      }
      if (terminated) return i - offset;
      // If we did not see a terminator, keep walking — the stale echo
      // may itself contain nested echoes.
    }
    return i - offset;
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
