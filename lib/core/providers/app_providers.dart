import 'dart:async';

import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';

import '../ble/ble_transport.dart';
import '../services/bp_raw_store.dart';
import '../services/cloud_api.dart';
import '../services/firmware_service.dart';
import '../services/history_store.dart';
import '../services/history_sync.dart';
import '../services/settings_service.dart';
import '../services/watch_manager.dart';

// --- Settings (offline-first) -----------------------------------------------

final settingsServiceProvider = FutureProvider<SettingsService>(
  (ref) => SettingsService.create(),
);

/// Current app settings. Defaults to offline-first until prefs load.
final settingsProvider = NotifierProvider<SettingsNotifier, AppSettings>(
  SettingsNotifier.new,
);

class SettingsNotifier extends Notifier<AppSettings> {
  SettingsService? _service;

  @override
  AppSettings build() {
    // Hydrate asynchronously; start from safe offline-first defaults.
    ref.listen(settingsServiceProvider, (_, next) {
      final svc = next.value;
      if (svc != null) {
        _service = svc;
        state = svc.load();
      }
    }, fireImmediately: true);
    return const AppSettings();
  }

  Future<void> update(AppSettings settings) async {
    state = settings;
    await _service?.save(settings);
  }

  Future<void> setCloudSync(bool enabled) =>
      update(state.copyWith(cloudSyncEnabled: enabled));

  Future<void> setRegion(CloudRegion region) =>
      update(state.copyWith(region: region));

  Future<void> setAutoSyncTime(bool enabled) =>
      update(state.copyWith(autoSyncTimeOnConnect: enabled));

  Future<void> setAutoSyncHistory(bool enabled) =>
      update(state.copyWith(autoSyncHistoryOnConnect: enabled));

  Future<void> setHrAutoMeasure(bool enabled) =>
      update(state.copyWith(hrAutoMeasureEnabled: enabled));

  Future<void> setHrInterval(int minutes) =>
      update(state.copyWith(hrIntervalMinutes: minutes));

  Future<void> setHrLowAlarm(int bpm) =>
      update(state.copyWith(hrLowAlarm: bpm));

  Future<void> setHrHighAlarm(int bpm) =>
      update(state.copyWith(hrHighAlarm: bpm));
}

// --- BLE transport + watch manager ------------------------------------------

final bleTransportProvider = Provider<BleTransport>((ref) {
  final t = BleTransport();
  ref.onDispose(t.dispose);
  return t;
});

final watchManagerProvider = ChangeNotifierProvider<WatchManager>((ref) {
  // Built once against the stable transport. Crucially, do NOT `watch`
  // settingsProvider here — it rebuilds when prefs hydrate asynchronously,
  // which would spawn a second WatchManager and a duplicate handshake.
  final transport = ref.watch(bleTransportProvider);
  final mgr = WatchManager(transport);
  mgr.autoSyncTime = ref.read(settingsProvider).autoSyncTimeOnConnect;
  ref.listen(settingsProvider, (_, next) {
    mgr.autoSyncTime = next.autoSyncTimeOnConnect;
  });
  return mgr;
});

final linkStateProvider = StreamProvider<LinkState>((ref) {
  final t = ref.watch(bleTransportProvider);
  final controller = StreamController<LinkState>();
  controller.add(t.state.value);
  void listener() => controller.add(t.state.value);
  t.state.addListener(listener);
  ref.onDispose(() {
    t.state.removeListener(listener);
    unawaited(controller.close());
  });
  return controller.stream;
});

final connectedDeviceProvider = Provider<BluetoothDevice?>((ref) {
  ref.watch(linkStateProvider);
  return ref.watch(bleTransportProvider).device;
});

// --- Scan --------------------------------------------------------------------

final adapterStateProvider = StreamProvider<BluetoothAdapterState>(
  (ref) => FlutterBluePlus.adapterState,
);

