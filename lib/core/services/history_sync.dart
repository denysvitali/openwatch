import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';

import '../ble/ble_transport.dart';
import '../protocol/channel_a.dart';
import '../protocol/channel_b.dart';
import '../protocol/codec.dart';
import '../protocol/commands.dart';
import '../protocol/fragment_reassembler.dart';
import '../protocol/opcodes.dart';
import '../protocol/sleep_parser.dart';
import 'app_log.dart';
import 'history_store.dart';
import 'opentelemetry_service.dart';

// Re-export sleep model types so existing consumers can keep importing
// them from `history_sync.dart` after the move to `sleep_parser.dart`.
export '../protocol/sleep_parser.dart' show SleepSegment, SleepStage;
export 'history_store.dart' show DateOnly, DailyHistory;

/// A 5-minute HR sample.
@immutable
class HrSample {
  const HrSample(this.timestamp, this.bpm);
  final DateTime timestamp;
  final int bpm;
}

/// A fixed-slot scalar health sample such as stress or HRV.
@immutable
class HealthMetricSample {
  const HealthMetricSample(this.timestamp, this.value);
  final DateTime timestamp;
  final int value;
}

/// A blood-pressure sample.
@immutable
class BloodPressureSample {
  const BloodPressureSample({
    required this.timestamp,
    required this.systolic,
    required this.diastolic,
  });

  final DateTime timestamp;
  final int systolic;
  final int diastolic;
}

/// An assembled `0x37` stress-history record (GHIDRA §3.20).
///
/// The firmware fragments each `FUN_008344fe` read into a single
/// header frame + four 13-byte payload chunks via `FUN_0082c988`.
/// [FragmentReassembler] collects the chunks and we surface the
/// raw 4-byte producer header + up-to-48-byte body. The exact
/// 4-byte header shape is not documented in the RE — structured
/// decode is a follow-up; for now callers should treat [header]
/// as opaque.
@immutable
class PressureRecord {
  const PressureRecord({
    required this.slotId,
    required this.header,
    required this.body,
  });

  /// Echo of `req[1]` from the stress-history request (today = 0,
  /// yesterday = 1, ...). See GHIDRA §3.20.
  final int slotId;

  /// First 4 bytes of the assembled payload — the producer header
  /// (`FUN_008344fe` writes `*r` into `out[0..3]`).
  final Uint8List header;

  /// Remaining bytes (up to 48) — the null-terminated body.
  final Uint8List body;
}

/// An assembled `0x39` HRV history record (GHIDRA §3.21).
///
/// Structurally identical to [PressureRecord] but sourced from
/// `FUN_0083468e` and the HRV record table
/// (`DAT_008347dc` / `*DAT_008347d8`).
@immutable
class HrvRecord {
  const HrvRecord({
    required this.slotId,
    required this.header,
    required this.body,
  });

  /// Echo of `req[1]` from the HRV history request (today = 0,
  /// yesterday = 1, ...). See GHIDRA §3.21.
  final int slotId;

  /// First 4 bytes of the assembled payload — the producer header.
  final Uint8List header;

  /// Remaining bytes (up to 48) — the null-terminated body.
  final Uint8List body;
}

/// A queued inbound Channel-A frame paired with the [DateOnly] day it
/// was captured for.  Day is snapshotted from [_currentSyncDay] at
/// enqueue time so that late frames are still attributed to the
/// correct day even after the sync loop has moved on (HS-8).
@immutable
class _RxEntry {
  const _RxEntry(this.frame, this.day);
  final Uint8List frame;
  final DateOnly? day;
}

/// Day-aligned totals for the activity ring on the dashboard.
///
/// All fields are nullable so that `null` means "no data from the watch"
/// and `0` means "the watch reported zero" — distinguishing a fresh day
/// (e.g. after midnight) from a day that simply has no activity summary.
@immutable
class DailyTotals {
  const DailyTotals({this.steps, this.calories, this.distanceMeters});
  final int? steps;
  final int? calories;
  final int? distanceMeters;
}

/// One raw Channel-B `0x2a` activity-summary entry (GHIDRA §2.8).
@immutable
class ActivitySummaryRecord {
  const ActivitySummaryRecord({
    required this.day,
    required this.dayOffset,
    required this.body,
    required this.totals,
  });

  final DateOnly day;
  final int dayOffset;

  /// The 48-byte producer-owned activity body with `0xff` bytes normalised
  /// to `0x00`, matching the firmware's compression convention.
  final Uint8List body;

  /// Best-effort totals decoded from the first TodaySport-shaped groups.
  final DailyTotals totals;
}

/// Pulls historical data from the watch. Uses the watch's data distribution
/// bitmask to know which days have data, then requests HR, sleep, and
/// activity summaries per day.
///
/// Multi-packet responses are reassembled here (the SDK does this in Java;
/// the original payload layout is 13 bytes per sample at 5-min slots).
///
/// **Local-first**: when a [HistoryStore] is supplied, fetched samples are
/// persisted to disk as they arrive, the store's per-day data is loaded
/// into memory on startup, and subsequent [syncAll] calls only re-fetch
/// days the watch says have new data AND we haven't already stored. The
/// watermark is bumped only after a successful pass so a partial sync
/// (transport drop, etc.) leaves previously-stored data intact and the
/// next sync picks up where we left off.
class HistorySync extends ChangeNotifier {
  HistorySync(
    this.transport,
    this.onTotals, {
    ChannelADispatcher? dispatcher,
    ChannelBParser? bParser,
    HistoryStore? store,
    this.drainDuration = const Duration(milliseconds: 600),
    this.postCommandDelay = const Duration(milliseconds: 50),
    this.fragmentQuietWindow = const Duration(milliseconds: 250),
    DateTime Function()? clock,
  }) : _dispatcher = dispatcher,
       _bParser = bParser,
       _store = store,
       _clock = clock ?? DateTime.now {
    _inbound = transport.inboundA.listen(_collectRx);
    // Channel-B sleep responses (`0x27` night + `0x3e` lunch per
    // PROTOCOL.md §4.4) only flow through the BC-fragmented
    // transport — the inboundA listener can't see them. Subscribe
    // to the parser's reassembled stream when one is provided.
    final p = _bParser;
    if (p != null) {
      _bCmdSub = p.commands.listen(_onChannelBCommand);
    }
    _ensureMetricRecordListeners();
  }

  /// Settle window used after each command before draining the RX queue.
  /// Configurable so tests can run with short artificial delays.
  final Duration drainDuration;

  /// Short extra delay after draining before moving to the next command.
  final Duration postCommandDelay;

  /// Quiet window passed to the stress/HRV fragment reassemblers.
  final Duration fragmentQuietWindow;
  final BleTransport transport;
  final ChannelADispatcher? _dispatcher;
  final ChannelBParser? _bParser;
  HistoryStore? _store;
  final DateTime Function() _clock;
  final void Function(DailyTotals) onTotals;
  StreamSubscription<ChannelBCommand>? _bCmdSub;

  /// In-memory mirror of the persisted store, keyed by [DateOnly]. Hydrated
  /// by [loadFromStore]; updated in-place by [syncAll] as new samples
  /// arrive. The single source of truth for the UI.
  final Map<DateOnly, DailyHistory> _days = {};

  final List<HrSample> _hr = [];
  final List<SleepSegment> _sleep = [];
  final List<ActivitySummaryRecord> _activity = [];

  /// The day the current in-flight HR chunk series belongs to. Captured
  /// when the 0x15 header (pl[0] == 0x18) arrives so that late chunks
  /// are still attributed to the original poll day even after the sync
  /// loop has moved on to another day (HS-8).
  DateOnly? _hrChunkDay;
  final Set<int> _availableDays = {};
  final Map<DateOnly, DailyTotals> _sportDetailTotals = {};

