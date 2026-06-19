import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:permission_handler/permission_handler.dart';

import '../../core/ble/ble_constants.dart';
import '../../core/providers/app_providers.dart';
import '../../core/services/app_log.dart';

/// Scans for nearby Oudmon watches and connects to the chosen one.
class ScanScreen extends ConsumerStatefulWidget {
  const ScanScreen({super.key});

  @override
  ConsumerState<ScanScreen> createState() => _ScanScreenState();
}

class _ScanScreenState extends ConsumerState<ScanScreen> {
  String? _error;
  bool _connecting = false;
  bool _reconnecting = false;
  String? _reconnectName;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _maybeAutoReconnect());
  }

  /// Tries to silently reconnect to the last paired watch on launch, so the
  /// user doesn't have to scan & pair every time.
  Future<void> _maybeAutoReconnect() async {
    final svc = await ref.read(settingsServiceProvider.future);
    final id = svc.lastDeviceId;
    if (id == null || !mounted) return;
    if (!await _ensurePermissions()) return;
    if (!mounted) return;
    setState(() {
      _reconnecting = true;
      _reconnectName = svc.lastDeviceName ?? id;
    });
    AppLog.instance.info('ble', 'Auto-reconnecting to saved device $id');
    try {
      final device = BluetoothDevice.fromId(id);
      await ref.read(bleTransportProvider).connect(device);
      await _rememberDevice(device);
      if (mounted) context.go('/dashboard');
    } catch (e) {
      AppLog.instance.warn('ble', 'Auto-reconnect failed: $e');
      if (mounted) {
        setState(
          () => _error = 'Could not reconnect automatically. Scan to retry.',
        );
      }
    } finally {
      if (mounted) setState(() => _reconnecting = false);
    }
  }

  Future<void> _rememberDevice(BluetoothDevice device) async {
    final svc = await ref.read(settingsServiceProvider.future);
    await svc.saveLastDevice(
      device.remoteId.str,
      device.platformName.isNotEmpty ? device.platformName : 'Watch',
    );
  }

  Future<void> _startScan() async {
    setState(() => _error = null);
    final granted = await _ensurePermissions();
    if (!granted) {
      setState(
        () => _error =
            'Bluetooth permission is required to scan. Grant "Nearby devices" '
            'in system settings, then try again.',
      );
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: const Text('Bluetooth permission denied'),
            action: SnackBarAction(
              label: 'Settings',
              onPressed: openAppSettings,
            ),
          ),
        );
      }
      return;
    }
    try {
      await FlutterBluePlus.startScan(timeout: const Duration(seconds: 12));
    } catch (e) {
      setState(() => _error = '$e');
    }
  }

  Future<bool> _ensurePermissions() async {
    // Android 12+ (API 31+): the "Nearby devices" prompt covers BLUETOOTH_SCAN
    // and BLUETOOTH_CONNECT. We declare BLUETOOTH_SCAN with `neverForLocation`,
    // so location is NOT required (and ACCESS_FINE_LOCATION isn't even declared
    // above SDK 30, so requesting it just returns denied).
    final scan = await Permission.bluetoothScan.request();
    final connect = await Permission.bluetoothConnect.request();
    final bleGranted =
        (scan.isGranted || scan.isLimited) &&
        (connect.isGranted || connect.isLimited);
    if (bleGranted) return true;

    // Pre-Android-12: the Bluetooth permissions are normal-level (auto-granted)
    // and a location grant is what actually gates BLE scanning.
    final loc = await Permission.locationWhenInUse.request();
    return loc.isGranted || loc.isLimited;
  }

  Future<void> _connect(BluetoothDevice device) async {
    setState(() {
      _connecting = true;
      _error = null;
    });
    try {
      await FlutterBluePlus.stopScan();
      await ref.read(bleTransportProvider).connect(device);
      await _rememberDevice(device);
      if (mounted) context.go('/dashboard');
    } catch (e) {
      if (mounted) setState(() => _error = 'Connection failed: $e');
    } finally {
      if (mounted) setState(() => _connecting = false);
    }
  }

  bool _looksLikeWatch(ScanResult r) {
    if (r.advertisementData.serviceUuids.contains(BleUuids.serviceA)) {
      return true;
    }
    final name = r.device.platformName.isNotEmpty
        ? r.device.platformName
        : r.advertisementData.advName;
    if (name.isEmpty) return false;
    if (BleUuids.namePrefixes.isEmpty) return true;
    return BleUuids.namePrefixes.any(
      (p) => name.toLowerCase().startsWith(p.toLowerCase()),
    );
  }

  @override
  Widget build(BuildContext context) {
    final adapter = ref.watch(adapterStateProvider).value;
    final scanning = ref.watch(isScanningProvider).value ?? false;
    final results =
        (ref.watch(scanResultsProvider).value ?? <ScanResult>[])
            .where(_looksLikeWatch)
            .toList()
          ..sort((a, b) => b.rssi.compareTo(a.rssi));

    return Scaffold(
      appBar: AppBar(
        title: const Text('OpenWatch'),
        actions: [
          if (scanning)
            const Padding(
              padding: EdgeInsets.all(16),
              child: SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            ),
        ],
      ),
      body: Column(
        children: [
          if (_reconnecting)
            MaterialBanner(
              content: Text(
                'Reconnecting to ${_reconnectName ?? "your watch"}…',
              ),
              leading: const SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
              actions: [
                TextButton(
                  onPressed: () => setState(() => _reconnecting = false),
                  child: const Text('Scan instead'),
                ),
              ],
            ),
          if (adapter != null && adapter != BluetoothAdapterState.on)
            MaterialBanner(
              content: const Text(
                'Bluetooth is off. Turn it on to scan for your watch.',
              ),
              leading: const Icon(Icons.bluetooth_disabled),
              actions: [
                TextButton(
                  onPressed: () =>
                      FlutterBluePlus.turnOn().catchError((_) => false),
                  child: const Text('Enable'),
                ),
              ],
            ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.all(16),
              child: Text(
                _error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ),
          Expanded(
            child: results.isEmpty
                ? Center(
                    child: Text(
                      scanning
                          ? 'Searching for watches…'
                          : 'No watches found yet.\nTap scan to search.',
                      textAlign: TextAlign.center,
                      style: Theme.of(context).textTheme.bodyMedium,
                    ),
                  )
                : ListView.separated(
                    itemCount: results.length,
                    separatorBuilder: (_, _) => const Divider(height: 1),
                    itemBuilder: (context, i) {
                      final r = results[i];
                      final name = r.device.platformName.isNotEmpty
                          ? r.device.platformName
                          : (r.advertisementData.advName.isNotEmpty
                                ? r.advertisementData.advName
                                : '(unknown)');
                      return ListTile(
                        leading: const Icon(Icons.watch),
                        title: Text(name),
                        subtitle: Text(r.device.remoteId.str),
                        trailing: Text('${r.rssi} dBm'),
                        onTap: _connecting ? null : () => _connect(r.device),
                      );
                    },
                  ),
          ),
          if (_connecting) const LinearProgressIndicator(),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: scanning ? FlutterBluePlus.stopScan : _startScan,
        icon: Icon(scanning ? Icons.stop : Icons.search),
        label: Text(scanning ? 'Stop' : 'Scan'),
      ),
    );
  }
}