final scanResultsProvider = StreamProvider<List<ScanResult>>(
  (ref) => FlutterBluePlus.scanResults,
);

final isScanningProvider = StreamProvider<bool>(
  (ref) => FlutterBluePlus.isScanning,
);

// --- Cloud (constructed only when the user enabled cloud sync) ---------------

/// Returns a [CloudApi] **only** when cloud sync is enabled; otherwise null.
/// Every cloud call site must null-check this, keeping the app offline-first.
final cloudApiProvider = Provider<CloudApi?>((ref) {
  final settings = ref.watch(settingsProvider);
  if (!settings.cloudSyncEnabled) return null;
  return CloudApi(settings: settings);
});

final firmwareServiceProvider = Provider<FirmwareService>(
  (ref) => FirmwareService(),
);

// --- History (local-first store + sync) -------------------------------------

/// Persistent on-device store for HR/sleep/steps per day. Opens the
/// `<app docs>/history/` directory on first access and exposes async
/// readers/writers; the UI uses [historySyncProvider] for reactive
/// access to the in-memory mirror.
final historyStoreProvider = FutureProvider<HistoryStore>(
  (ref) => HistoryStore.open(),
);

/// Sidecar store for the raw 13-byte BP records whose per-byte
/// layout is on PROTOCOL.md §8.5 as "needs live capture". The BP
/// debug screen reads this; the regular app surface does not.
final bpRawStoreProvider = FutureProvider<BpRawStore>(
  (ref) => BpRawStore.open(),
);

/// Singleton [HistorySync] wired against the [BleTransport] + a
/// persistent [HistoryStore]. Built once and reused across all screens
/// — `HistorySync` is a `ChangeNotifier` so any `Consumer*` watching it
/// rebuilds automatically when samples land.
///
/// The store future resolves asynchronously (path_provider +
/// SharedPreferences). We construct the sync without a store initially
/// and rebind it via [HistorySync.bindStore] once the FutureProvider
/// resolves — the sync then hydrates from disk in the background and
/// the next `syncAll` will persist.
final historySyncProvider = ChangeNotifierProvider<HistorySync>((ref) {
  final transport = ref.watch(bleTransportProvider);
  // Read the stable manager instance without subscribing to its
  // ChangeNotifier updates. WatchManager notifies on every live device
  // update (battery, steps, HR, link state); if HistorySync watched it,
  // Riverpod would recreate the sync object and drop freshly-fetched history.
  final manager = ref.read(watchManagerProvider);
  final sync = HistorySync(
    transport,
    (_) {}, // totals are surfaced on the dashboard via WatchManager
    dispatcher: manager.hub.channelA,
    bParser: manager.hub.channelB,
  );
  ref.listen(historyStoreProvider, (_, next) {
    next.whenData((store) {
      sync.bindStore(store);
    });
  }, fireImmediately: true);
  ref.listen(bpRawStoreProvider, (_, next) {
    next.whenData((raw) {
      sync.bindRawStore(raw);
    });
  }, fireImmediately: true);

  // Auto-sync after the watch-level handshake completes, not merely
  // when GATT discovery marks the BLE link ready. The handshake may
  // still be syncing time and probing capabilities at that point.
  var managerWasInitialized = false;
  void maybeAutoSync() {
    final becameInitialized = manager.initialized && !managerWasInitialized;
    managerWasInitialized = manager.initialized;
    if (!becameInitialized) return;
    final autoSync = ref.read(settingsProvider).autoSyncHistoryOnConnect;
    if (!autoSync) return;
    // `unawaited` — the future itself is observed by the UI via
    // `sync.syncing`; if the user manually taps Sync, the existing
    // in-flight call short-circuits via the `_syncing` guard.
    unawaited(sync.syncAll());
  }

  manager.addListener(maybeAutoSync);
  ref.onDispose(() {
    manager.removeListener(maybeAutoSync);
  });
  maybeAutoSync();
  return sync;
});