  /// Days for which the watch reported data during the most recent
  /// [syncAll] — used by the UI to render the availability ribbon.
  final Set<DateOnly> _watchDaysWithData = {};

  /// Days that were actually re-fetched in the most recent [syncAll].
  /// The UI can highlight these so the user sees exactly what changed.
  final Set<DateOnly> _fetchedDays = {};

  // FragmentReassemblers for the two-phase `0x37` stress history (§3.20)
  // and `0x39` HRV history (§3.21) streams. They are still allocated
  // through the public getters, but HistorySync subscribes during
  // construction when a dispatcher is present so sync results land in
  // DailyHistory without a UI-side listener.
  FragmentReassembler<
    PressureSettingHeader,
    PressureSettingChunk,
    PressureRecord
  >?
  _pressureReassembler;
  FragmentReassembler<HrvSettingHeader, HrvSettingChunk, HrvRecord>?
  _hrvReassembler;
  StreamSubscription<PressureRecord>? _pressureRecordsSub;
  StreamSubscription<HrvRecord>? _hrvRecordsSub;
  static const _hrSlotDuration = Duration(minutes: 5);

  /// Broadcast stream of assembled
  /// `0x37` stress history records. Wires [FragmentReassembler]
  /// against `dispatcher.onPressureSettingHeader` /
  /// `dispatcher.onPressureSettingChunk` when first created. The
  /// quiet window is 250 ms (matches the helper default) —
  /// short enough for responsive UI, long enough to coalesce
  /// the 4-chunk sequence the firmware emits. Requires the
  /// HistorySync to have been constructed with a non-null
  /// [dispatcher].
  Stream<PressureRecord> get pressureRecords {
    final r = _pressureReassembler;
    if (r != null) return r.assembled;
    final dispatcher = _dispatcher;
    if (dispatcher == null) {
      throw StateError(
        'HistorySync.pressureRecords requires a ChannelADispatcher',
      );
    }
    final reassembler =
        FragmentReassembler<
          PressureSettingHeader,
          PressureSettingChunk,
          PressureRecord
        >(
          headers: dispatcher.onPressureSettingHeader,
          chunks: dispatcher.onPressureSettingChunk,
          build: (header, payload) => PressureRecord(
            slotId: header.slotId,
            header: Uint8List.sublistView(
              payload,
              0,
              payload.length < 4 ? payload.length : 4,
            ),
            body: Uint8List.sublistView(
              payload,
              payload.length < 4 ? payload.length : 4,
              payload.length,
            ),
          ),
          quietWindow: fragmentQuietWindow,
        );
    _pressureReassembler = reassembler;
    return reassembler.assembled;
  }

  /// Broadcast stream of assembled
  /// `0x39` HRV history records. Same reassembly semantics as
  /// [pressureRecords]; see GHIDRA §3.21.
  Stream<HrvRecord> get hrvRecords {
    final r = _hrvReassembler;
    if (r != null) return r.assembled;
    final dispatcher = _dispatcher;
    if (dispatcher == null) {
      throw StateError('HistorySync.hrvRecords requires a ChannelADispatcher');
    }
    final reassembler =
        FragmentReassembler<HrvSettingHeader, HrvSettingChunk, HrvRecord>(
          headers: dispatcher.onHrvHeader,
          chunks: dispatcher.onHrvChunk,
          build: (header, payload) => HrvRecord(
            slotId: header.slotId,
            header: Uint8List.sublistView(
              payload,
              0,
              payload.length < 4 ? payload.length : 4,
            ),
            body: Uint8List.sublistView(
              payload,
              payload.length < 4 ? payload.length : 4,
              payload.length,
            ),
          ),
          quietWindow: fragmentQuietWindow,
        );
    _hrvReassembler = reassembler;
    return reassembler.assembled;
  }

  void _ensureMetricRecordListeners() {
    if (_dispatcher == null) return;
    _pressureRecordsSub ??= pressureRecords.listen(_onStressRecord);
    _hrvRecordsSub ??= hrvRecords.listen(_onHrvRecord);
  }

  List<HrSample> get hr => List.unmodifiable(_hr);
  List<SleepSegment> get sleep => List.unmodifiable(_sleep);
  List<ActivitySummaryRecord> get activity => List.unmodifiable(_activity);
  Set<int> get availableDays => Set.unmodifiable(_availableDays);

  /// Days the watch reported as having data during the most recent sync.
  /// Empty until the first sync completes — UI should treat that as
  /// "unknown" and not as "no data".
  Set<DateOnly> get watchDaysWithData => Set.unmodifiable(_watchDaysWithData);

  /// Days that were actually fetched during the most recent sync.
  /// A subset of [watchDaysWithData] — only days we didn't already
  /// have persisted are re-fetched.
  Set<DateOnly> get fetchedDays => Set.unmodifiable(_fetchedDays);

  /// Snapshot of every persisted day, sorted oldest → newest.
  List<DailyHistory> get days {
    final list = _days.values.toList()..sort((a, b) => a.day.compareTo(b.day));
    return List.unmodifiable(list);
  }

  /// Convenience accessor for one day's record. Returns null when the
  /// store has nothing for [day] — callers should render an empty card
  /// rather than throw.
  DailyHistory? dayOf(DateOnly day) => _days[day];

  /// Most recent [lastSyncedAt] from the persistent store. Null until
  /// the first successful sync persists a watermark.
  DateTime? get lastSyncedAt => _store?.lastSyncedAt;

  bool _syncing = false;
  bool get syncing => _syncing;

  /// Last sync error message — null when the most recent sync succeeded
  /// (or no sync has been attempted yet). Cleared at the start of each
  /// [syncAll] call.
  String? lastSyncError;

  /// Sync progress as `(current, total)`. `current` is the index of the
  /// day currently being fetched (1-based); `total` is the number of
  /// days that will be re-fetched this pass. Zero / zero when idle.
  int _progressCurrent = 0;
  int _progressTotal = 0;
  int get progressCurrent => _progressCurrent;
  int get progressTotal => _progressTotal;

  StreamSubscription<Uint8List>? _inbound;

  /// One queued inbound Channel-A frame together with the sync-day it
  /// belongs to, captured at the moment the frame arrives.  This removes
  /// the HS-8 race where a late HR frame could be mis-attributed to a
  /// later sleep/activity day because [_currentSyncDay] had already
  /// moved on.
  final List<_RxEntry> _rxQueue = [];

  /// The day the in-flight HR chunks belong to. Set just before we send
  /// `0x15` for a given day; consumed by [_flushHrChunks]. Channel-B
  /// sleep commands carry their own day offset so they don't need this.
  DateOnly? _currentSyncDay;

  /// Hydrate the in-memory cache from the persistent store. Safe to call
  /// more than once — the latest store snapshot wins.
  ///
  /// When no [HistoryStore] is wired (legacy test scenarios) this is a
  /// no-op so existing call sites don't have to special-case it.
  Future<void> loadFromStore() async {
    final store = _store;
    if (store == null) return;
    final persisted = await store.persistedDays();
    // The latest store snapshot wins; drop any in-memory days that no
    // longer exist on disk (e.g. after clearAll) so they don't leak forever.
    _days.clear();
    for (final d in persisted) {
      _days[d] = await store.readDay(d);
    }
    _hr
      ..clear()
      ..addAll(_days.values.expand((d) => d.hr));
    _hr.sort((a, b) => a.timestamp.compareTo(b.timestamp));
    _sleep
      ..clear()
      ..addAll(_days.values.expand((d) => d.sleep));
    _sleep.sort((a, b) => a.start.compareTo(b.start));
    notifyListeners();
  }

