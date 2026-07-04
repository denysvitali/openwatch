import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import 'app_log.dart';
import 'history_store.dart';
import 'history_sync.dart' show BpRecordDay;

/// One row in the sidecar BP-raw store: the 13 raw bytes the watch
/// emitted for a single slot on a single day, plus the timestamp the
/// host assigned to that slot (derived from the header's day +
/// slot-index × slotDuration).
///
/// The per-byte meaning is on PROTOCOL.md §8.5 as "needs live
/// capture" — until a future live-capture session maps the fields,
/// we keep the bytes intact so the BP debug screen can dump them and
/// the bug report can quote them.
@immutable
class RawBpSlot {
  const RawBpSlot({
    required this.timestamp,
    required this.slotIndex,
    required this.bytes,
  });

  final DateTime timestamp;
  final int slotIndex;
  final Uint8List bytes;

  Map<String, dynamic> toJson() => {
    't': timestamp.toUtc().millisecondsSinceEpoch,
    'idx': slotIndex,
    // Encode as lowercase hex with no separators — `0xab`-style
    // is unambiguous, sortable, and survives copy/paste into
    // analysis tools that don't understand Flutter's Uint8List.
    'hex': _bytesToHex(bytes),
  };

  static RawBpSlot fromJson(Map<String, dynamic> j) => RawBpSlot(
    timestamp: DateTime.fromMillisecondsSinceEpoch(
      (j['t'] as num).toInt(),
      isUtc: true,
    ).toLocal(),
    slotIndex: (j['idx'] as num).toInt(),
    bytes: _hexToBytes(j['hex'] as String? ?? ''),
  );
}

String _bytesToHex(Uint8List b) {
  final sb = StringBuffer();
  for (final byte in b) {
    sb.write(byte.toRadixString(16).padLeft(2, '0'));
  }
  return sb.toString();
}

Uint8List _hexToBytes(String hex) {
  if (hex.isEmpty) return Uint8List(0);
  if (hex.length.isOdd) {
    AppLog.instance.warn('bp_raw', 'odd hex length, truncating: $hex');
  }
  final out = Uint8List(hex.length ~/ 2);
  for (var i = 0; i < out.length; i++) {
    out[i] = int.parse(hex.substring(i * 2, i * 2 + 2), radix: 16);
  }
  return out;
}

/// Sidecar store for raw 13-byte BP-history records.
///
/// Lives in a sibling `bp_raw/` directory next to `HistoryStore`'s
/// `history/` directory. The main store only knows about the
/// `BloodPressureSample` placeholder shape (timestamp + zero
/// systolic/diastolic). This store captures the *raw* bytes the
/// firmware emitted so a future live-capture session can immediately
/// look up "which byte is the systolic value" by reading a dump the
/// user has already collected.
///
/// The store is intentionally minimal: one JSON file per day, written
/// sequentially through a per-day queue (mirroring HistoryStore's
/// serialization pattern so a torn write can't poison the artifact).
class BpRawStore {
  BpRawStore._(this._dir);

  final Directory _dir;

  static Future<BpRawStore> open() async {
    final base = await getApplicationDocumentsDirectory();
    return openIn(Directory('${base.path}/bp_raw'));
  }

  /// Open a store rooted at [dir].
  ///
  /// Production callers use [open]; tests and tooling use this seam to
  /// exercise the real persistence path without depending on
  /// `path_provider`.
  static Future<BpRawStore> openIn(Directory dir) async {
    if (!await dir.exists()) await dir.create(recursive: true);
    return BpRawStore._(dir);
  }

  final Map<String, Future<void>> _writeQueue = {};

  File _fileFor(DateOnly day) => File('${_dir.path}/${day.iso}.json');

