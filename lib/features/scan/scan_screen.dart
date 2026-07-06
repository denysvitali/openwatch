import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:permission_handler/permission_handler.dart';

import '../../core/ble/ble_constants.dart';
import '../../core/providers/app_providers.dart';
import '../../core/services/app_log.dart';
import '../widgets/health_widgets.dart';

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
    final theme = Theme.of(context);
    final adapter = ref.watch(adapterStateProvider).value;
    final scanning = ref.watch(isScanningProvider).value ?? false;
    final results =
        (ref.watch(scanResultsProvider).value ?? <ScanResult>[])
            .where(_looksLikeWatch)
            .toList()
          ..sort((a, b) => b.rssi.compareTo(a.rssi));
    final bluetoothReady =
        adapter == null || adapter == BluetoothAdapterState.on;

    final statusTitle = _reconnecting
        ? 'Reconnecting'
        : bluetoothReady
        ? (scanning ? 'Scanning' : 'Ready to scan')
        : 'Bluetooth off';
    final statusCaption = _reconnecting
        ? 'Using your saved watch, then you can scan manually.'
        : bluetoothReady
        ? (results.isEmpty
              ? 'Keep the watch nearby and awake for the best BLE signal.'
              : '${results.length} compatible ${results.length == 1 ? "watch" : "watches"} found.')
        : 'Turn on Bluetooth before scanning.';

    return Scaffold(
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
          Expanded(
            child: SafeArea(
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 520),
                  child: ListView(
                    padding: const EdgeInsets.fromLTRB(20, 24, 20, 96),
                    children: [
                      if (_error != null) ...[
                        HealthCard(
                          icon: Icons.error_outline,
                          metricColor: theme.colorScheme.error,
                          title: 'Something went wrong',
                          caption: _error!,
                        ),
                        const SizedBox(height: 20),
                      ],
                      Center(
                        child: HealthCard(
                          icon: bluetoothReady
                              ? Icons.bluetooth_searching
                              : Icons.bluetooth_disabled,
                          title: 'OpenWatch',
                          value: statusTitle,
                          caption: statusCaption,
                          trailing: scanning
                              ? const SizedBox(
                                  width: 24,
                                  height: 24,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2.5,
                                  ),
                                )
                              : null,
                        ),
                      ),
                      const SizedBox(height: 24),
                      PrimaryHealthButton(
                        label: scanning ? 'Stop scanning' : 'Scan for watches',
                        icon: scanning ? Icons.stop : Icons.search,
                        onPressed: _connecting
                            ? null
                            : scanning
                            ? FlutterBluePlus.stopScan
                            : _startScan,
                      ),
                      if (results.isEmpty) ...[
                        const SizedBox(height: 32),
                        _EmptyScanState(scanning: scanning),
                      ] else ...[
                        const HealthSectionHeader(title: 'Nearby watches'),
                        Card(
                          margin: EdgeInsets.zero,
                          child: Column(
                            children: [
                              for (final r in results)
                                _DeviceTile(
                                  result: r,
                                  connecting: _connecting,
                                  onConnect: () => _connect(r.device),
                                ),
                            ],
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ),
          ),
          if (_connecting) const LinearProgressIndicator(),
        ],
      ),
    );
  }
}

class _DeviceTile extends StatelessWidget {
  const _DeviceTile({
    required this.result,
    required this.connecting,
    required this.onConnect,
  });

  final ScanResult result;
  final bool connecting;
  final VoidCallback onConnect;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final name = result.device.platformName.isNotEmpty
        ? result.device.platformName
        : (result.advertisementData.advName.isNotEmpty
              ? result.advertisementData.advName
              : 'Unknown watch');
    final strong = result.rssi >= -65;
    final fair = result.rssi >= -82;
    final signalColor = strong
        ? theme.colorScheme.secondary
        : fair
        ? theme.colorScheme.tertiary
        : theme.colorScheme.error;
    final signalLabel = strong
        ? 'Strong'
        : fair
        ? 'Fair'
        : 'Weak';
    final signalIcon = strong
        ? Icons.signal_cellular_alt
        : fair
        ? Icons.signal_cellular_alt_2_bar
        : Icons.signal_cellular_alt_1_bar;

    return HealthListTile(
      leadingIcon: Icons.watch_rounded,
      leadingColor: theme.colorScheme.primary,
      title: name,
      subtitle: result.device.remoteId.str,
      trailing: StatusPill(
        icon: signalIcon,
        label: signalLabel,
        color: signalColor,
      ),
      onTap: connecting ? null : onConnect,
      showDivider: true,
    );
  }
}

class _EmptyScanState extends StatelessWidget {
  const _EmptyScanState({required this.scanning});

  final bool scanning;

  @override
  Widget build(BuildContext context) {
    return HealthCard(
      icon: scanning ? Icons.radar : Icons.watch_outlined,
      title: scanning ? 'Searching for watches' : 'No watches found yet',
      caption: scanning
          ? 'Results appear here as compatible devices advertise.'
          : 'Tap Scan and keep the watch close to this phone.',
      trailing: scanning
          ? const SizedBox(
              width: 22,
              height: 22,
              child: CircularProgressIndicator(strokeWidth: 2.5),
            )
          : null,
    );
  }
}