  /// Late-binds a [HistoryStore] and hydrates the in-memory cache from
  /// it. Idempotent — calling it again with the same store is a no-op,
  /// calling it with a new store re-reads the disk.
  Future<void> bindStore(HistoryStore store) async {
    if (identical(_store, store)) return;
    if (_syncing) {
      AppLog.instance.warn('history', 'bindStore deferred: sync in progress');
      return;
    }
    _store = store;
    await loadFromStore();
  }

  /// Trigger a sync. When a [HistoryStore] is wired:
  ///   * in-memory cache is hydrated from disk on first call;
  ///   * the watch's distribution bitmask is queried for which days
  ///     have data;
  ///   * **delta sync per metric** — each metric (HR, stress, HRV,
  ///     sleep, activity) is only re-fetched for days the store has
  ///     not already ingested that metric for. Today is always
  ///     re-fetched because it can carry samples from sessions that
  ///     started in a previous calendar day (overnight sleep, late
  ///     HR, etc.) and may have grown since the previous sync;
  ///   * pass [force] `true` to ignore the per-metric skip rule and
  ///     re-fetch every day in range (useful when the user wants to
  ///     re-pull data after a suspected corruption or after manually
  ///     clearing a day).
  ///   * each day's HR + sleep samples are persisted as they land;
  ///   * the sync watermark is bumped only on a clean pass.
  ///
  /// Without a store, behaves like the legacy in-memory sync (clears
  /// the lists, refetches every requested day). [daysBack] caps how
  /// far into the past we look at the distribution bitmask — the
  /// bitmask is a 32-day window so values above 32 are clamped.
  Future<void> syncAll({int daysBack = 7, bool force = false}) async {
    if (_syncing) return;

    final effectiveDaysBack = daysBack.clamp(1, 32).toInt();
    // Top-level span covering the full sync pass — distribution bitmask,
    // per-day HR + sleep polls, and the watermark bump. Ends in finally
    // so partial failures still flush.
    final syncSpan = OpenTelemetryService().startTrace(
      'sync.history',
      attributes: {'sync.days_back': effectiveDaysBack},
    );
    var fetched = 0;
    Object? caughtError;
    StackTrace? caughtTrace;
    try {
      // Move all state-mutating setup inside the try so any throw
      // (including from [notifyListeners]) is caught and [_syncing] is
      // always reset in the outer finally. Without this, a disposed
      // listener throwing during the initial notify would leave
      // [_syncing] true forever and block every future sync.
      _syncing = true;
      lastSyncError = null;
      _rxQueue.clear();
      _hr.clear();
      _sleep.clear();
      _activity.clear();
      _availableDays.clear();
      _sportDetailTotals.clear();
      _sportDetailPageState.clear();
      _watchDaysWithData.clear();
      _fetchedDays.clear();
      _hrChunks.clear();
      _hrExpectedChunks = null;
      _hrChunkDay = null;
      _hrChunk1Received = false;
      _progressCurrent = 0;
      _progressTotal = 0;
      notifyListeners();

      AppLog.instance.info(
        'history',
        'Sync start (last $effectiveDaysBack days, store=${_store != null}, force=$force)',
      );
      Future<void> runBody() => _syncAllBody(
        effectiveDaysBack,
        force: force,
        onFetched: (i) => fetched = i,
      );
      if (syncSpan == null) {
        await runBody();
      } else {
        await OpenTelemetryService().withActiveSpan(syncSpan, () async {
          await runBody();
        });
      }
    } catch (e, st) {
      // Mirror the legacy swallow — the original method never threw,
      // it surfaced failures via [lastSyncError] only.
      lastSyncError = e.toString();
      AppLog.instance.error('history', 'Sync failed: $e');
      caughtError = e;
      caughtTrace = st;
    } finally {
      _syncing = false;
      syncSpan?.setAttribute('sync.days_fetched', fetched);
      syncSpan?.setAttribute('sync.days_total', _fetchedDays.length);
      if (caughtError != null) {
        syncSpan?.recordError(caughtError, caughtTrace);
        syncSpan?.end(ok: false);
      } else {
        syncSpan?.end();
      }
    }
  }

