import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:openwatch/core/ble/ble_transport.dart';
import 'package:openwatch/core/protocol/channel_a.dart';
import 'package:openwatch/core/protocol/channel_b.dart';
import 'package:openwatch/core/protocol/codec.dart';
import 'package:openwatch/core/protocol/opcodes.dart';
import 'package:openwatch/core/services/history_store.dart';
import 'package:openwatch/core/services/history_sync.dart';

class _StubTransport implements BleTransport {
  final inA = StreamController<Uint8List>.broadcast();
  final inB = StreamController<Uint8List>.broadcast();
  final sent = <Uint8List>[];
  final sentB = <Uint8List>[];

  @override
  Stream<Uint8List> get inboundA => inA.stream;

  @override
  Stream<Uint8List> get inboundB => inB.stream;

  @override
  Future<void> sendA(Uint8List frame) async {
    sent.add(frame);
  }

  @override
  Future<void> sendB(Uint8List framed) async {
    sentB.add(framed);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

Uint8List _channelAErrorFrame(int op, List<int> payload) {
  final f = Codec.buildChannelA(op, payload);
  f[0] = f[0] | 0x80;
  var sum = 0;
  for (var i = 0; i < 15; i++) {
    sum = (sum + f[i]) & 0xFF;
  }
  f[15] = sum;
  return f;
}

HistorySync _testSync(
  _StubTransport t,
  ChannelADispatcher d, {
  ChannelBParser? bParser,
  DateTime Function()? clock,
}) {
  // Bind the Channel-B parser to the stub transport so test-injected
  // Channel-B frames are actually reassembled and dispatched.
  bParser?.bind();
  return HistorySync(
    t,
    (_) {},
    dispatcher: d,
    bParser: bParser,
    drainDuration: const Duration(milliseconds: 50),
    postCommandDelay: Duration.zero,
    fragmentQuietWindow: const Duration(milliseconds: 50),
    clock: clock,
  );
}

void main() {
  group('HistorySync', () {
    test('syncAll never sends 0x46 (it is a watch→phone notify-only opcode '
        'per PROTOCOL.md §4.6 — no host→watch request exists)', () async {
      final t = _StubTransport();
      final d = ChannelADispatcher(t);
      d.bind();
      final sync = _testSync(t, d);
      final future = sync.syncAll(daysBack: 1);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      // No 0x46 frame should ever appear on the wire — the previous
      // implementation sent a bare 0x46 and the firmware replied with
      // `0xC6 ERR 0xee`, forcing the `_distributionFailed` fallback.
      expect(
        t.sent.where((f) => f.isNotEmpty && f[0] == OpA.queryDataDistribution),
        isEmpty,
        reason: '0x46 is watch→phone notify-only; phone must never send it',
      );
      await future;
      sync.dispose();
      d.dispose();
    });

    test(
      'syncAll blindly polls the last N days without needing 0x46',
      () async {
        final t = _StubTransport();
        final d = ChannelADispatcher(t);
        d.bind();
        final bp = ChannelBParser(t);
        final now = DateTime(2026, 6, 23, 23, 59);
        final sync = _testSync(t, d, bParser: bp, clock: () => now);
        final future = sync.syncAll(daysBack: 2);
        await Future<void>.delayed(const Duration(milliseconds: 20));
        await future;

        // Per-day HR reads fire for both day 0 (today) and day 1.
        expect(
          t.sent.where((f) => f.isNotEmpty && f[0] == OpA.readHeartRate),
          hasLength(2),
        );
        // Activity summary fires on Channel-B (clamped to dayOffset ≤ 2).
        expect(t.sentB.map(Codec.rxChannelBCmd), contains(OpB.activitySummary));
        final today = DateOnly.fromDateTime(now);
        expect(sync.fetchedDays, containsAll([today, today.addDays(-1)]));
        sync.dispose();
        d.dispose();
      },
    );

    test('syncAll ignores concurrent calls while already syncing', () async {
      final t = _StubTransport();
      final d = ChannelADispatcher(t);
      d.bind();
      // Use a long drain so the first syncAll stays in-flight long enough
      // for us to fire a second one while _syncing is true.
      final sync = HistorySync(
        t,
        (_) {},
        dispatcher: d,
        drainDuration: const Duration(milliseconds: 500),
        postCommandDelay: Duration.zero,
        fragmentQuietWindow: const Duration(milliseconds: 50),
      );

      final first = sync.syncAll(daysBack: 1);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      final sentBefore = t.sent.length;

      // Second call must return immediately and not send any frames.
      await sync.syncAll(daysBack: 1);

      expect(t.sent.length, sentBefore);
      await first;
      sync.dispose();
      d.dispose();
    });

    test('syncAll re-fetches persisted past days with empty HR', () async {
      final t = _StubTransport();
      final d = ChannelADispatcher(t);
      d.bind();
      final sync = _testSync(t, d);
      final today = DateOnly.today();
      final yesterday = today.addDays(-1);
      await sync.bindStore(
        _FakeHistoryStore(
          seed: {
            yesterday: DailyHistory(
              day: yesterday,
              hr: const [],
              sleep: [
                SleepSegment(
                  yesterday.midnight.add(const Duration(hours: 22)),
                  const Duration(minutes: 30),
                  SleepStage.deep,
                ),
              ],
              steps: 7087,
              energyKcal: 0,
              distanceMeters: 4522,
            ),
          },
        ),
      );

      await sync.syncAll(daysBack: 2);

      final hrReads = t.sent
          .where((f) => f.isNotEmpty && f[0] == OpA.readHeartRate)
          .toList();
      expect(
        hrReads,
        hasLength(2),
        reason: 'empty HR persisted by older parser versions must be re-polled',
      );
      expect(sync.fetchedDays, containsAll([today, yesterday]));
      sync.dispose();
      d.dispose();
    });

    test('syncAll skips persisted past days that already have HR', () async {
      final t = _StubTransport();
      final d = ChannelADispatcher(t);
      d.bind();
      final sync = _testSync(t, d);
      final today = DateOnly.today();
      final yesterday = today.addDays(-1);
      await sync.bindStore(
        _FakeHistoryStore(
          seed: {
            yesterday: DailyHistory(
              day: yesterday,
              hr: [
                HrSample(yesterday.midnight.add(const Duration(hours: 8)), 62),
              ],
            ),
          },
        ),
      );

      await sync.syncAll(daysBack: 2);

      final hrReads = t.sent
          .where((f) => f.isNotEmpty && f[0] == OpA.readHeartRate)
          .toList();
      expect(hrReads, hasLength(1));
      expect(sync.fetchedDays, contains(today));
      expect(sync.fetchedDays, isNot(contains(yesterday)));
      sync.dispose();
      d.dispose();
    });

    test(
      'syncAll skips persisted past days that already have stress',
      () async {
        final t = _StubTransport();
        final d = ChannelADispatcher(t);
        d.bind();
        final sync = _testSync(t, d);
        final today = DateOnly.today();
        final yesterday = today.addDays(-1);
        await sync.bindStore(
          _FakeHistoryStore(
            seed: {
              yesterday: DailyHistory(
                day: yesterday,
                // A past day already has stress samples — the stress
                // poll for that dayOffset must NOT go on the wire.
                // Today is always re-fetched.
                stress: [HealthMetricSample(DateTime(2026, 6, 23, 10, 30), 42)],
              ),
            },
          ),
        );

        await sync.syncAll(daysBack: 2);

        // 0x37 (pressure) frames for dayOffset=1 must be absent.
        // 0x37 for dayOffset=0 (today) is still present.
        final stressReads = t.sent
            .where((f) => f.isNotEmpty && f[0] == OpA.pressure)
            .toList();
        expect(
          stressReads,
          hasLength(1),
          reason: 'only today should be re-polled for stress',
        );
        expect(stressReads.first[1], 0x00); // dayOffset=0
        sync.dispose();
        d.dispose();
      },
    );

    test('syncAll skips persisted past days that already have HRV', () async {
      final t = _StubTransport();
      final d = ChannelADispatcher(t);
      d.bind();
      final sync = _testSync(t, d);
      final today = DateOnly.today();
      final yesterday = today.addDays(-1);
      await sync.bindStore(
        _FakeHistoryStore(
          seed: {
            yesterday: DailyHistory(
              day: yesterday,
              hrv: [HealthMetricSample(DateTime(2026, 6, 23, 10, 30), 55)],
            ),
          },
        ),
      );

      await sync.syncAll(daysBack: 2);

      // 0x39 (hrv) frames for dayOffset=1 must be absent.
      final hrvReads = t.sent
          .where((f) => f.isNotEmpty && f[0] == OpA.hrv)
          .toList();
      expect(
        hrvReads,
        hasLength(1),
        reason: 'only today should be re-polled for HRV',
      );
      expect(hrvReads.first[1], 0x00); // dayOffset=0
      sync.dispose();
      d.dispose();
    });

    test('syncAll skips persisted past days that already have sleep', () async {
      final t = _StubTransport();
      final d = ChannelADispatcher(t);
      final bParser = ChannelBParser(t);
      d.bind();
      final sync = _testSync(t, d, bParser: bParser);
      final today = DateOnly.today();
      final yesterday = today.addDays(-1);
      await sync.bindStore(
        _FakeHistoryStore(
          seed: {
            yesterday: DailyHistory(
              day: yesterday,
              // Past day already has a sleep segment — the
              // 0x27 poll for that dayOffset must NOT go on the wire.
              // Today is always re-fetched.
              sleep: [
                SleepSegment(
                  DateTime(2026, 6, 23, 23, 30),
                  const Duration(minutes: 30),
                  SleepStage.deep,
                ),
              ],
            ),
          },
        ),
      );

      await sync.syncAll(daysBack: 2);

      // With yesterday skipped, the only 0x27 frame should be for
      // dayOffset=0 (today).
      final nightReads = t.sentB
          .where((f) => f.isNotEmpty && Codec.rxChannelBCmd(f) == OpB.sleepNew)
          .toList();
      expect(
        nightReads,
        hasLength(1),
        reason: 'only today should be re-polled for night sleep',
      );
      // 0x3e must never be sent (redundant per GHIDRA §2.3).
      final lunchReads = t.sentB
          .where(
            (f) => f.isNotEmpty && Codec.rxChannelBCmd(f) == OpB.sleepLunchNew,
          )
          .toList();
      expect(
        lunchReads,
        isEmpty,
        reason: '0x3e sleepLunchNew must not be sent (redundant)',
      );
      sync.dispose();
      d.dispose();
    });

    test('loadFromStore drops days removed from disk', () async {
      final t = _StubTransport();
      final d = ChannelADispatcher(t);
      d.bind();
      final store = _FakeHistoryStore(
        seed: {DateOnly(2026, 6, 20): DailyHistory(day: DateOnly(2026, 6, 20))},
      );
      final sync = _testSync(t, d);
      await sync.bindStore(store);
      expect(sync.dayOf(DateOnly(2026, 6, 20)), isNotNull);

      await store.clearAll();
      await sync.loadFromStore();

      expect(sync.dayOf(DateOnly(2026, 6, 20)), isNull);
      sync.dispose();
      d.dispose();
    });

    test(
      'days getter returns persisted days sorted oldest to newest',
      () async {
        final t = _StubTransport();
        final d = ChannelADispatcher(t);
        d.bind();
        final sync = _testSync(t, d, clock: () => DateTime(2026, 6, 23));
        await sync.bindStore(
          _FakeHistoryStore(
            seed: {
              DateOnly(2026, 6, 20): DailyHistory(day: DateOnly(2026, 6, 20)),
              DateOnly(2026, 6, 18): DailyHistory(day: DateOnly(2026, 6, 18)),
              DateOnly(2026, 6, 19): DailyHistory(day: DateOnly(2026, 6, 19)),
            },
          ),
        );

        expect(sync.days.map((d) => d.day), [
          DateOnly(2026, 6, 18),
          DateOnly(2026, 6, 19),
          DateOnly(2026, 6, 20),
        ]);

        sync.dispose();
        d.dispose();
      },
    );

    test(
      'hrvRecords and pressureRecords getters cache their streams',
      () async {
        final t = _StubTransport();
        final d = ChannelADispatcher(t);
        d.bind();
        final sync = _testSync(t, d);

        expect(identical(sync.hrvRecords, sync.hrvRecords), isTrue);
        expect(identical(sync.pressureRecords, sync.pressureRecords), isTrue);

        sync.dispose();
        d.dispose();
      },
    );

    test('lastSyncedAt is set after successful sync', () async {
      final t = _StubTransport();
      final d = ChannelADispatcher(t);
      d.bind();
      final store = _FakeHistoryStore();
      final sync = _testSync(t, d);
      await sync.bindStore(store);

      expect(sync.lastSyncedAt, isNull);
      await sync.syncAll(daysBack: 1);
      expect(sync.lastSyncedAt, isNotNull);

      sync.dispose();
      d.dispose();
    });

    test(
      'syncAll still re-fetches past days when the stored slice is empty',
      () async {
        // Regression: the skip rule must trigger on "data present",
        // not "file present". A day that exists in the store with
        // zero stress / sleep samples is a partial sync and must be
        // re-polled to fill the gap.
        final t = _StubTransport();
        final d = ChannelADispatcher(t);
        d.bind();
        final bParser = ChannelBParser(t);
        final sync = _testSync(t, d, bParser: bParser);
        final today = DateOnly.today();
        final yesterday = today.addDays(-1);
        await sync.bindStore(
          _FakeHistoryStore(
            seed: {
              yesterday: DailyHistory(
                day: yesterday,
                hr: [
                  HrSample(
                    yesterday.midnight.add(const Duration(hours: 8)),
                    62,
                  ),
                ],
                // stress + sleep intentionally empty.
              ),
            },
          ),
        );

        await sync.syncAll(daysBack: 2);

        // HR for yesterday IS skipped (has data).
        // Stress + HRV for yesterday are NOT skipped (empty).
        final stressReads = t.sent
            .where((f) => f.isNotEmpty && f[0] == OpA.pressure)
            .toList();
        final hrvReads = t.sent
            .where((f) => f.isNotEmpty && f[0] == OpA.hrv)
            .toList();
        final nightReads = t.sentB
            .where(
              (f) => f.isNotEmpty && Codec.rxChannelBCmd(f) == OpB.sleepNew,
            )
            .toList();
        // Two days requested × 1 command each, so we expect
        // 2 stress / 2 hrv / 2 night sleep reads on the wire.
        expect(stressReads, hasLength(2));
        expect(hrvReads, hasLength(2));
        expect(nightReads, hasLength(2));
        sync.dispose();
        d.dispose();
      },
    );

    test(
      'syncAll skips persisted past days that were confirmed empty for stress',
      () async {
        final t = _StubTransport();
        final d = ChannelADispatcher(t);
        d.bind();
        final sync = _testSync(t, d);
        final today = DateOnly.today();
        final yesterday = today.addDays(-1);
        await sync.bindStore(
          _FakeHistoryStore(
            seed: {
              yesterday: DailyHistory(
                day: yesterday,
                // Empty stress, but the metric was synced earlier (watch
                // returned an empty 0x37 record). It must be skipped now.
                syncedMetrics: const {'stress'},
              ),
            },
          ),
        );

        await sync.syncAll(daysBack: 2);

        final stressReads = t.sent
            .where((f) => f.isNotEmpty && f[0] == OpA.pressure)
            .toList();
        expect(
          stressReads,
          hasLength(1),
          reason: 'confirmed-empty stress day should be skipped',
        );
        expect(stressReads.first[1], 0x00); // today only
        sync.dispose();
        d.dispose();
      },
    );

    test(
      'syncAll skips persisted past days that were confirmed empty for HRV',
      () async {
        final t = _StubTransport();
        final d = ChannelADispatcher(t);
        d.bind();
        final sync = _testSync(t, d);
        final today = DateOnly.today();
        final yesterday = today.addDays(-1);
        await sync.bindStore(
          _FakeHistoryStore(
            seed: {
              yesterday: DailyHistory(
                day: yesterday,
                syncedMetrics: const {'hrv'},
              ),
            },
          ),
        );

        await sync.syncAll(daysBack: 2);

        final hrvReads = t.sent
            .where((f) => f.isNotEmpty && f[0] == OpA.hrv)
            .toList();
        expect(
          hrvReads,
          hasLength(1),
          reason: 'confirmed-empty HRV day should be skipped',
        );
        expect(hrvReads.first[1], 0x00); // today only
        sync.dispose();
        d.dispose();
      },
    );

    test(
      'syncAll skips persisted past days that were confirmed empty for sleep',
      () async {
        final t = _StubTransport();
        final d = ChannelADispatcher(t);
        final bParser = ChannelBParser(t);
        d.bind();
        final sync = _testSync(t, d, bParser: bParser);
        final today = DateOnly.today();
        final yesterday = today.addDays(-1);
        await sync.bindStore(
          _FakeHistoryStore(
            seed: {
              yesterday: DailyHistory(
                day: yesterday,
                syncedMetrics: const {'sleep'},
              ),
            },
          ),
        );

        await sync.syncAll(daysBack: 2);

        final nightReads = t.sentB
            .where(
              (f) => f.isNotEmpty && Codec.rxChannelBCmd(f) == OpB.sleepNew,
            )
            .toList();
        // 0x3e must never be sent (redundant per GHIDRA §2.3).
        final lunchReads = t.sentB
            .where(
              (f) =>
                  f.isNotEmpty && Codec.rxChannelBCmd(f) == OpB.sleepLunchNew,
            )
            .toList();
        expect(
          nightReads,
          hasLength(1),
          reason: 'confirmed-empty sleep day should be skipped',
        );
        expect(
          lunchReads,
          isEmpty,
          reason: '0x3e sleepLunchNew must not be sent (redundant)',
        );
        sync.dispose();
        d.dispose();
      },
    );

    test(
      'syncAll force=true re-fetches persisted past days for every metric',
      () async {
        final t = _StubTransport();
        final d = ChannelADispatcher(t);
        final bParser = ChannelBParser(t);
        d.bind();
        final sync = _testSync(t, d, bParser: bParser);
        final today = DateOnly.today();
        final yesterday = today.addDays(-1);
        await sync.bindStore(
          _FakeHistoryStore(
            seed: {
              yesterday: DailyHistory(
                day: yesterday,
                hr: [
                  HrSample(
                    yesterday.midnight.add(const Duration(hours: 8)),
                    62,
                  ),
                ],
                stress: [HealthMetricSample(DateTime(2026, 6, 23, 10, 30), 42)],
                hrv: [HealthMetricSample(DateTime(2026, 6, 23, 10, 30), 55)],
                sleep: [
                  SleepSegment(
                    DateTime(2026, 6, 23, 23, 30),
                    const Duration(minutes: 30),
                    SleepStage.deep,
                  ),
                ],
              ),
            },
          ),
        );

        await sync.syncAll(daysBack: 2, force: true);

        // Force must bypass every per-metric skip rule.
        final hrReads = t.sent
            .where((f) => f.isNotEmpty && f[0] == OpA.readHeartRate)
            .toList();
        final stressReads = t.sent
            .where((f) => f.isNotEmpty && f[0] == OpA.pressure)
            .toList();
        final hrvReads = t.sent
            .where((f) => f.isNotEmpty && f[0] == OpA.hrv)
            .toList();
        final nightReads = t.sentB
            .where(
              (f) => f.isNotEmpty && Codec.rxChannelBCmd(f) == OpB.sleepNew,
            )
            .toList();
        // 0x3e must never be sent (redundant per GHIDRA §2.3).
        final lunchReads = t.sentB
            .where(
              (f) =>
                  f.isNotEmpty && Codec.rxChannelBCmd(f) == OpB.sleepLunchNew,
            )
            .toList();
        expect(hrReads, hasLength(2));
        expect(stressReads, hasLength(2));
        expect(hrvReads, hasLength(2));
        expect(nightReads, hasLength(2));
        expect(lunchReads, isEmpty);
        sync.dispose();
        d.dispose();
      },
    );

    test(
      'unsolicited 0x46 push from the watch does NOT throw or break sync',
      () async {
        final t = _StubTransport();
        final d = ChannelADispatcher(t);
        d.bind();
        final now = DateTime(2026, 6, 23, 23, 59);
        final sync = _testSync(t, d, clock: () => now);
        final future = sync.syncAll(daysBack: 1);
        await Future<void>.delayed(const Duration(milliseconds: 20));
        // Some firmware builds push 0x46 unsolicited — the decoder
        // must NOT throw and the sync must complete cleanly.
        t.inA.add(
          Codec.buildChannelA(OpA.queryDataDistribution, [
            0x00,
            0x00,
            0x00,
            0x01,
          ]),
        );
        await future; // must complete without throwing
        expect(sync.lastSyncError, isNull);
        sync.dispose();
        d.dispose();
      },
    );

    test('readHeartRate 0x15 multi-pkt reassembly yields HrSamples', () async {
      final t = _StubTransport();
      final d = ChannelADispatcher(t);
      d.bind();
      final sync = _testSync(t, d);
      final syncFuture = sync.syncAll();
      // syncAll no longer sends 0x46 — it blind-polls day 0 directly.
      // Wait long enough for the per-day 0x15 poll + drain
      // (0x15 send at T+0 + 50ms drain at T+50).
      await Future<void>.delayed(const Duration(milliseconds: 150));
      // Header
      t.inA.add(Codec.buildChannelA(OpA.readHeartRate, [0x18, 0x80, 0x05]));
      // First 4 bytes of the reassembled record = the day
      // timestamp LE u32 (per the pre-v14 smali convention — see
      // GHIDRA §3.12 for the v14 packed-BCD echo). We use the
      // smali layout here because the regression targets the
      // chunk-reassembly path, not the v14 packed-date echo.
      // Day-start timestamp = 2026-06-19 00:00 UTC = 0x6A34F600
      final dayStartBytes = [0x00, 0xF6, 0x34, 0x6A];
      // Chunk 1: pl[0]=seq=1, pl[1..4]=dayStart, pl[5..13]=samples
      final chunk1 = Uint8List.fromList([
        0x01, // seq=1 (flushed on receipt because count >= seq)
        ...dayStartBytes,
        0x60, // bpm 96
        0x65, // bpm 101
        0xFF, // no sample → skip
        0x6A, // bpm 106
        0x6E, // bpm 110
        0x00, // bpm 0 → skip
        0x6F, // bpm 111
        0x72, // bpm 114
        0x73, // bpm 115
      ]);
      t.inA.add(Codec.buildChannelA(OpA.readHeartRate, chunk1));
      // Let the drain run.
      await Future<void>.delayed(const Duration(milliseconds: 150));
      // The first chunk should have flushed because
      // count (1) >= seq (1).
      final bpms = sync.hr.map((s) => s.bpm).toList();
      expect(bpms, containsAll([96, 101, 106, 110, 111, 114, 115]));
      for (final s in sync.hr) {
        expect(s.bpm, inInclusiveRange(30, 240));
      }
      // Let the sync finish.
      await syncFuture;
      sync.dispose();
      d.dispose();
    });

    test(
      'readHeartRate 0x15 only strips the single 4-byte record header',
      () async {
        final now = DateTime(2026, 6, 24, 12);
        final t = _StubTransport();
        final d = ChannelADispatcher(t);
        d.bind();
        final sync = _testSync(t, d, clock: () => now);
        final syncFuture = sync.syncAll(daysBack: 1);
        // Wait only long enough for the first HR drain to start (not for
        // syncAll to advance past the HR phase) — once stress/activity
        // loops begin, `_currentSyncDay` flips back to null and the HR
        // chunk series loses its day attribution. The HS-8 fix only
        // captures `_hrChunkDay` at header arrival.
        await Future<void>.delayed(const Duration(milliseconds: 20));

        // H59MAX style header: chunkCount=2 data chunks (pl[1] includes header).
        t.inA.add(Codec.buildChannelA(OpA.readHeartRate, [0x00, 0x03, 0x05]));

        final dayStartBytes = [0x00, 0xF6, 0x34, 0x6A];
        final chunk1 = Uint8List.fromList([
          0x01,
          ...dayStartBytes,
          61,
          62,
          63,
          64,
          65,
          66,
          67,
          68,
          69,
        ]);
        // On H59MA v13 firmware only chunk 1 carries the 4-byte timestamp
        // echo; chunks 2+ are 13 pure BPM bytes.
        final chunk2 = Uint8List.fromList([
          0x02,
          70,
          71,
          72,
          73,
          74,
          75,
          76,
          77,
          78,
          79,
          80,
          81,
          82,
        ]);
        t.inA.add(Codec.buildChannelA(OpA.readHeartRate, chunk1));
        // Wait long enough that chunk2 lands in a drain cycle AFTER the
        // header + chunk1 have already been processed — otherwise the
        // chunk-handler races with the drain ordering and `sync.hr` ends
        // up empty. 200ms comfortably covers the HR drain (50ms) and the
        // first stress drain (50ms) so the merge flush fires once both
        // chunks are in the assembly buffer.
        await Future<void>.delayed(const Duration(milliseconds: 100));

        // This second packet must be merged with the pending series,
        // not interpreted as independent BPM bytes at the next 4 slots.
        t.inA.add(Codec.buildChannelA(OpA.readHeartRate, chunk2));
        await Future<void>.delayed(const Duration(milliseconds: 200));

        final today = DateOnly.fromDateTime(now);
        final dayHistory = sync.dayOf(today);
        expect(dayHistory, isNotNull);
        final bySlot = <int, HrSample>{
          for (final h in dayHistory!.hr)
            (h.timestamp.difference(today.midnight).inMinutes ~/ 5): h,
        };

        expect(bySlot.length, 22);
        expect(bySlot[0]?.bpm, 61);
        expect(bySlot[1]?.bpm, 62);
        expect(bySlot[8]?.bpm, 69);
        expect(bySlot[9]?.bpm, 70);
        expect(bySlot[10]?.bpm, 71);
        expect(bySlot[21]?.bpm, 82);
        expect(
          bySlot[9]?.timestamp,
          equals(today.midnight.add(const Duration(minutes: 45))),
        );

        // With the v13 wire shape, chunk 2's first byte is sample 70, so
        // it lands at slot 9; a per-chunk-header interpretation would have
        // placed it at slot 13.
        expect(bySlot[13]?.bpm, isNot(70));

        await syncFuture;
        sync.dispose();
        d.dispose();
      },
    );

    test('readHeartRate 0x15 assembles out-of-order chunks and suppresses '
        'duplicates', () async {
      final now = DateTime(2026, 6, 24, 12);
      final t = _StubTransport();
      final d = ChannelADispatcher(t);
      d.bind();
      final sync = _testSync(t, d, clock: () => now);
      final syncFuture = sync.syncAll(daysBack: 1);
      await Future<void>.delayed(const Duration(milliseconds: 20));

      // H59MAX style header: 2 data chunks expected.
      t.inA.add(Codec.buildChannelA(OpA.readHeartRate, [0x00, 0x03, 0x05]));

      final dayStartBytes = [0x00, 0xF6, 0x34, 0x6A];
      final chunk1 = Uint8List.fromList([
        0x01,
        ...dayStartBytes,
        61,
        62,
        63,
        64,
        65,
        66,
        67,
        68,
        69,
      ]);
      final chunk2 = Uint8List.fromList([
        0x02,
        70,
        71,
        72,
        73,
        74,
        75,
        76,
        77,
        78,
        79,
        80,
        81,
        82,
      ]);

      // Inject chunk 2 first, then a duplicate chunk 2, then chunk 1.
      t.inA.add(Codec.buildChannelA(OpA.readHeartRate, chunk2));
      t.inA.add(Codec.buildChannelA(OpA.readHeartRate, chunk2));
      await Future<void>.delayed(const Duration(milliseconds: 150));
      t.inA.add(Codec.buildChannelA(OpA.readHeartRate, chunk1));
      await Future<void>.delayed(const Duration(milliseconds: 200));

      final today = DateOnly.fromDateTime(now);
      final dayHistory = sync.dayOf(today);
      expect(dayHistory, isNotNull);
      final bySlot = <int, HrSample>{
        for (final h in dayHistory!.hr)
          (h.timestamp.difference(today.midnight).inMinutes ~/ 5): h,
      };

      // 22 unique slots; duplicates must not inflate the count.
      expect(bySlot.length, 22);
      expect(bySlot[0]?.bpm, 61);
      expect(bySlot[9]?.bpm, 70);
      expect(bySlot[21]?.bpm, 82);

      await syncFuture;
      sync.dispose();
      d.dispose();
    });

    test(
      'readHeartRate 0x15 seq-0 firmware header waits for all chunks',
      () async {
        final t = _StubTransport();
        final d = ChannelADispatcher(t);
        d.bind();
        final sync = _testSync(t, d);
        final syncFuture = sync.syncAll();
        await Future<void>.delayed(const Duration(milliseconds: 150));

        t.inA.add(Codec.buildChannelA(OpA.readHeartRate, [0x00, 0x03, 0x05]));
        final dayStartBytes = [0x00, 0xF6, 0x34, 0x6A];
        final chunk1 = Uint8List.fromList([
          0x01,
          ...dayStartBytes,
          0x60,
          0x65,
          0xff,
          0x6a,
          0x6e,
          0,
          0,
          0,
          0,
        ]);
        t.inA.add(Codec.buildChannelA(OpA.readHeartRate, chunk1));
        await Future<void>.delayed(const Duration(milliseconds: 120));
        expect(sync.hr, isEmpty, reason: 'seq-0 header declares 2 chunks');

        final chunk2 = Uint8List.fromList([
          0x02,
          // Chunks 2+ are 13 pure BPM bytes on v13 firmware.
          0x6f,
          0x72,
          0x73,
          0,
          0,
          0,
          0,
          0,
          0,
          0,
          0,
          0,
          0,
        ]);
        t.inA.add(Codec.buildChannelA(OpA.readHeartRate, chunk2));
        await Future<void>.delayed(const Duration(milliseconds: 150));
        final bpms = sync.hr.map((s) => s.bpm).toList();
        expect(bpms, containsAll([96, 101, 106, 110, 111, 114, 115]));

        await syncFuture;
        sync.dispose();
        d.dispose();
      },
    );

    test(
      'readHeartRate 0x15 soft-clips today record with future slots (HS-9)',
      () async {
        // The 0x01 setTime ACK is a fixed capability shape (§3.4), so the
        // watch never echoes its RTC. The sync soft-clips samples whose
        // inferred wall-clock is still in the future — no throw, no
        // lastSyncError — and lets the next pass re-pull them once the
        // watch's RTC catches up. See history_sync._flushHrChunks.
        final now = DateTime(2026, 6, 23, 9);
        final t = _StubTransport();
        final d = ChannelADispatcher(t);
        d.bind();
        final sync = _testSync(t, d, clock: () => now);
        final syncFuture = sync.syncAll(daysBack: 1);
        await Future<void>.delayed(const Duration(milliseconds: 20));

        // Header variant where pl[1] declares total chunks + 1. 24 means
        // 23 data chunks, enough to carry the full 288-slot HR record.
        t.inA.add(Codec.buildChannelA(OpA.readHeartRate, [0x00, 0x18, 0x05]));

        final record = Uint8List(23 * 13);
        record.fillRange(0, record.length, 0xff);
        for (var i = 0; i < 4; i++) {
          record[i] = 0;
        }
        record[4 + (8 * 12)] = 80; // 08:00 watch-time, before now → kept.
        record[4 + (23 * 12 + 11)] =
            120; // 23:55 watch-time, far future → dropped.

        for (var chunk = 0; chunk < 23; chunk++) {
          final start = chunk * 13;
          t.inA.add(
            Codec.buildChannelA(OpA.readHeartRate, [
              chunk + 1,
              ...record.sublist(start, start + 13),
            ]),
          );
        }

        await Future<void>.delayed(const Duration(milliseconds: 150));

        await syncFuture;

        // Past samples survive, future ones are silently dropped.
        expect(sync.hr.map((s) => s.bpm), contains(80));
        expect(sync.hr.map((s) => s.bpm), isNot(contains(120)));
        expect(sync.hr.any((s) => s.timestamp.isAfter(now)), isFalse);
        // Critical: sync must not surface a hard "Watch clock mismatch"
        // error any more — the user is repeatedly hitting this in the
        // wild because the watch RTC drifts ~7 min ahead of phone.
        expect(sync.lastSyncError, isNull);

        sync.dispose();
        d.dispose();
      },
    );

    test(
      'readHeartRate 0x15 keeps a completed trailing slot and drops the next one',
      () async {
        // Protocol-faithful decode: each byte is a 5-min slot anchored at
        // the requested day's midnight. A slot whose anchor is already in
        // the past is kept; one still in the future is dropped (the watch
        // cannot have measured a sample it hasn't reached yet). No offset
        // is inferred and no timestamp is shifted.
        final now = DateTime(2026, 6, 23, 17, 36);
        final t = _StubTransport();
        final d = ChannelADispatcher(t);
        d.bind();
        final sync = _testSync(t, d, clock: () => now);
        final syncFuture = sync.syncAll(daysBack: 1);
        await Future<void>.delayed(const Duration(milliseconds: 20));

        t.inA.add(Codec.buildChannelA(OpA.readHeartRate, [0x00, 0x18, 0x05]));

        final record = Uint8List(23 * 13);
        record.fillRange(0, record.length, 0xff);
        for (var i = 0; i < 4; i++) {
          record[i] = 0;
        }
        record[4 + (17 * 12 + 6)] = 80; // slot 210 → 17:30, completed.
        record[4 + (17 * 12 + 7)] = 120; // slot 211 → 17:35, completed.
        record[4 + (17 * 12 + 8)] = 99; // slot 212 → 17:40, future → dropped.

        for (var chunk = 0; chunk < 23; chunk++) {
          final start = chunk * 13;
          t.inA.add(
            Codec.buildChannelA(OpA.readHeartRate, [
              chunk + 1,
              ...record.sublist(start, start + 13),
            ]),
          );
        }

        await Future<void>.delayed(const Duration(milliseconds: 150));
        await syncFuture;

        expect(sync.hr.map((s) => s.bpm), contains(80));
        expect(sync.hr.map((s) => s.bpm), contains(120));
        expect(sync.hr.map((s) => s.bpm), isNot(contains(99)));
        expect(sync.hr.any((s) => s.timestamp.isAfter(now)), isFalse);
        expect(sync.lastSyncError, isNull);
        // Anchored exactly at slot time — no drift shift.
        expect(
          sync.hr.lastWhere((s) => s.bpm == 120).timestamp,
          equals(DateTime(2026, 6, 23, 17, 35)),
        );

        sync.dispose();
        d.dispose();
      },
    );

    test('syncAll sends UTC day-start seconds for 0x15 HR history', () async {
      final t = _StubTransport();
      final d = ChannelADispatcher(t);
      d.bind();
      final sync = _testSync(t, d);
      final today = DateTime.now();
      final expectedSeconds =
          DateTime.utc(
            today.year,
            today.month,
            today.day,
          ).millisecondsSinceEpoch ~/
          1000;
      final future = sync.syncAll();
      // syncAll no longer sends 0x46 — it blind-polls day 0 directly.
      await Future<void>.delayed(const Duration(milliseconds: 20));
      await Future<void>.delayed(const Duration(milliseconds: 150));
      final sent = t.sent.firstWhere(
        (f) => f.isNotEmpty && f[0] == OpA.readHeartRate,
        orElse: () => Uint8List(0),
      );
      expect(sent, isNotEmpty);
      expect(
        Codec.readU32le(sent, 1),
        expectedSeconds,
        reason:
            '0x15 subData must be UTC day-start seconds; H59MAX replies '
            '0xff to packed BCD date bytes such as 26 06 21 00',
      );
      await Future<void>.delayed(const Duration(milliseconds: 1200));
      await future;
      sync.dispose();
      d.dispose();
    });

    test(
      'readHeartRate 0x15 error frame (pl[0]==0xff) clears pending chunks',
      () async {
        final t = _StubTransport();
        final d = ChannelADispatcher(t);
        d.bind();
        final sync = _testSync(t, d);
        final syncFuture = sync.syncAll();
        // syncAll no longer sends 0x46 — it blind-polls day 0 directly.
        // Wait for the per-day poll window.
        await Future<void>.delayed(const Duration(milliseconds: 150));
        t.inA.add(Codec.buildChannelA(OpA.readHeartRate, [0x18, 0x80, 0x05]));
        // seq=1, dayStart=0x6A34F600 (LE), 9 sample bytes (96, 100, 102)
        t.inA.add(
          Codec.buildChannelA(OpA.readHeartRate, [
            0x01,
            0x00, 0xF6, 0x34, 0x6A, // dayStart
            0x60, 0x64, 0x66, // 96, 100, 102
            0x00, 0x00, 0x00, 0x00, 0x00, 0x00, // padding
          ]),
        );
        t.inA.add(Codec.buildChannelA(OpA.readHeartRate, [0xff]));
        // Wait for the drain.
        await Future<void>.delayed(const Duration(milliseconds: 150));
        // The error frame shouldn't crash the parser. After a
        // complete record has been flushed, _hrChunks is reset, so
        // a subsequent 0xff is a no-op.
        expect(sync.hr, isNotEmpty);
        for (final s in sync.hr) {
          expect(s.bpm, inInclusiveRange(30, 240));
        }
        await syncFuture;
        sync.dispose();
        d.dispose();
      },
    );

    test(
      'queryDataDistribution 0x46|0x80 error response surfaces errorFlag '
      'via onQueryDataDistribution (regression for pattern-disjunction bug)',
      () async {
        final t = _StubTransport();
        final d = ChannelADispatcher(t);
        d.bind();
        final errorEvents = <QueryDataDistribution>[];
        final sub = d.onQueryDataDistribution.listen(errorEvents.add);
        d.markDistributionQuery();
        // Build a frame with the device-side error flag set on
        // opcode 0x46. The buildChannelA helper doesn't expose the
        // top bit, so OR it in after construction AND recompute the
        // checksum so the dispatcher's isValidChannelA() check passes.
        final f = _channelAErrorFrame(OpA.queryDataDistribution, [
          0xee,
          0x00,
          0x00,
          0x00,
        ]);
        t.inA.add(f);
        await Future<void>.delayed(const Duration(milliseconds: 20));
        expect(errorEvents.length, 1);
        expect(errorEvents.first.errorFlag, isTrue);
        await sub.cancel();
        d.dispose();
      },
    );

    test('late Channel-A HR frame is attributed to correct day even when '
        'sync loop has moved on (HS-8)', () async {
      final t = _StubTransport();
      final d = ChannelADispatcher(t);
      d.bind();
      final bp = ChannelBParser(t);
      final sync = _testSync(t, d, bParser: bp);
      final syncFuture = sync.syncAll(daysBack: 2);

      // Wait until today's HR poll is active (_currentSyncDay == today).
      // drainDuration is 50 ms, so the first-day window is short.
      await Future<void>.delayed(const Duration(milliseconds: 25));

      // Today: send a H59MAX header declaring 2 chunks total, then chunk 1.
      // The header captures today's day; the chunk does not flush yet because
      // only one chunk has arrived.
      // Day-start timestamp = 2026-06-19 00:00 UTC = 0x6A34F600 (LE).
      final dayStartBytes = [0x00, 0xF6, 0x34, 0x6A];
      t.inA.add(Codec.buildChannelA(OpA.readHeartRate, [0x00, 0x03, 0x05]));
      t.inA.add(
        Codec.buildChannelA(OpA.readHeartRate, [
          0x01, // seq=1 (captures series day; does not flush alone)
          ...dayStartBytes,
          0x60, 0x64, 0x66, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        ]),
      );

      // Let today's drain finish and give the next poll/sleep/activity phase
      // time to start so that _currentSyncDay has moved on.
      await Future<void>.delayed(const Duration(milliseconds: 85));

      // Now inject the SECOND chunk for TODAY, but AFTER the sync loop
      // has moved past today's HR window. In the old code this
      // would be mis-attributed to the current day because _flushHrChunks read
      // _currentSyncDay at flush time. With HS-8 fix, the series day is
      // captured when the header arrives.
      t.inA.add(
        Codec.buildChannelA(OpA.readHeartRate, [
          0x02, // seq=2 (length >= expected, so flush)
          ...dayStartBytes,
          0x6A, 0x6E, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        ]),
      );

      // Wait for the drain to process the late frame.
      await Future<void>.delayed(const Duration(milliseconds: 80));

      // Let sync finish.
      await syncFuture;

      // The late frame should be attributed to today, not yesterday.
      final today = DateOnly.today();
      final yesterday = today.addDays(-1);
      final todayHistory = sync.dayOf(today);
      final yesterdayHistory = sync.dayOf(yesterday);

      expect(todayHistory, isNotNull);
      expect(
        todayHistory!.hr,
        isNotEmpty,
        reason: 'today should have HR samples from the late frame',
      );

      // Yesterday should have no HR samples (we only sent a header for
      // today, and the late chunk was for today).
      expect(
        yesterdayHistory == null || yesterdayHistory.hr.isEmpty,
        isTrue,
        reason: 'yesterday must not receive today\'s late HR samples',
      );

      sync.dispose();
      d.dispose();
      bp.dispose();
    });

    test('0xFF empty-day frame is attributed to correct day when captured '
        '(HS-8)', () async {
      final t = _StubTransport();
      final d = ChannelADispatcher(t);
      d.bind();
      final sync = _testSync(t, d);
      final syncFuture = sync.syncAll(daysBack: 2);

      // Wait for today HR poll.
      await Future<void>.delayed(const Duration(milliseconds: 150));

      // Send an empty-day response for today.
      t.inA.add(Codec.buildChannelA(OpA.readHeartRate, [0xff]));

      // Wait for drain.
      await Future<void>.delayed(const Duration(milliseconds: 150));

      // Wait for yesterday HR poll.
      await Future<void>.delayed(const Duration(milliseconds: 150));

      // Now send a late 0xFF for today, after _currentSyncDay has moved
      // to yesterday. With HS-8, the day is captured at enqueue time.
      t.inA.add(Codec.buildChannelA(OpA.readHeartRate, [0xff]));

      // Wait for drain.
      await Future<void>.delayed(const Duration(milliseconds: 150));

      await syncFuture;

      // Both days should have empty HR records (the 0xFF commits an
      // empty day). The late 0xFF should not create a duplicate or
      // mis-attributed record.
      final today = DateOnly.today();
      final yesterday = today.addDays(-1);
      final todayHistory = sync.dayOf(today);
      final yesterdayHistory = sync.dayOf(yesterday);

      expect(todayHistory, isNotNull);
      expect(todayHistory!.hr, isEmpty);

      // Yesterday should also be empty (no chunks sent for it).
      expect(yesterdayHistory == null || yesterdayHistory.hr.isEmpty, isTrue);

      sync.dispose();
      d.dispose();
    });

    // ------------------------------------------------------------------
    // 0x37 stress history + 0x39 HRV history two-phase reassembly.
    // Wired via FragmentReassembler — GHIDRA §3.20 / §3.21.
    // ------------------------------------------------------------------

    test(
      'stress history 0x37 header + 4 chunks assembles into one '
      'PressureRecord (regression for §3.20 two-phase wire format)',
      () async {
        final t = _StubTransport();
        final d = ChannelADispatcher(t);
        d.bind();
        final sync = _testSync(t, d);

        final producerHeader = [0xAA, 0xBB, 0xCC, 0xDD];
        final body = List<int>.generate(45, (i) => 0x10 + i);
        final all = [...producerHeader, ...body];
        // Pad the 49-byte payload up to 56 = 4 frames × 14 bytes so
        // the test assertions don't depend on trailing-zero behaviour.
        final padded = [...all, ...List<int>.filled(56 - all.length, 0xEE)];
        const chunkSize = 14;

        // Start listening first so no chunk is lost, then await the
        // single assembled record instead of polling a fixed delay.
        // This removes the timing flakiness that failed on slower CI
        // runners when the 250 ms quiet window hadn't quite fired.
        final expectation = expectLater(
          sync.pressureRecords,
          emits(
            isA<PressureRecord>()
                .having((r) => r.slotId, 'slotId', 0x00)
                .having((r) => r.header, 'header', producerHeader)
                .having((r) => r.body, 'body', [
                  ...body,
                  0xEE,
                  0xEE,
                  0xEE,
                  0xEE,
                  0xEE,
                  0xEE,
                  0xEE,
                ]),
          ),
        );

        // Header: pl[2] == 0x1E discriminator, pl[0] = slotId = 0
        t.inA.add(
          Codec.buildChannelA(OpA.pressure, [
            0x00, // slotId
            0x05, // padding for header literal
            0x1e, // discriminator
          ]),
        );
        for (var i = 0; i < 4; i++) {
          t.inA.add(
            Codec.buildChannelA(
              OpA.pressure,
              padded.sublist(i * chunkSize, (i + 1) * chunkSize),
            ),
          );
        }

        await expectation;
        sync.dispose();
        d.dispose();
      },
    );

    test('HRV history 0x39 header + 4 chunks assembles into one '
        'HrvRecord (regression for §3.21 two-phase wire format)', () async {
      final t = _StubTransport();
      final d = ChannelADispatcher(t);
      d.bind();
      final sync = _testSync(t, d);

      final producerHeader = [0x11, 0x22, 0x33, 0x44];
      final body = List<int>.generate(45, (i) => 0x40 + i);
      final all = [...producerHeader, ...body];
      final padded = [...all, ...List<int>.filled(56 - all.length, 0xEE)];
      const chunkSize = 14;

      final expectation = expectLater(
        sync.hrvRecords,
        emits(
          isA<HrvRecord>()
              .having((r) => r.slotId, 'slotId', 0x00)
              .having((r) => r.header, 'header', producerHeader)
              .having((r) => r.body, 'body', [
                ...body,
                0xEE,
                0xEE,
                0xEE,
                0xEE,
                0xEE,
                0xEE,
                0xEE,
              ]),
        ),
      );

      // Header: pl[2] == 0x1E discriminator, pl[0] = slotId = 0
      t.inA.add(Codec.buildChannelA(OpA.hrv, [0x00, 0x05, 0x1e]));
      for (var i = 0; i < 4; i++) {
        t.inA.add(
          Codec.buildChannelA(
            OpA.hrv,
            padded.sublist(i * chunkSize, (i + 1) * chunkSize),
          ),
        );
      }

      await expectation;
      sync.dispose();
      d.dispose();
    });

    test('stress history 0x37 two back-to-back records emit two '
        'PressureRecords (regression for reassembler over multiple '
        'phases)', () async {
      final t = _StubTransport();
      final d = ChannelADispatcher(t);
      d.bind();
      final sync = _testSync(t, d);
      final records = <PressureRecord>[];
      final sub = sync.pressureRecords.listen(records.add);

      // Record #1
      t.inA.add(Codec.buildChannelA(OpA.pressure, [0x00, 0x05, 0x1e]));
      // 49-byte payload split across 4 frames of 14 subData bytes
      // (we send 56 total bytes — the test only asserts on the
      // header slot + first 45 body bytes, so over-padding with
      // a sentinel is harmless).
      const rec1 = [
        0xA1, 0xA2, 0xA3, 0xA4, // producer header
        0x10, 0x11, 0x12, 0x13, 0x14, 0x15, 0x16, 0x17, 0x18, 0x19, 0x1A,
        0x1B, 0x1C, 0x1D, 0x1E, 0x1F, 0x20, 0x21, 0x22, 0x23, 0x24, 0x25,
        0x26, 0x27, 0x28, 0x29, 0x2A, 0x2B, 0x2C, 0x2D, 0x2E, 0x2F,
        0x30, 0x31, 0x32, 0x33, 0x34, 0x35, 0x36, 0x37, 0x38, 0x39,
        0x3A, 0x3B, 0x3C, 0x3D, 0x3E, 0x3F, 0x40, 0x41, 0x42,
        // pad 7 sentinel bytes so 4 × 14 = 56 fits exactly.
        0xEE, 0xEE, 0xEE, 0xEE, 0xEE, 0xEE, 0xEE,
      ];
      const chunkSize = 14;
      for (var i = 0; i < 4; i++) {
        t.inA.add(
          Codec.buildChannelA(
            OpA.pressure,
            rec1.sublist(i * chunkSize, (i + 1) * chunkSize),
          ),
        );
      }
      // Wait past the quiet window so #1 fires.
      await Future<void>.delayed(const Duration(milliseconds: 250));
      expect(records, hasLength(1));

      // Record #2 — different slotId so we can verify it carried.
      t.inA.add(Codec.buildChannelA(OpA.pressure, [0x01, 0x05, 0x1e]));
      const rec2 = [
        0xB1,
        0xB2,
        0xB3,
        0xB4,
        0x50,
        0x51,
        0x52,
        0x53,
        0x54,
        0x55,
        0x56,
        0x57,
        0x58,
        0x59,
        0x5A,
        0x5B,
        0x5C,
        0x5D,
        0x5E,
        0x5F,
        0x60,
        0x61,
        0x62,
        0x63,
        0x64,
        0x65,
        0x66,
        0x67,
        0x68,
        0x69,
        0x6A,
        0x6B,
        0x6C,
        0x6D,
        0x6E,
        0x6F,
        0x70,
        0x71,
        0x72,
        0x73,
        0x74,
        0x75,
        0x76,
        0x77,
        0x78,
        0x79,
        0x7A,
        0x7B,
        0x7C,
        0x7D,
        0x7E,
        0x7F,
        0x80,
        0x81,
        0x82,
        0xEE,
        0xEE,
        0xEE,
        0xEE,
        0xEE,
        0xEE,
        0xEE,
      ];
      for (var i = 0; i < 4; i++) {
        t.inA.add(
          Codec.buildChannelA(
            OpA.pressure,
            rec2.sublist(i * chunkSize, (i + 1) * chunkSize),
          ),
        );
      }
      await Future<void>.delayed(const Duration(milliseconds: 250));
      expect(records, hasLength(2));
      expect(records[0].slotId, 0x00);
      expect(records[1].slotId, 0x01);
      await sub.cancel();
      sync.dispose();
      d.dispose();
    });

    test(
      'stress history 0x37 fixed slots are stored on the matching day',
      () async {
        final t = _StubTransport();
        final d = ChannelADispatcher(t);
        d.bind();
        final now = DateTime(2026, 6, 23, 23, 59);
        final sync = _testSync(t, d, clock: () => now);

        final samples = List<int>.filled(48, 0);
        samples[0] = 21;
        samples[12] = 44;
        samples[47] = 68;
        final raw = [0x00, ...samples, ...List<int>.filled(7, 0)];
        const chunkSize = 14;

        t.inA.add(Codec.buildChannelA(OpA.pressure, [0x00, 0x05, 0x1e]));
        for (var i = 0; i < 4; i++) {
          t.inA.add(
            Codec.buildChannelA(
              OpA.pressure,
              raw.sublist(i * chunkSize, (i + 1) * chunkSize),
            ),
          );
        }
        await Future<void>.delayed(const Duration(milliseconds: 80));

        final today = DateOnly.fromDateTime(now);
        final history = sync.dayOf(today);
        expect(history, isNotNull);
        expect(history!.stress.map((s) => s.value), [21, 44, 68]);
        // Protocol-faithful decode: each byte is a 30-min slot anchored at
        // the requested day's midnight. samples[12]=44 is slot 12 → 06:00
        // exactly. No clock-offset is inferred and no timestamp is shifted.
        expect(
          history.stress[1].timestamp,
          today.midnight.add(const Duration(minutes: 6 * 60)),
        );

        sync.dispose();
        d.dispose();
      },
    );

    // ------------------------------------------------------------------
    // HS-5: ChannelBParser null → skip sleep/activity commands.
    // ------------------------------------------------------------------

    test(
      'syncAll skips sleep and activity commands when ChannelBParser is null (HS-5)',
      () async {
        final t = _StubTransport();
        final d = ChannelADispatcher(t);
        d.bind();
        final sync = _testSync(t, d, bParser: null);
        final future = sync.syncAll(daysBack: 1);
        await Future<void>.delayed(const Duration(milliseconds: 20));
        await future;

        // No sleep or activity commands should be sent on Channel B.
        expect(
          t.sentB.where(
            (f) => f.isNotEmpty && Codec.rxChannelBCmd(f) == OpB.sleepNew,
          ),
          isEmpty,
          reason: '0x27 sleepNew must not be sent when bParser is null',
        );
        expect(
          t.sentB.where(
            (f) => f.isNotEmpty && Codec.rxChannelBCmd(f) == OpB.sleepLunchNew,
          ),
          isEmpty,
          reason: '0x3e sleepLunchNew must not be sent when bParser is null',
        );
        expect(
          t.sentB.where(
            (f) =>
                f.isNotEmpty && Codec.rxChannelBCmd(f) == OpB.activitySummary,
          ),
          isEmpty,
          reason: '0x2a activitySummary must not be sent when bParser is null',
        );

        // HR sync should still proceed normally.
        expect(
          t.sent.where((f) => f.isNotEmpty && f[0] == OpA.readHeartRate),
          isNotEmpty,
        );

        sync.dispose();
        d.dispose();
      },
    );

    test(
      'syncAll sends only 0x27 sleep (not redundant 0x3e) when ChannelBParser is provided',
      () async {
        final t = _StubTransport();
        final d = ChannelADispatcher(t);
        final bParser = ChannelBParser(t);
        d.bind();
        final sync = _testSync(t, d, bParser: bParser);
        final future = sync.syncAll(daysBack: 1);
        await Future<void>.delayed(const Duration(milliseconds: 20));
        await future;

        // 0x27 sleepNew must be sent.
        expect(
          t.sentB.where(
            (f) => f.isNotEmpty && Codec.rxChannelBCmd(f) == OpB.sleepNew,
          ),
          isNotEmpty,
          reason: '0x27 sleepNew must be sent when bParser is provided',
        );
        // 0x3e sleepLunchNew must NOT be sent — the firmware always
        // emits both 0x27 and 0x3e responses from a single 0x27 request
        // per GHIDRA_DECOMPILATION.md §2.3.
        expect(
          t.sentB.where(
            (f) => f.isNotEmpty && Codec.rxChannelBCmd(f) == OpB.sleepLunchNew,
          ),
          isEmpty,
          reason: '0x3e sleepLunchNew is redundant; 0x27 alone triggers both',
        );

        sync.dispose();
        d.dispose();
      },
    );

    test(
      'syncAll preserves persisted sleep when sleep fetch has no response',
      () async {
        final t = _StubTransport();
        final d = ChannelADispatcher(t);
        final bParser = ChannelBParser(t);
        d.bind();
        final sync = _testSync(t, d, bParser: bParser);

        final today = DateOnly.today();
        final yesterday = today.addDays(-1);
        final staleSleep = SleepSegment(
          yesterday.midnight.add(const Duration(hours: 21)),
          const Duration(minutes: 45),
          SleepStage.deep,
        );
        final fakeStore = _FakeHistoryStore(
          seed: {
            yesterday: DailyHistory(
              day: yesterday,
              hr: [
                HrSample(yesterday.midnight.add(const Duration(hours: 8)), 62),
              ],
              sleep: [staleSleep],
              steps: 4321,
              energyKcal: 210,
              distanceMeters: 3100,
            ),
          },
        );
        await sync.bindStore(fakeStore);

        // No 0x27/0x3e responses are injected. A missed or malformed sleep
        // response must not erase a previously stored night.
        await sync.syncAll(daysBack: 1);

        final restored = sync.dayOf(yesterday);
        expect(restored, isNotNull);
        expect(restored!.sleep, [staleSleep]);
        expect(restored.hr, hasLength(1));
        expect(restored.steps, 4321);
        expect((await fakeStore.readDay(yesterday)).sleep, [staleSleep]);

        sync.dispose();
        d.dispose();
      },
    );

    test(
      'explicit empty sleep response clears persisted wake window',
      () async {
        final t = _StubTransport();
        final d = ChannelADispatcher(t);
        final bParser = ChannelBParser(t);
        d.bind();
        final sync = _testSync(t, d, bParser: bParser);

        final today = DateOnly.today();
        final yesterday = today.addDays(-1);
        final staleSleep = SleepSegment(
          yesterday.midnight.add(const Duration(hours: 21)),
          const Duration(minutes: 45),
          SleepStage.deep,
        );
        final fakeStore = _FakeHistoryStore(
          seed: {
            yesterday: DailyHistory(day: yesterday, sleep: [staleSleep]),
          },
        );
        await sync.bindStore(fakeStore);

        t.inB.add(Codec.buildChannelB(OpB.sleepNew));
        await Future<void>.delayed(const Duration(milliseconds: 50));

        expect(sync.dayOf(yesterday)!.sleep, isEmpty);
        expect((await fakeStore.readDay(yesterday)).sleep, isEmpty);

        sync.dispose();
        d.dispose();
      },
    );

    test('activity summary 0x2a parses dayOffset=0 as a valid today entry '
        'after yesterday (HS-7)', () async {
      final t = _StubTransport();
      final d = ChannelADispatcher(t);
      final bParser = ChannelBParser(t);
      d.bind();
      final sync = _testSync(t, d, bParser: bParser);
      final future = sync.syncAll(daysBack: 1);
      await Future<void>.delayed(const Duration(milliseconds: 20));

      // Firmware emits entries in descending day-offset order.
      // A dayOffset=0 entry in the middle is today's data, not a
      // terminator — parsing must continue to the payload end.
      final body1 = List<int>.filled(48, 0x00);
      body1[0] = 0x00;
      body1[1] = 0x00;
      body1[2] = 0x64; // steps = 100
      body1[6] = 0x00;
      body1[7] = 0x00;
      body1[8] = 0x32; // calories = 50
      body1[9] = 0x00;
      body1[10] = 0x00;
      body1[11] = 0x50; // distance = 80

      final body0 = List<int>.filled(48, 0x00);
      body0[0] = 0x00;
      body0[1] = 0x00;
      body0[2] = 0xC8; // steps = 200
      body0[6] = 0x00;
      body0[7] = 0x00;
      body0[8] = 0x64; // calories = 100
      body0[9] = 0x00;
      body0[10] = 0x00;
      body0[11] = 0xA0; // distance = 160

      final payload = Uint8List.fromList([
        0x01, ...body1, // yesterday with data
        0x00, ...body0, // today with data
      ]);
      t.inB.add(Codec.buildChannelB(OpB.activitySummary, payload));

      await future;

      final yesterday = DateOnly.today().addDays(-1);
      final yestHistory = sync.dayOf(yesterday);
      expect(yestHistory, isNotNull);
      expect(yestHistory!.steps, 100);
      expect(yestHistory.energyKcal, 50);
      expect(yestHistory.distanceMeters, 80);

      final today = DateOnly.today();
      final todayHistory = sync.dayOf(today);
      expect(todayHistory, isNotNull);
      expect(todayHistory!.steps, 200);
      expect(todayHistory.energyKcal, 100);
      expect(todayHistory.distanceMeters, 160);

      sync.dispose();
      d.dispose();
    });

    test('activity summary 0x2a parses all three day offsets in firmware order '
        '[2, 1, 0] (HS-7)', () async {
      final t = _StubTransport();
      final d = ChannelADispatcher(t);
      final bParser = ChannelBParser(t);
      d.bind();
      final sync = _testSync(t, d, bParser: bParser);
      final future = sync.syncAll(daysBack: 2);
      await Future<void>.delayed(const Duration(milliseconds: 20));

      Uint8List body(int steps) {
        final b = List<int>.filled(48, 0x00);
        b[0] = 0x00;
        b[1] = 0x00;
        b[2] = steps;
        return Uint8List.fromList(b);
      }

      final payload = Uint8List.fromList([
        0x02, ...body(0x10), // 2 days ago: 16 steps
        0x01, ...body(0x20), // yesterday: 32 steps
        0x00, ...body(0x30), // today: 48 steps
      ]);
      t.inB.add(Codec.buildChannelB(OpB.activitySummary, payload));

      await future;

      final today = DateOnly.today();
      final yesterday = today.addDays(-1);
      final twoDaysAgo = today.addDays(-2);

      expect(sync.dayOf(today)?.steps, 0x30);
      expect(sync.dayOf(yesterday)?.steps, 0x20);
      expect(sync.dayOf(twoDaysAgo)?.steps, 0x10);

      sync.dispose();
      d.dispose();
    });

    test(
      'activity summary 0x2a first entry dayOffset=0 is not a terminator (HS-7)',
      () async {
        final t = _StubTransport();
        final d = ChannelADispatcher(t);
        final bParser = ChannelBParser(t);
        d.bind();
        final sync = _testSync(t, d, bParser: bParser);
        final future = sync.syncAll(daysBack: 0);
        await Future<void>.delayed(const Duration(milliseconds: 20));

        // Build a Channel-B 0x2a payload with one entry:
        //   dayOffset = 0 (today), body has data
        // The offset > 0 guard means the first entry is never treated as a
        // terminator, even if dayOffset == 0.
        final body = List<int>.filled(48, 0x00);
        body[0] = 0x00;
        body[1] = 0x00;
        body[2] = 0x64; // steps = 100
        final payload = Uint8List.fromList([0x00, ...body]);
        t.inB.add(Codec.buildChannelB(OpB.activitySummary, payload));

        await future;

        final today = DateOnly.today();
        final todayHistory = sync.dayOf(today);
        expect(todayHistory, isNotNull);
        expect(todayHistory!.steps, 100);

        sync.dispose();
        d.dispose();
      },
    );

    // ------------------------------------------------------------------
    // HS-6: Step/calorie totals must not fallback to previous day on 0.
    // ------------------------------------------------------------------

    test('activity summary 0x2a with all-zero body preserves nulls, '
        'not previous-day totals (HS-6)', () async {
      final t = _StubTransport();
      final d = ChannelADispatcher(t);
      final bParser = ChannelBParser(t);
      d.bind();
      final sync = _testSync(t, d, bParser: bParser);

      // Pre-seed yesterday with non-zero totals via a fake store so
      // _days is hydrated before syncAll runs.
      final yesterday = DateOnly.today().addDays(-1);
      final fakeStore = _FakeHistoryStore(
        seed: {
          yesterday: DailyHistory(
            day: yesterday,
            steps: 12345,
            energyKcal: 678,
            distanceMeters: 9876,
          ),
        },
      );
      await sync.bindStore(fakeStore);

      final future = sync.syncAll(daysBack: 1);
      await Future<void>.delayed(const Duration(milliseconds: 20));

      // Build a Channel-B 0x2a payload with one entry:
      //   dayOffset = 0 (today)
      //   48-byte body all zeros → genuine "no activity yet today"
      final body = List<int>.filled(48, 0x00);
      final payload = Uint8List.fromList([0x00, ...body]);
      t.inB.add(Codec.buildChannelB(OpB.activitySummary, payload));

      await future;

      final today = DateOnly.today();
      final todayHistory = sync.dayOf(today);
      expect(todayHistory, isNotNull);
      // The all-zero body must produce null totals, NOT fallback to
      // yesterday's 12345/678/9876 values.
      expect(
        todayHistory!.steps,
        isNull,
        reason: 'steps must be null for all-zero body',
      );
      expect(
        todayHistory.energyKcal,
        isNull,
        reason: 'calories must be null for all-zero body',
      );
      expect(
        todayHistory.distanceMeters,
        isNull,
        reason: 'distance must be null for all-zero body',
      );

      // Yesterday must remain untouched.
      final yestHistory = sync.dayOf(yesterday);
      expect(yestHistory!.steps, 12345);
      expect(yestHistory.energyKcal, 678);
      expect(yestHistory.distanceMeters, 9876);

      sync.dispose();
      d.dispose();
    });

    test('activity summary 0x2a with zero steps but non-zero calories '
        'keeps steps=0 (HS-6)', () async {
      final t = _StubTransport();
      final d = ChannelADispatcher(t);
      final bParser = ChannelBParser(t);
      d.bind();
      final sync = _testSync(t, d, bParser: bParser);
      final future = sync.syncAll(daysBack: 0);
      await Future<void>.delayed(const Duration(milliseconds: 20));

      // Build a Channel-B 0x2a payload:
      //   dayOffset = 0 (today)
      //   body: steps = 0 (u24 BE @ 0), calories = 1500 (u24 BE @ 6),
      //         distance = 2000 (u24 BE @ 9)
      final body = List<int>.filled(48, 0x00);
      body[0] = 0x00;
      body[1] = 0x00;
      body[2] = 0x00; // steps = 0
      body[6] = 0x00;
      body[7] = 0x05;
      body[8] = 0xDC; // calories = 1500 (0x05DC)
      body[9] = 0x00;
      body[10] = 0x07;
      body[11] = 0xD0; // distance = 2000 (0x07D0)
      final payload = Uint8List.fromList([0x00, ...body]);
      t.inB.add(Codec.buildChannelB(OpB.activitySummary, payload));

      await future;

      final today = DateOnly.today();
      final todayHistory = sync.dayOf(today);
      expect(todayHistory, isNotNull);
      // steps = 0 is genuine zero activity, not "no data".
      expect(todayHistory!.steps, 0, reason: 'steps must be 0, not null');
      expect(todayHistory.energyKcal, 1500);
      expect(todayHistory.distanceMeters, 2000);

      sync.dispose();
      d.dispose();
    });

    test('activity summary 0x2a absurd-clamped values become null '
        'instead of 0 (HS-6)', () async {
      final t = _StubTransport();
      final d = ChannelADispatcher(t);
      final bParser = ChannelBParser(t);
      d.bind();
      final sync = _testSync(t, d, bParser: bParser);
      final future = sync.syncAll(daysBack: 0);
      await Future<void>.delayed(const Duration(milliseconds: 20));

      // Build a Channel-B 0x2a payload with absurd values that exceed
      // the sanity clamps in _activityTotalsFromBody.
      final body = List<int>.filled(48, 0x00);
      // steps = 999_999 (> 200_000 clamp)
      body[0] = 0x0F;
      body[1] = 0x42;
      body[2] = 0x3F;
      // calories = 99_999 (> 20_000 clamp)
      body[6] = 0x01;
      body[7] = 0x86;
      body[8] = 0x9F;
      // distance = 999_999 (> 200_000 clamp)
      body[9] = 0x0F;
      body[10] = 0x42;
      body[11] = 0x3F;
      final payload = Uint8List.fromList([0x00, ...body]);
      t.inB.add(Codec.buildChannelB(OpB.activitySummary, payload));

      await future;

      final today = DateOnly.today();
      final todayHistory = sync.dayOf(today);
      expect(todayHistory, isNotNull);
      // Clamped values must be null so the UI can show "no data"
      // and _upsertTotals won't fall back to stale previous-day values.
      expect(
        todayHistory!.steps,
        isNull,
        reason: 'absurd steps must clamp to null',
      );
      expect(
        todayHistory.energyKcal,
        isNull,
        reason: 'absurd calories must clamp to null',
      );
      expect(
        todayHistory.distanceMeters,
        isNull,
        reason: 'absurd distance must clamp to null',
      );

      sync.dispose();
      d.dispose();
    });

    // ------------------------------------------------------------------
    // 0x43 sport detail paging validation.
    // ------------------------------------------------------------------

    test('0x43 sport detail defers totals until final page arrives '
        '(regression for partial paged response)', () async {
      final t = _StubTransport();
      final d = ChannelADispatcher(t);
      d.bind();
      final now = DateTime(2026, 6, 21, 12);
      final sync = _testSync(t, d, clock: () => now);
      final syncFuture = sync.syncAll(daysBack: 1);
      await Future<void>.delayed(const Duration(milliseconds: 20));

      // Page 0 of 2: steps=100, distance=50. Not final page — totals
      // must NOT be written yet. BCD date matches the clock day.
      t.inA.add(
        Codec.buildChannelA(OpA.readDetailSport, [
          0x26, // year BCD = 38 → 2038? No, 0x26 = 2*16+6 = 38... wait.
          // Actually BCD: 0x26 = tens=2, units=6 → 26. Year = 2000 + 26 = 2026.
          0x06, // month BCD = 6
          0x21, // day BCD = 21
          0x00, // slot << 2
          0x00, // page = 0
          0x02, // total = 2
          0x00,
          0x0A, // duration = 10
          0x64,
          0x00, // steps = 100
          0x32,
          0x00, // distance = 50
        ]),
      );
      await Future<void>.delayed(const Duration(milliseconds: 150));

      final today = DateOnly.fromDateTime(now);
      final historyBefore = sync.dayOf(today);
      // Totals should not exist yet because page 0 < total-1.
      expect(
        historyBefore == null || historyBefore.steps == null,
        isTrue,
        reason: 'partial page must not write totals',
      );

      // Page 1 of 2 (final): steps=200, distance=80.
      t.inA.add(
        Codec.buildChannelA(OpA.readDetailSport, [
          0x26,
          0x06,
          0x21,
          0x04, // slot << 2 (next slot)
          0x01, // page = 1 (final)
          0x02, // total = 2
          0x00,
          0x14, // duration = 20
          0xC8,
          0x00, // steps = 200
          0x50,
          0x00, // distance = 80
        ]),
      );
      await Future<void>.delayed(const Duration(milliseconds: 150));
      await syncFuture;

      final historyAfter = sync.dayOf(today);
      expect(historyAfter, isNotNull);
      // After final page, accumulated totals = 100 + 200 = 300 steps,
      // 50 + 80 = 130 distance.
      expect(historyAfter!.steps, 300);
      expect(historyAfter.distanceMeters, 130);

      sync.dispose();
      d.dispose();
    });

    test('0x43 sport detail single-page response (page==total-1) writes '
        'totals immediately', () async {
      final t = _StubTransport();
      final d = ChannelADispatcher(t);
      d.bind();
      final now = DateTime(2026, 6, 21, 12);
      final sync = _testSync(t, d, clock: () => now);
      final syncFuture = sync.syncAll(daysBack: 1);
      await Future<void>.delayed(const Duration(milliseconds: 20));

      // Single page: page=0, total=1 → final page, totals write immediately.
      // BCD date matches the clock day.
      t.inA.add(
        Codec.buildChannelA(OpA.readDetailSport, [
          0x26,
          0x06,
          0x21,
          0x00,
          0x00, // page = 0
          0x01, // total = 1
          0x00,
          0x0A,
          0x2B,
          0x01, // steps = 299
          0x5E,
          0x01, // distance = 350
        ]),
      );
      await Future<void>.delayed(const Duration(milliseconds: 150));
      await syncFuture;

      final today = DateOnly.fromDateTime(now);
      final history = sync.dayOf(today);
      expect(history, isNotNull);
      expect(history!.steps, 299);
      expect(history.distanceMeters, 350);

      sync.dispose();
      d.dispose();
    });
  });
}

/// A minimal fake store that satisfies bindStore without touching disk.
class _FakeHistoryStore implements HistoryStore {
  _FakeHistoryStore({Map<DateOnly, DailyHistory>? seed}) : _seed = seed ?? {};

  final Map<DateOnly, DailyHistory> _seed;
  DateTime? _lastSyncedAt;
  DateOnly? _lastSyncDay;

  @override
  Future<void> writeDay(DailyHistory history, {DateTime? lastUpdated}) async {
    _seed[history.day] = history;
  }

  @override
  Future<DailyHistory> readDay(DateOnly day) async =>
      _seed[day] ?? DailyHistory(day: day);

  @override
  Future<List<DateOnly>> persistedDays() async => _seed.keys.toList();

  @override
  DateTime? get lastSyncedAt => _lastSyncedAt;

  @override
  Future<List<DailyHistory>> readRange(DateOnly from, DateOnly to) async {
    final days = from.daysTo(to);
    final out = <DailyHistory>[];
    for (var i = 0; i <= days; i++) {
      out.add(await readDay(from.addDays(i)));
    }
    return out;
  }

  @override
  DateOnly? get lastSyncedDay => _lastSyncDay;

  Future<void> setLastSyncDay(DateOnly day) async {
    _lastSyncDay = day;
  }

  @override
  Future<DailyHistory> mergeHr(
    DateOnly day,
    Iterable<HrSample> hrSamples,
  ) async {
    final current = _seed[day] ?? DailyHistory(day: day);
    final byTs = <int, HrSample>{
      for (final h in current.hr) h.timestamp.millisecondsSinceEpoch: h,
    };
    for (final h in hrSamples) {
      byTs[h.timestamp.millisecondsSinceEpoch] = h;
    }
    final merged = byTs.values.toList()
      ..sort((a, b) => a.timestamp.compareTo(b.timestamp));
    final updated = current.copyWith(hr: merged, lastUpdated: DateTime.now());
    _seed[day] = updated;
    return updated;
  }

  @override
  Future<DailyHistory> mergeSleep(
    DateOnly day,
    Iterable<SleepSegment> segments,
  ) async {
    final current = _seed[day] ?? DailyHistory(day: day);
    final byStart = <int, SleepSegment>{
      for (final s in current.sleep) s.start.millisecondsSinceEpoch: s,
    };
    for (final s in segments) {
      byStart[s.start.millisecondsSinceEpoch] = s;
    }
    final merged = byStart.values.toList()
      ..sort((a, b) => a.start.compareTo(b.start));
    final updated = current.copyWith(
      sleep: merged,
      lastUpdated: DateTime.now(),
    );
    _seed[day] = updated;
    return updated;
  }

  @override
  Future<DailyHistory> recordTotals(
    DateOnly day, {
    required int steps,
    required int energyKcal,
    required int distanceMeters,
  }) async {
    final current = _seed[day] ?? DailyHistory(day: day);
    final updated = current.copyWith(
      steps: steps,
      energyKcal: energyKcal,
      distanceMeters: distanceMeters,
      lastUpdated: DateTime.now(),
    );
    _seed[day] = updated;
    return updated;
  }

  @override
  Future<DailyHistory> mergeStress(
    DateOnly day,
    Iterable<HealthMetricSample> samples,
  ) async {
    final current = _seed[day] ?? DailyHistory(day: day);
    final updated = current.copyWith(
      stress: _mergeScalar(current.stress, samples),
      lastUpdated: DateTime.now(),
    );
    _seed[day] = updated;
    return updated;
  }

  @override
  Future<DailyHistory> mergeHrv(
    DateOnly day,
    Iterable<HealthMetricSample> samples,
  ) async {
    final current = _seed[day] ?? DailyHistory(day: day);
    final updated = current.copyWith(
      hrv: _mergeScalar(current.hrv, samples),
      lastUpdated: DateTime.now(),
    );
    _seed[day] = updated;
    return updated;
  }

  @override
  Future<DailyHistory> mergeBloodPressure(
    DateOnly day,
    Iterable<BloodPressureSample> samples,
  ) async {
    final current = _seed[day] ?? DailyHistory(day: day);
    final byTs = <int, BloodPressureSample>{
      for (final s in current.bloodPressure)
        s.timestamp.millisecondsSinceEpoch: s,
      for (final s in samples) s.timestamp.millisecondsSinceEpoch: s,
    };
    final updated = current.copyWith(
      bloodPressure: byTs.values.toList()
        ..sort((a, b) => a.timestamp.compareTo(b.timestamp)),
      lastUpdated: DateTime.now(),
    );
    _seed[day] = updated;
    return updated;
  }

  List<HealthMetricSample> _mergeScalar(
    List<HealthMetricSample> existing,
    Iterable<HealthMetricSample> incoming,
  ) {
    final byTs = <int, HealthMetricSample>{
      for (final s in existing) s.timestamp.millisecondsSinceEpoch: s,
      for (final s in incoming) s.timestamp.millisecondsSinceEpoch: s,
    };
    return byTs.values.toList()
      ..sort((a, b) => a.timestamp.compareTo(b.timestamp));
  }

  @override
  Future<void> markSynced(DateTime at) async {
    _lastSyncedAt = at;
  }

  @override
  Future<void> clearAll() async {
    _seed.clear();
    _lastSyncedAt = null;
    _lastSyncDay = null;
  }

  @override
  Future<Map<String, dynamic>> exportAll() async => {
    'schemaVersion': 1,
    'exportedAt': DateTime.now().toUtc().toIso8601String(),
    'watermarks': {
      'lastSyncedAt': _lastSyncedAt?.toUtc().toIso8601String(),
      'lastSyncDay': _lastSyncDay?.iso,
    },
    'days': [
      for (final e in _seed.entries)
        {'date': e.key.iso, 'data': e.value.toJson()},
    ],
  };
}