  /// Persist the 13-byte records for [day]. Existing entries are
  /// replaced — the BP record stream is idempotent (a re-sync of the
  /// same day replays the same 13-byte records), so merge is
  /// unnecessary and would risk mixing in stale bytes from a prior
  /// sync whose slot durations differed.
  Future<void> putDay(DateOnly day, BpRecordDay record) async {
    final dayKey = day.iso;
    final previous = _writeQueue[dayKey] ?? Future<void>.value();
    final next = previous.then((_) async {
      try {
        final payload = {
          'day': day.iso,
          'slotMinutes': record.slotDuration.inMinutes,
          // Schema version is *not* a per-write bump — it identifies
          // the on-disk layout. Bump only when the field set or
          // encoding changes.
          'schema': 1,
          'slots': [
            for (var i = 0; i < record.slots.length; i++)
              RawBpSlot(
                timestamp: record.day.midnight.add(record.slotDuration * i),
                slotIndex: i,
                bytes: record.slots[i],
              ).toJson(),
          ],
        };
        await _fileFor(day).writeAsString(jsonEncode(payload), flush: true);
      } catch (e, st) {
        AppLog.instance.warn('bp_raw', 'putDay($dayKey) failed: $e\n$st');
        rethrow;
      }
    });
    _writeQueue[dayKey] = next;
    next.whenComplete(() {
      if (identical(_writeQueue[dayKey], next)) {
        _writeQueue.remove(dayKey);
      }
    });
    return next;
  }

  /// Returns every day with a bp_raw artifact, sorted newest → oldest
  /// (so the most recent capture session is at the top of the debug
  /// screen).
  Future<List<DateOnly>> persistedDays() async {
    if (!await _dir.exists()) return const [];
    final files = await _dir
        .list()
        .where((e) => e is File && e.path.endsWith('.json'))
        .cast<File>()
        .toList();
    final out = <DateOnly>[];
    for (final f in files) {
      final name = f.uri.pathSegments.last.replaceAll('.json', '');
      final parsed = DateOnly.tryParseIso(name);
      if (parsed != null) out.add(parsed);
    }
    out.sort((a, b) => b.compareTo(a));
    return out;
  }

  /// Reads the raw slots for [day]. Returns an empty list when no
  /// artifact exists yet — callers can render a "no raw data" tile
  /// rather than crash.
  Future<RawBpDay> readDay(DateOnly day) async {
    final f = _fileFor(day);
    if (!await f.exists()) return RawBpDay.empty(day);
    try {
      final raw = await f.readAsString();
      if (raw.isEmpty) return RawBpDay.empty(day);
      final j = jsonDecode(raw) as Map<String, dynamic>;
      return RawBpDay.fromJson(j);
    } catch (e) {
      AppLog.instance.warn('bp_raw', 'readDay(${day.iso}) failed: $e');
      return RawBpDay.empty(day);
    }
  }
}

/// In-memory view of a single day's raw BP bytes. Decoupled from
/// [RawBpSlot] for callers (the debug screen) that just need the
/// day-level metadata + the list of slots.
@immutable
class RawBpDay {
  const RawBpDay({
    required this.day,
    required this.slotMinutes,
    required this.slots,
  });

  factory RawBpDay.empty(DateOnly day) =>
      RawBpDay(day: day, slotMinutes: 0, slots: const []);

  final DateOnly day;
  final int slotMinutes;
  final List<RawBpSlot> slots;

  bool get isEmpty => slots.isEmpty;

  static RawBpDay fromJson(Map<String, dynamic> j) {
    final iso = j['day'] as String? ?? '';
    final parsed = DateOnly.tryParseIso(iso);
    if (parsed == null) {
      throw FormatException('RawBpDay: invalid day "$iso"');
    }
    final raw = (j['slots'] as List?) ?? const [];
    return RawBpDay(
      day: parsed,
      slotMinutes: (j['slotMinutes'] as num?)?.toInt() ?? 0,
      slots: [
        for (final s in raw.cast<Map<String, dynamic>>()) RawBpSlot.fromJson(s),
      ],
    );
  }
}