  /// Inner body of [syncAll] — split out so the OTel span can be
  /// active around the full try/catch without polluting the public
  /// method signature.
  Future<void> _syncAllBody(
    int effectiveDaysBack, {
    required bool force,
    required void Function(int) onFetched,
  }) async {
    try {
      // Hydrate from disk so we don't drop already-stored data even
      // if the watch drops the link halfway through a re-fetch.
      await loadFromStore();

      // NOTE: 0x46 (`queryDataDistribution`) is a **watch→phone notify
      // only** opcode per PROTOCOL.md §4.6 — no host→watch request
      // exists. The previous implementation sent a bare 0x46 and the
      // firmware replied with `0xC6 ERR 0xee`, forcing the
      // `_distributionFailed` fallback on every handshake. We instead
      // rely on the unsolicited Channel-B 0x27 / 0x2a / 0x3e pushes
      // the watch emits when ready, plus a bounded blind-poll of the
      // last `effectiveDaysBack` days for anything that hasn't surfaced.
      // The watch's dayOffset for activity summaries is clamped to ≤2,
      // so the per-day reads (0x15 HR / 0x2a activity / 0x27 sleep)
      // remain the source of truth for older history.
      AppLog.instance.debug(
        'history',
        'sync start: relying on unsolicited Channel-B pushes + '
            'bounded blind-poll of last $effectiveDaysBack day(s)',
      );

      // The watch expects a UTC day-start timestamp for 0x15 HR history.
      // Live H59MAX firmware replies 0xff to packed BCD dates such as
      // `26 06 21 00`; `Commands.readHeartRateHistory` converts the
      // DateOnly-style day to epoch seconds.
      final today = _clock();
      final todayD = DateOnly.fromDateTime(today);
      // Always blind-poll the last `effectiveDaysBack` days; the
      // watch's per-day reads are idempotent and `HistoryStore.merge*`
      // dedupes on timestamp / start.ms, so re-pulling a day we
      // already have is wasted bytes only — never a wrong write.
      final wantsDays = <int>{for (var d = 0; d < effectiveDaysBack; d++) d};

      // Pre-compute the days we'll actually fetch so the UI can
      // render an accurate progress fraction. The per-metric helper
      // is the single source of truth for the "skip if already
      // ingested" rule — stress/HRV/sleep reuse it with the
      // appropriate predicate. Today is always re-fetched (overnight
      // sessions, trailing HR samples, etc.).
      final hrToFetch = _daysToFetch(
        wantsDays,
        todayD,
        metric: 'hr',
        hasData: (h) => h.hr.isNotEmpty,
        force: force,
      );
      _progressTotal = hrToFetch.length;
      _progressCurrent = 0;
      notifyListeners();

      var fetched = 0;
      for (final d in hrToFetch) {
        // Per-day child span — one full HR poll per day. Parent
        // (sync.history) is auto-inherited via currentSpan.
        final daySpan = OpenTelemetryService().startChildSpan(
          'sync.history.day',
          attributes: {'sync.day_offset': d},
        );
        try {
          final day = todayD.addDays(-d);
          daySpan?.setAttribute('sync.day.iso', day.iso);
          _fetchedDays.add(day);
          fetched++;
          onFetched(fetched);
          // Stage an empty record so the UI sees the day even if the
          // watch has nothing in it (error frame).
          _days.putIfAbsent(day, () => DailyHistory(day: day));
          _currentSyncDay = day;
          _progressCurrent = fetched;
          notifyListeners();
          await transport.sendA(
            // readHeartRateHistory only uses the calendar components and
            // sends DateTime.utc(year, month, day) as seconds since epoch.
            Commands.readHeartRateHistory(day: day.midnight),
          );
          await _drainRx(drainDuration);
          // Drain any sleep segments that came back on Channel B as
          // part of this day's poll. The parser may emit a few frames
          // after the per-day drain — [_onChannelBCommand] will
          // append them and notify.  Keep _currentSyncDay alive until
          // after the post-command delay so that any late HR chunks
          // arriving on Channel A are still attributed to the correct
          // day (HS-4).
          await Future<void>.delayed(postCommandDelay);
          _currentSyncDay = null;
          daySpan?.end();
        } catch (e, st) {
          daySpan?.recordError(e, st);
          daySpan?.end(ok: false);
          rethrow;
        }
      }

      if (_dispatcher != null) {
        _ensureMetricRecordListeners();
        // Delta sync for stress + HRV: same skip rule as HR. The
        // watch only emits fixed-slot records for completed past
        // days, and the merge is idempotent on timestamp, so
        // re-polling a day we already have is wasted bytes only —
        // never a missing write. Today is always re-fetched so
        // half-hour slots that have filled in since the previous
        // sync are picked up.
        final stressToFetch = _daysToFetch(
          wantsDays,
          todayD,
          metric: 'stress',
          hasData: (h) => h.stress.isNotEmpty,
          force: force,
        );
        final hrvToFetch = _daysToFetch(
          wantsDays,
          todayD,
          metric: 'hrv',
          hasData: (h) => h.hrv.isNotEmpty,
          force: force,
        );
        // Union of days we need to hit on the wire — we always
        // send both 0x37 and 0x39 in the same per-day pass so a
        // single sync skip applies to both.
        final metricDays = <int>{...stressToFetch, ...hrvToFetch}.toList()
          ..sort();
        for (final d in metricDays) {
          if (stressToFetch.contains(d)) {
            await transport.sendA(Commands.readStressHistory(dayOffset: d));
            await _drainRx(drainDuration);
            await Future<void>.delayed(postCommandDelay);
          }
          if (hrvToFetch.contains(d)) {
            await transport.sendA(Commands.readHrvHistory(dayOffset: d));
            await _drainRx(drainDuration);
            await Future<void>.delayed(postCommandDelay);
          }
        }
      }

      if (_bParser != null) {
        // Activity summary is the cheap v14 sport-motion probe (Channel-B
        // `0x2a`, GHIDRA §2.8). It returns entries only for day offsets
        // 0..2, so older history still relies on HR/sleep until a live
        // capture confirms another totals source.
        final activityOffsets = wantsDays.where((d) => d <= 2).toList()..sort();
        if (activityOffsets.isNotEmpty) {
          final maxOffset = activityOffsets.fold<int>(
            0,
            (max, d) => d > max ? d : max,
          );
          await transport.sendB(
            Commands.readActivitySummary(dayOffset: maxOffset),
          );
          await Future<void>.delayed(drainDuration);

          // Pair the summary with the per-hour detail command. The detail
          // frames are surfaced through ChannelADispatcher.onSportDetail* for
          // diagnostics and future richer charts; DailyHistory stores only
          // day totals today.
          for (final d in activityOffsets) {
            await transport.sendA(Commands.readDetailSport(dayOffset: d));
            await _drainRx(drainDuration);
          }
        }

        // Sleep for the most recent N days — the new protocol emits
        // a single day offset per request, so we fire-and-await for
        // each. Delta sync: a past day we have already ingested sleep
        // for is skipped; today is always re-fetched because the
        // watch's "night" response for the wake-up day also carries
        // sessions that *began* in the previous calendar day (the
        // HS-3 rationale for re-polling past days no longer holds —
        // the watch's own per-day responses are immutable, so a
        // second pull can only return the same segments the merge
        // would have already deduplicated). Sleep buckets are cleared
        // only when a replacement response is actually decoded; a
        // missed or malformed reply must not erase the user's
        // previously-stored night.
        //
        // NOTE: per GHIDRA_DECOMPILATION.md §2.3, the firmware handler
        // `channel_b_send_sleep_records` (0x0082fada) **always** emits
        // both `0x3E` (nap) and `0x27` (night) responses in a single
        // call regardless of `recordType`. The `param_2` only affects
        // which pass reads from storage first. Therefore, sending only
        // `0x27` suffices to get both night and lunch/nap data; a
        // separate `0x3e` send would be redundant and cause duplicate
        // responses (absorbed by ChannelBParser dedup, but wasted).
        final sleepToFetch = _daysToFetch(
          wantsDays,
          todayD,
          metric: 'sleep',
          hasData: (h) => h.sleep.isNotEmpty,
          force: force,
        );
        for (final d in sleepToFetch) {
          final day = todayD.addDays(-d);
          _currentSyncDay = day;
          await transport.sendB(Commands.readSleepNewProtocol(dayOffset: d));
          await _drainRx(drainDuration);
          await Future<void>.delayed(postCommandDelay);
          _currentSyncDay = null;
        }
      } else {
        AppLog.instance.warn(
          'history',
          'Skipping sleep/activity sync: ChannelBParser is null. '
              'Sleep/activity data will not be ingested.',
        );
      }

      // Bump the watermark — only after a clean pass.
      await _store?.markSynced(DateTime.now());

      AppLog.instance.info(
        'history',
        'Sync complete: hr=${_hr.length} sleep=${_sleep.length} '
            'fetched=$fetched days=${_watchDaysWithData.length}',
      );

      // Final drain to catch any late-arriving frames that were queued
      // after the last per-command drain (e.g. multi-page sport detail
      // responses that straddle the settle window).
      await _drainRx(drainDuration);
    } catch (e) {
      lastSyncError = e.toString();
      AppLog.instance.error('history', 'Sync failed: $e');
    } finally {
      _currentSyncDay = null;
      _progressCurrent = 0;
      _progressTotal = 0;
      _syncing = false;
      notifyListeners();
    }
  }

  /// Returns the subset of [wantsDays] (a set of day-offsets, 0 =
  /// today) that we still need to fetch for [metric]. Today is
  /// always included — its response can carry samples that
  /// straddle midnight or that have filled in since the previous
  /// sync. Past days are skipped when either [hasData] reports the
  /// in-memory cache already has at least one sample of that
  /// metric for them, or [DailyHistory.syncedMetrics] already
  /// contains [metric] (meaning we fetched it earlier and the watch
  /// returned an empty record). When [force] is `true`, every
  /// requested day is returned so the caller can do a full re-sync.
  /// Without a store backing the cache, every requested day is also
  /// returned (legacy in-memory behaviour).
  List<int> _daysToFetch(
    Iterable<int> wantsDays,
    DateOnly todayD, {
    required String metric,
    required bool Function(DailyHistory) hasData,
    required bool force,
  }) {
    final out = <int>[];
    for (final d in wantsDays) {
      final day = todayD.addDays(-d);
      final isToday = day == todayD;
      final existing = _days[day];
      if (!force &&
          !isToday &&
          existing != null &&
          (hasData(existing) || existing.syncedMetrics.contains(metric))) {
        AppLog.instance.debug(
          'history',
          'skip ${day.iso} for $metric (already in store)',
        );
        continue;
      }
      out.add(d);
    }
    return out;
  }

  void _clearSleepDays(Iterable<DateOnly> days, {bool persist = true}) {
    var changed = false;
    for (final day in days) {
      final existing = _days[day];
      final previous = existing ?? DailyHistory(day: day);
      final alreadySynced = previous.syncedMetrics.contains('sleep');
      // If the day is already in memory with empty sleep and marked
      // synced, there is nothing to do. Otherwise we need to record
      // the empty response so the next sync skips this day.
      if (existing != null && previous.sleep.isEmpty && alreadySynced) continue;
      final updated = previous.copyWith(
        sleep: const [],
        lastUpdated: DateTime.now(),
        syncedMetrics: {...previous.syncedMetrics, 'sleep'},
      );
      _days[day] = updated;
      changed = true;
      if (persist) {
        unawaited(_store?.writeDay(updated));
      }
    }
    if (!changed) return;
    _sleep
      ..clear()
      ..addAll(_days.values.expand((d) => d.sleep));
    _sleep.sort((a, b) => a.start.compareTo(b.start));
    notifyListeners();
  }

  void _collectRx(Uint8List frame) {
    _rxQueue.add(_RxEntry(frame, _currentSyncDay));
  }

  Future<void> _drainRx(Duration settle) async {
    // Spans the per-call settle window so we can measure queue
    // processing latency independently from the surrounding poll.
    final span = OpenTelemetryService().startChildSpan(
      'sync.history.drain_rx',
      attributes: {'sync.settle_ms': settle.inMilliseconds},
    );
    try {
      await Future<void>.delayed(settle);
      final frames = _rxQueue.toList();
      _rxQueue.clear();
      for (final e in frames) {
        _parse(e.frame, e.day);
      }
      notifyListeners();
      span?.end();
    } catch (e, st) {
      span?.recordError(e, st);
      span?.end(ok: false);
      rethrow;
    }
  }

  void _parse(Uint8List frame, DateOnly? day) {
    if (frame.length != 16) return;
    final op = Codec.rxOpcode(frame);
    final pl = Codec.rxPayload(frame);
    switch (op) {
      case OpA.queryDataDistribution:
        // Unsolicited watch→phone push (PROTOCOL.md §4.6). The host
        // never sends a 0x46 request — sending one aliases to
        // `0xC6 deviceReboot` on the firmware and the device replies
        // with `0xC6 ERR 0xee`. We still decode the bitmask in case
        // some firmware builds push it (the data goes to
        // `availableDays` / `watchDaysWithData` for the UI), but the
        // sync flow no longer gates on it — it always blind-polls the
        // last `daysBack` days.
        if (Codec.rxIsError(frame)) {
          final code = pl.isEmpty ? -1 : pl[0];
          AppLog.instance.warn(
            'history',
            '0x46 data-distribution error push (code=0x'
                '${code.toRadixString(16)}); ignoring',
          );
          return;
        }
        // 4-byte BE bitmask: bit d = day d has data (PROTOCOL.md §4.6).
        if (pl.length < 4) {
          AppLog.instance.warn(
            'history',
            '0x46 data-distribution push too short (${pl.length} B)',
          );
          return;
        }
        final v = Codec.readU32be(pl, 0);
        final today = DateOnly.today();
        for (var d = 0; d < 32; d++) {
          if ((v & (1 << d)) != 0) {
            _availableDays.add(d);
            _watchDaysWithData.add(today.addDays(-d));
          }
        }
      case OpA.readHeartRate:
        // 0x15 multi-pkt reassembly per FUN_0082cf48 (GHIDRA §3.12).
        //   * pl[0] == 0x18 → legacy header.
        //   * pl[0] == 0x00 && pl[1] > 0 → H59MAX firmware header
        //     where pl[1] is total frame count including the header.
        //   * pl[0] == 0xFF → empty-day answer (watch has no HR for
        //     this date). This is a WATCH-SIDE answer, not a decoder
        //     error — the watch only stores HR samples when continuous
        //     measurement is enabled (see `OpA.realTimeHeartRate`).
        //     A user who never started a continuous session will see
        //     `0xFF` for every queried day; that is correct behaviour.
        //     `HistorySync` persists the (empty) record so the day
        //     surfaces in the UI rather than being silently dropped.
        //   * pl[0] ∈ 1..23 → chunk with seq byte, 13 payload bytes
        //     follow (samples at 5-min intervals)
        if (pl.isEmpty) return;
        final tag = pl[0];
        if (tag == 0x18 || (tag == 0x00 && pl.length >= 3 && pl[1] > 0)) {
          _hrChunks.clear();
          _hrExpectedChunks = tag == 0x00 ? pl[1] - 1 : null;
          _hrChunk1Received = false;
          // Capture the day the header arrived for; subsequent chunks
          // for this series will flush under that day even if they
          // arrive after _currentSyncDay has moved on (HS-8).
          _hrChunkDay = day;
        } else if (tag == 0xff) {
          // Capture the target day before clearing the series state: a late
          // 0xFF response may arrive after _currentSyncDay has been cleared,
          // but _hrChunkDay was set when the header arrived (HS-8).
          final commitDay = day ?? _hrChunkDay;
          _hrChunks.clear();
          _hrExpectedChunks = null;
          _hrChunkDay = null;
          _hrChunk1Received = false;
          // Persist the (possibly empty) record so the UI shows the
          // day even when the watch has no HR data for it.
          _commitCurrentDayHr(commitDay);
        } else if (tag >= 1 && tag <= 23) {
          if (pl.length >= 1 + 13) {
            // Store by sequence number so out-of-order chunks and BLE
            // retries assemble correctly. A duplicate seq overwrites the
            // previous copy instead of inflating the buffer.
            _hrChunks[tag] = Uint8List.fromList(pl.sublist(1, 1 + 13));
            if (tag == 1) _hrChunk1Received = true;
            final expected = _hrExpectedChunks;
            if ((expected != null && _hrChunks.length >= expected) ||
                (expected == null && _hrChunks.length >= tag)) {
              _flushHrChunks(_hrChunkDay ?? day);
            }
          }
        }
      case OpA.todaySport:
        final parsed = SportTotals.tryParse(pl);
        if (parsed != null) {
          final totals = DailyTotals(
            steps: parsed.steps,
            calories: parsed.calories,
            distanceMeters: parsed.distanceMeters,
          );
          _upsertTotals(DateOnly.today(), totals);
          onTotals(totals);
        }
      case OpA.readDetailSport:
        _decodeSportDetailTotals(pl);
    }
  }

  final Map<int, Uint8List> _hrChunks = {};
  int? _hrExpectedChunks;
  bool _hrChunk1Received = false;

  void _flushHrChunks(DateOnly? day) {
    // Spans the assembly + merge step for one day's HR series; tagged
    // with the target day so flame graphs show which day is slow.
    final span = OpenTelemetryService().startChildSpan(
      'sync.history.flush_hr',
      attributes: {'sync.day.iso': day?.iso ?? ''},
    );
    try {
      // No header → drop the record. The header handler captures the
      // day at arrival time (HS-8); reaching here with no day means the
      // header was lost, and trusting the echoed u32 as a fallback has
      // caused cross-day pollution in the wild.
      final resolvedDay = day;
      if (resolvedDay == null) {
        _hrChunks.clear();
        _hrExpectedChunks = null;
        _hrChunk1Received = false;
        _hrChunkDay = null;
        return;
      }
      // Per GHIDRA §3.12 + verified on H59MA_1.00.13_251230, only chunk 1
      // carries the 4-byte echoed request timestamp; chunks 2+ are 13
      // pure BPM bytes. Concatenate every chunk, then drop the single
      // 4-byte record header. Each remaining byte is one 5-min slot
      // anchored at the requested day's midnight (PROTOCOL.md §4.3).
      final builder = BytesBuilder();
      final keys = _hrChunks.keys.toList()..sort();
      for (final k in keys) {
        final c = _hrChunks[k]!;
        builder.add(c.sublist(0, c.length < 13 ? c.length : 13));
      }
      final assembled = builder.toBytes();
      _hrChunks.clear();
      _hrExpectedChunks = null;
      final sampleBytes = assembled.length >= 4 && _hrChunk1Received
          ? Uint8List.fromList(assembled.sublist(4))
          : assembled;
      _hrChunk1Received = false;
      if (sampleBytes.length < 2) return;

      final slots = _decodeFixedSlots(
        sampleBytes,
        day: resolvedDay,
        slotDuration: _hrSlotDuration,
        maxSlots: 288,
        keep: (v) => v != 0x00 && v != 0xff && v >= 30 && v <= 240,
      );
      final samples = [for (final s in slots) HrSample(s.timestamp, s.value)];
      final previous = _days[resolvedDay] ?? DailyHistory(day: resolvedDay);
      final mergedByTs = <int, HrSample>{
        for (final h in previous.hr) h.timestamp.millisecondsSinceEpoch: h,
        for (final h in samples) h.timestamp.millisecondsSinceEpoch: h,
      };
      final mergedHr = mergedByTs.values.toList()
        ..sort((a, b) => a.timestamp.compareTo(b.timestamp));
      final updated = previous.copyWith(
        hr: mergedHr,
        lastUpdated: DateTime.now(),
      );
      _days[resolvedDay] = updated;
      _hr
        ..clear()
        ..addAll(_days.values.expand((d) => d.hr));
      _hr.sort((a, b) => a.timestamp.compareTo(b.timestamp));
      span?.setAttribute('sync.hr_samples', mergedHr.length);
      unawaited(_store?.mergeHr(resolvedDay, mergedHr));
    } catch (e, st) {
      span?.recordError(e, st);
      span?.end(ok: false);
      rethrow;
    } finally {
      span?.end();
    }
  }

  /// Decode a fixed-slot byte series (HR / stress / HRV) anchored at
  /// [day].midnight per PROTOCOL.md §4.3/§3.20/§3.21.
  ///
  /// Slot `i` occupies `day.midnight + slotDuration*i`, for up to
  /// [maxSlots] slots. Bytes for which [keep] returns false (sentinels
  /// like `0x00`/`0xff` or implausible values) are skipped, as is any
  /// slot whose anchor is still in the future — the watch cannot have
  /// measured a sample for a time it has not reached yet, so dropping
  /// it is a completeness ceiling, not a reinterpretation of the data.
  ///
  /// The watch never echoes its RTC (the `0x01` setTime ACK is a fixed
  /// capability shape per §3.4), so we do NOT infer a clock offset or
  /// shift timestamps — each sample is stored at exactly the wall-clock
  /// its slot index denotes. Display-side "now" clipping already lives
  /// in the chart widgets and the debug export.
  List<({DateTime timestamp, int value})> _decodeFixedSlots(
    Uint8List bytes, {
    required DateOnly day,
    required Duration slotDuration,
    required int maxSlots,
    required bool Function(int) keep,
  }) {
    final now = _clock();
    final dayStart = day.midnight;
    final out = <({DateTime timestamp, int value})>[];
    for (var i = 0; i < bytes.length && i < maxSlots; i++) {
      final v = bytes[i] & 0xff;
      if (!keep(v)) continue;
      final ts = dayStart.add(slotDuration * i);
      if (ts.isAfter(now)) continue;
      out.add((timestamp: ts, value: v));
    }
    return out;
  }

  /// Persist the currently-attributed day as an empty HR record. Called
  /// when the watch returns `pl[0] == 0xff` (no data for this slot).
  /// Without this, an empty day would never be written to disk and the
  /// next sync would re-fetch it forever.
  void _commitCurrentDayHr(DateOnly? day) {
    if (day == null) return;
    final previous = _days[day] ?? DailyHistory(day: day);
    if (previous.hr.isNotEmpty) return; // already persisted with data
    final updated = previous.copyWith(
      lastUpdated: DateTime.now(),
      syncedMetrics: {...previous.syncedMetrics, 'hr'},
    );
    _days[day] = updated;
    unawaited(_store?.writeDay(updated));
  }

  void _onStressRecord(PressureRecord record) {
    final day = DateOnly.fromDateTime(
      _clock(),
    ).addDays(-record.slotId.clamp(0, 31).toInt());
    final samples = _decodeFixedSlotMetric(record.header, record.body, day);
    if (samples.isEmpty) {
      // The watch returned a stress record for this day but it decoded
      // to zero samples (all slots empty/0xff). Mark stress as synced
      // so we don't re-poll this day forever.
      final previous = _days[day] ?? DailyHistory(day: day);
      final updated = previous.copyWith(
        lastUpdated: DateTime.now(),
        syncedMetrics: {...previous.syncedMetrics, 'stress'},
      );
      _days[day] = updated;
      unawaited(_store?.writeDay(updated));
      return;
    }
    final previous = _days[day] ?? DailyHistory(day: day);
    final merged = _mergeScalar(previous.stress, samples);
    final updated = previous.copyWith(
      stress: merged,
      lastUpdated: DateTime.now(),
    );
    _days[day] = updated;
    unawaited(_store?.mergeStress(day, merged));
    notifyListeners();
  }

  void _onHrvRecord(HrvRecord record) {
    final day = DateOnly.fromDateTime(
      _clock(),
    ).addDays(-record.slotId.clamp(0, 31).toInt());
    final samples = _decodeFixedSlotMetric(record.header, record.body, day);
    if (samples.isEmpty) {
      // The watch returned an HRV record for this day but it decoded
      // to zero samples. Mark HRV as synced so we don't re-poll this
      // day forever.
      final previous = _days[day] ?? DailyHistory(day: day);
      final updated = previous.copyWith(
        lastUpdated: DateTime.now(),
        syncedMetrics: {...previous.syncedMetrics, 'hrv'},
      );
      _days[day] = updated;
      unawaited(_store?.writeDay(updated));
      return;
    }
    final previous = _days[day] ?? DailyHistory(day: day);
    final merged = _mergeScalar(previous.hrv, samples);
    final updated = previous.copyWith(hrv: merged, lastUpdated: DateTime.now());
    _days[day] = updated;
    unawaited(_store?.mergeHrv(day, merged));
    notifyListeners();
  }

  List<HealthMetricSample> _decodeFixedSlotMetric(
    Uint8List header,
    Uint8List body,
    DateOnly day,
  ) {
    // GHIDRA §3.20/§3.21: the reassembled record is 49 bytes — a 1-byte
    // slot-id echo followed by 48 half-hour samples. Drop the echo and
    // anchor each remaining byte at day.midnight + i*30min.
    final raw = Uint8List.fromList([...header, ...body]);
    if (raw.length < 2) return const [];
    final sampleBytes = Uint8List.fromList(raw.skip(1).take(48).toList());
    final slots = _decodeFixedSlots(
      sampleBytes,
      day: day,
      slotDuration: const Duration(minutes: 30),
      maxSlots: 48,
      keep: (v) => v != 0 && v != 0xff,
    );
    return [for (final s in slots) HealthMetricSample(s.timestamp, s.value)];
  }

  List<HealthMetricSample> _mergeScalar(
    List<HealthMetricSample> existing,
    List<HealthMetricSample> incoming,
  ) {
    final byTs = <int, HealthMetricSample>{
      for (final s in existing) s.timestamp.millisecondsSinceEpoch: s,
      for (final s in incoming) s.timestamp.millisecondsSinceEpoch: s,
    };
    return byTs.values.toList()
      ..sort((a, b) => a.timestamp.compareTo(b.timestamp));
  }

  @override
  void dispose() {
    _inbound?.cancel();
    _bCmdSub?.cancel();
    _pressureRecordsSub?.cancel();
    _hrvRecordsSub?.cancel();
    _pressureReassembler?.dispose();
    _hrvReassembler?.dispose();
    super.dispose();
  }

  // ---------------------------------------------------------------------------
  // Channel-B command ingest — handles `0x27` night sleep, `0x3e`
  // lunch/nap responses (PROTOCOL.md §4.4, GHIDRA §2.3), and
  // `0x2a` activity summaries (GHIDRA §2.8). The
  // `ChannelBParser` already validated CRC and emitted a fully
  // reassembled payload; we just decode the records.
  // ---------------------------------------------------------------------------

  void _onChannelBCommand(ChannelBCommand cmd) {
    final added = switch (cmd.cmd) {
      OpB.sleepNew => _decodeSleepNew(cmd.payload),
      OpB.sleepLunchNew => _decodeSleepLunch(cmd.payload),
      OpB.activitySummary => _decodeActivitySummary(cmd.payload),
      _ => 0,
    };
    if (added > 0) {
      AppLog.instance.debug(
        'history',
        'Channel-B cmd=0x${cmd.cmd.toRadixString(16)} +$added update(s) '
            '(sleep=${_sleep.length} activity=${_activity.length})',
      );
      notifyListeners();
    }
  }

  int _decodeActivitySummary(Uint8List payload) {
    var updated = 0;
    var offset = 0;
    final today = DateOnly.today();
    while (offset + 49 <= payload.length) {
      final dayOffset = payload[offset];
      final body = Uint8List.fromList([
        for (var i = offset + 1; i < offset + 49; i++)
          payload[i] == 0xff ? 0x00 : payload[i],
      ]);
      if (dayOffset <= 31) {
        final day = today.addDays(-dayOffset);
        final totals = _activityTotalsFromBody(body);
        final rec = ActivitySummaryRecord(
          day: day,
          dayOffset: dayOffset,
          body: body,
          totals: totals,
        );
        _activity.removeWhere((r) => r.day == day);
        _activity.add(rec);
        _activity.sort((a, b) => a.day.compareTo(b.day));
        _upsertTotals(day, totals);
        if (day == today) onTotals(totals);
        updated++;
      }
      offset += 49;
    }
    return updated;
  }

  DailyTotals _activityTotalsFromBody(Uint8List body) {
    if (body.length < 12) return const DailyTotals();
    // Best-effort field layout: steps (u24 BE @ 0), calories (u24 BE
    // @ 6), distance (u24 BE @ 9). The H59MA v13 firmware emits the
    // activity body with field semantics "owned by the producer"
    // (see `firmwares/GHIDRA_DECOMPILATION.md` §2.8) — i.e. the
    // RE notes only pin the *frame* layout (1 B day-offset + 48 B
    // body), not the per-byte semantics of the body. The offsets
    // above are our best guess from live captures.
    //
    // Defensive clamping: on v13 the u24 BE field at body[6..8] can
    // decode to values like 6,381,923 kcal (impossible). Until we
    // have a RE-pinned offset for that build we clamp any value past
    // [kMaxSaneKcalPerDay] to null so the UI doesn't show absurd numbers
    // and so _upsertTotals knows the field is missing (not zero).
    // The OLD app versions (before commit fd28b07) had no clamp,
    // which produced kcal values like 108543 in the user's export;
    // `DailyHistory.fromJson` now nulls those on read.
    const kMaxSaneSteps = 200000; // ~2 steps/sec for 24h straight
    const kMaxSaneKcal = 20000; // ~10x elite-athlete ceiling
    const kMaxSaneMeters = 200000; // 200 km in a day
    final rawSteps = Codec.readU24be(body, 0);
    final rawKcal = Codec.readU24be(body, 6);
    final rawMeters = Codec.readU24be(body, 9);
    // An all-zero activity body means "the watch has no activity summary
    // for this day yet" (e.g. freshly after midnight). Return null totals
    // so the UI shows "no data" and _upsertTotals does not fall back to
    // a previous day's values (HS-6).
    if (rawSteps == 0 && rawKcal == 0 && rawMeters == 0) {
      return const DailyTotals();
    }
    return DailyTotals(
      steps: rawSteps > kMaxSaneSteps ? null : rawSteps,
      calories: rawKcal > kMaxSaneKcal ? null : rawKcal,
      distanceMeters: rawMeters > kMaxSaneMeters ? null : rawMeters,
    );
  }

  /// Tracks the last seen page/total per day for `0x43` sport-detail
  /// paged responses. Key = [DateOnly] day; value = (page, total).
  /// Totals are only finalized when the last page (`page == total - 1`)
  /// arrives, per PROTOCOL.md §4.4.
  final Map<DateOnly, ({int page, int total})> _sportDetailPageState = {};

  void _decodeSportDetailTotals(Uint8List pl) {
    if (pl.length < 12) return;
    if (pl[0] == 0xf0 || pl[0] == 0xff) return; // header / empty day

    final year = 2000 + Codec.fromBcd(pl[0]);
    final month = Codec.fromBcd(pl[1]);
    final dayOfMonth = Codec.fromBcd(pl[2]);
    if (month < 1 || month > 12 || dayOfMonth < 1 || dayOfMonth > 31) {
      return;
    }

    final page = pl[4];
    final total = pl[5];
    if (total == 0) return; // malformed / zero-total guard

    final day = DateOnly(year, month, dayOfMonth);
    _sportDetailPageState[day] = (page: page, total: total);

    // Live H59MA_V1.0 captures show the detail record body as:
    //   pl[3]    = slot << 2
    //   pl[4]    = record index (page)
    //   pl[5]    = header record count (total)
    //   pl[6..7] = duration seconds, LE
    //   pl[8..9] = per-slot steps, LE
    //   pl[10..11] = per-slot distance meters, LE
    //
    // NOTE: PROTOCOL.md §3.4 says `BLEDataFormatUtils.bytes2Int` is
    // big-endian, and §4.4 says `0x43` cal/steps/dist uses
    // "bytes2Int of swapped pairs". However, live H59MA v13/v14
    // captures show plain LE for steps/dist here, matching the
    // current decode. This is a documented H59MA-specific deviation
    // from the generic Oudmon SDK spec.
    final steps = pl[8] | (pl[9] << 8);
    final distance = pl[10] | (pl[11] << 8);

    // Accumulate each page's contribution as it arrives, but start a
    // fresh sum on page 0 so a restarted/retried paged sequence does
    // not inherit stale totals. Only persist to the store once the
    // final page (page == total - 1) has been seen.
    var previous = _sportDetailTotals[day] ?? const DailyTotals();
    if (page == 0) previous = const DailyTotals();

    final existingDay = _days[day];
    final totals = DailyTotals(
      steps: (previous.steps ?? 0) + steps,
      // Sport-detail frames do not carry calories; preserve the value
      // from the activity summary if one has already been ingested.
      calories: previous.calories ?? existingDay?.energyKcal,
      distanceMeters: (previous.distanceMeters ?? 0) + distance,
    );
    _sportDetailTotals[day] = totals;

    // PROTOCOL.md §4.4: b4=page, b5=total; done when b4==b5-1.
    if (page == total - 1) {
      _upsertTotals(day, totals);
    }
  }

  void _upsertTotals(DateOnly day, DailyTotals totals) {
    final previous = _days[day] ?? DailyHistory(day: day);
    final updated = previous.copyWith(
      steps: totals.steps,
      clearSteps: totals.steps == null,
      energyKcal: totals.calories,
      clearEnergyKcal: totals.calories == null,
      distanceMeters: totals.distanceMeters,
      clearDistanceMeters: totals.distanceMeters == null,
      lastUpdated: DateTime.now(),
    );
    _days[day] = updated;
    unawaited(_store?.writeDay(updated));
  }

  /// Extracts the day offset from the payload of a `0x27` Ch-B sleep reply.
  ///
  /// Only the night-sleep opcode (`0x27`) carries a `dayOffset` prefix
  /// (PROTOCOL.md §4.4: first payload byte = dayOffset, 0 = today,
  /// 1 = yesterday, …). The lunch/nap opcode (`0x3e`) does **not** have this
  /// prefix — its first byte is the high byte of the BE `endMinuteOfDay`.
  /// Some older firmware revisions omit the prefix entirely; in that case
  /// we default to the current sync day (the one we just polled) so the
  /// data still lands in the correct file.
  DateOnly _dayFromSleepPayload(Uint8List payload, {required bool isNight}) {
    final today = DateOnly.today();
    if (isNight && payload.isNotEmpty && payload[0] <= 31) {
      return today.addDays(-payload[0]);
    }
    return _currentSyncDay ?? today;
  }

  int _decodeSleepNew(Uint8List payload) {
    // Spans the night-sleep decode + merge step so we can spot a
    // slow parse or failed mergeSleep in the trace timeline.
    final span = OpenTelemetryService().startChildSpan(
      'sync.history.decode_sleep',
      attributes: {'sync.sleep.kind': 'night'},
    );
    try {
      final isH59maRecordList = SleepParser.isH59maNightRecordPayload(payload);
      final today = DateOnly.today();
      final wakeDay = isH59maRecordList
          ? today
          : _dayFromSleepPayload(payload, isNight: true);
      final anchor = wakeDay.midnight;
      final added = SleepParser.parseNightSleepSegments(
        payload,
        anchor: anchor,
      );
      final replaceDays = <DateOnly>{};
      if (isH59maRecordList) {
        for (final offset in SleepParser.h59maNightRecordDayDeltas(payload)) {
          final day = today.addDays(-offset);
          replaceDays
            ..add(day)
            ..add(day.addDays(-1));
        }
      } else {
        replaceDays
          ..add(wakeDay)
          ..add(wakeDay.addDays(-1));
      }
      if (added.isEmpty) {
        if (payload.isEmpty) {
          _clearSleepDays(replaceDays);
        }
        return 0;
      }
      // The parser re-keys segments to the BEDTIME day when a
      // block wraps midnight (e.g. wakeDay=2026-06-19, segments
      // start at 2026-06-18T20:33). Group by the segment's
      // own start date so each segment lands in the right day's
      // _days bucket — otherwise a 4h50m night would be filed
      // under the wake-up day even though its start timestamp
      // belongs to the previous calendar date.
      final addedByDay = <DateOnly, List<SleepSegment>>{};
      for (final s in added) {
        final d = DateOnly.fromDateTime(s.start);
        addedByDay.putIfAbsent(d, () => []).add(s);
      }
      final daysWithNewSleep = addedByDay.keys.toSet();
      _clearSleepDays(replaceDays.difference(daysWithNewSleep));
      _clearSleepDays(daysWithNewSleep, persist: false);
      for (final entry in addedByDay.entries) {
        final day = entry.key;
        final segments = entry.value;
        final previous = _days[day] ?? DailyHistory(day: day);
        final mergedByStart = <int, SleepSegment>{};
        for (final s in previous.sleep) {
          mergedByStart[s.start.millisecondsSinceEpoch] = s;
        }
        for (final s in segments) {
          final key = s.start.millisecondsSinceEpoch;
          final existing = mergedByStart[key];
          if (existing != null &&
              (existing.duration != s.duration || existing.stage != s.stage)) {
            AppLog.instance.log(
              'HistorySync',
              'sleep merge conflict at ${s.start}: '
                  'existing ${existing.duration.inMinutes}min ${existing.stage.name} '
                  'vs new ${s.duration.inMinutes}min ${s.stage.name} — keeping new',
              level: LogLevel.warn,
            );
          }
          mergedByStart[key] = s;
        }
        final merged = mergedByStart.values.toList()
          ..sort((a, b) => a.start.compareTo(b.start));
        final updated = previous.copyWith(
          sleep: merged,
          lastUpdated: DateTime.now(),
        );
        _days[day] = updated;
        unawaited(_store?.mergeSleep(day, merged));
      }
      _sleep
        ..clear()
        ..addAll(_days.values.expand((d) => d.sleep));
      _sleep.sort((a, b) => a.start.compareTo(b.start));
      return added.length;
    } catch (e, st) {
      span?.recordError(e, st);
      rethrow;
    } finally {
      span?.end();
    }
  }

  int _decodeSleepLunch(Uint8List payload) {
    // Same shape as _decodeSleepNew but for the lunch/nap channel
    // (0x3e) — emitted as a sibling span so trace queries can
    // filter on sync.sleep.kind.
    final span = OpenTelemetryService().startChildSpan(
      'sync.history.decode_sleep',
      attributes: {'sync.sleep.kind': 'lunch'},
    );
    try {
      final wakeDay = _dayFromSleepPayload(payload, isNight: false);
      final anchor = wakeDay.midnight;
      final added = SleepParser.parseLunchSleepSegments(
        payload,
        anchor: anchor,
      );
      if (added.isEmpty) return 0;
      // Re-bucket by segment start date (same logic as night) so
      // a nap that ends after midnight lands under the bedtime
      // day. Lunch/nap is normally < 90 min so this is rare, but
      // the parser supports it.
      final addedByDay = <DateOnly, List<SleepSegment>>{};
      for (final s in added) {
        final d = DateOnly.fromDateTime(s.start);
        addedByDay.putIfAbsent(d, () => []).add(s);
      }
      for (final entry in addedByDay.entries) {
        final day = entry.key;
        final segments = entry.value;
        final previous = _days[day] ?? DailyHistory(day: day);
        final mergedByStart = <int, SleepSegment>{};
        for (final s in previous.sleep) {
          mergedByStart[s.start.millisecondsSinceEpoch] = s;
        }
        for (final s in segments) {
          final key = s.start.millisecondsSinceEpoch;
          final existing = mergedByStart[key];
          if (existing != null &&
              (existing.duration != s.duration || existing.stage != s.stage)) {
            AppLog.instance.log(
              'HistorySync',
              'sleep merge conflict at ${s.start}: '
                  'existing ${existing.duration.inMinutes}min ${existing.stage.name} '
                  'vs new ${s.duration.inMinutes}min ${s.stage.name} — keeping new',
              level: LogLevel.warn,
            );
          }
          mergedByStart[key] = s;
        }
        final merged = mergedByStart.values.toList()
          ..sort((a, b) => a.start.compareTo(b.start));
        final updated = previous.copyWith(
          sleep: merged,
          lastUpdated: DateTime.now(),
        );
        _days[day] = updated;
        unawaited(_store?.mergeSleep(day, merged));
      }
      _sleep
        ..clear()
        ..addAll(_days.values.expand((d) => d.sleep));
      _sleep.sort((a, b) => a.start.compareTo(b.start));
      return added.length;
    } catch (e, st) {
      span?.recordError(e, st);
      rethrow;
    } finally {
      span?.end();
    }
  }
}
