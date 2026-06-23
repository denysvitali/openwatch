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
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
              child: _ErrorCard(message: _error!),
            ),
          Expanded(
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 860),
                child: ListView(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 96),
                  children: [
                    _ScanStatusCard(
                      adapter: adapter,
                      scanning: scanning,
                      reconnecting: _reconnecting,
                      reconnectName: _reconnectName,
                      resultCount: results.length,
                      onScan: _connecting ? null : _startScan,
                      onStop: scanning ? FlutterBluePlus.stopScan : null,
                    ),
                    const SizedBox(height: 14),
                    if (results.isEmpty)
                      _EmptyScanState(scanning: scanning)
                    else ...[
                      _ResultsHeader(count: results.length),
                      const SizedBox(height: 8),
                      for (final r in results) ...[
                        _ScanResultCard(
                          result: r,
                          connecting: _connecting,
                          onConnect: () => _connect(r.device),
                        ),
                        const SizedBox(height: 10),
                      ],
                    ],
                  ],
                ),
              ),
            ),
          ),
          if (_connecting) const LinearProgressIndicator(),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _connecting
            ? null
            : scanning
            ? FlutterBluePlus.stopScan
            : _startScan,
        icon: Icon(scanning ? Icons.stop : Icons.search),
        label: Text(scanning ? 'Stop' : 'Scan'),
      ),
    );
  }
}

class _ScanStatusCard extends StatelessWidget {
  const _ScanStatusCard({
    required this.adapter,
    required this.scanning,
    required this.reconnecting,
    required this.reconnectName,
    required this.resultCount,
    required this.onScan,
    required this.onStop,
  });

  final BluetoothAdapterState? adapter;
  final bool scanning;
  final bool reconnecting;
  final String? reconnectName;
  final int resultCount;
  final VoidCallback? onScan;
  final VoidCallback? onStop;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final bluetoothReady =
        adapter == null || adapter == BluetoothAdapterState.on;
    final statusText = reconnecting
        ? 'Trying ${reconnectName ?? "saved watch"}'
        : bluetoothReady
        ? scanning
              ? 'Scanning nearby watches'
              : 'Ready to scan'
        : 'Bluetooth is off';
    final detailText = reconnecting
        ? 'OpenWatch will use the saved device first, then you can scan manually.'
        : bluetoothReady
        ? resultCount == 0
              ? 'Keep the watch nearby and awake for the best BLE signal.'
              : '$resultCount compatible ${resultCount == 1 ? "watch" : "watches"} found.'
        : 'Turn on Bluetooth before scanning.';

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: 56,
              height: 56,
              decoration: BoxDecoration(
                color: theme.colorScheme.primary.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Icon(
                bluetoothReady
                    ? Icons.bluetooth_searching
                    : Icons.bluetooth_disabled,
                color: theme.colorScheme.primary,
                size: 30,
              ),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    statusText,
                    style: theme.textTheme.titleLarge?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    detailText,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 14),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      _StatusChip(
                        icon: bluetoothReady
                            ? Icons.bluetooth_connected
                            : Icons.bluetooth_disabled,
                        label: bluetoothReady
                            ? 'Bluetooth ready'
                            : 'Bluetooth off',
                      ),
                      _StatusChip(
                        icon: scanning ? Icons.radar : Icons.watch_outlined,
                        label: scanning ? 'Scanning' : 'Idle',
                      ),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(width: 12),
            FilledButton.icon(
              onPressed: scanning ? onStop : onScan,
              icon: Icon(scanning ? Icons.stop : Icons.search),
              label: Text(scanning ? 'Stop' : 'Scan'),
            ),
          ],
        ),
      ),
    );
  }
}

class _ResultsHeader extends StatelessWidget {
  const _ResultsHeader({required this.count});

  final int count;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      children: [
        Expanded(
          child: Text(
            'Nearby watches',
            style: theme.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
        Text(
          '$count found',
          style: theme.textTheme.labelLarge?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ],
    );
  }
}

class _ScanResultCard extends StatelessWidget {
  const _ScanResultCard({
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

    return Card(
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: connecting ? null : onConnect,
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Row(
            children: [
              Container(
                width: 46,
                height: 46,
                decoration: BoxDecoration(
                  color: theme.colorScheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Icon(
                  Icons.watch_rounded,
                  color: theme.colorScheme.primary,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      name,
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      result.device.remoteId.str,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              _SignalBadge(rssi: result.rssi),
              const SizedBox(width: 10),
              FilledButton(
                onPressed: connecting ? null : onConnect,
                child: const Text('Connect'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SignalBadge extends StatelessWidget {
  const _SignalBadge({required this.rssi});

  final int rssi;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final strong = rssi >= -65;
    final fair = rssi >= -82;
    final color = strong
        ? theme.colorScheme.secondary
        : fair
        ? theme.colorScheme.tertiary
        : theme.colorScheme.error;
    final label = strong
        ? 'Strong'
        : fair
        ? 'Fair'
        : 'Weak';

    return Tooltip(
      message: '$rssi dBm',
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 7),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.network_cell_rounded, size: 16, color: color),
            const SizedBox(width: 5),
            Text(
              label,
              style: theme.textTheme.labelMedium?.copyWith(color: color),
            ),
          ],
        ),
      ),
    );
  }
}

class _EmptyScanState extends StatelessWidget {
  const _EmptyScanState({required this.scanning});

  final bool scanning;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 42),
      child: Column(
        children: [
          Container(
            width: 74,
            height: 74,
            decoration: BoxDecoration(
              color: theme.colorScheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(8),
            ),
            child: scanning
                ? const Padding(
                    padding: EdgeInsets.all(24),
                    child: CircularProgressIndicator(strokeWidth: 2.4),
                  )
                : Icon(
                    Icons.watch_outlined,
                    color: theme.colorScheme.onSurfaceVariant,
                    size: 34,
                  ),
          ),
          const SizedBox(height: 16),
          Text(
            scanning ? 'Searching for watches' : 'No watches found yet',
            style: theme.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            scanning
                ? 'Results appear here as compatible devices advertise.'
                : 'Tap Scan and keep the watch close to this phone.',
            textAlign: TextAlign.center,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}

class _StatusChip extends StatelessWidget {
  const _StatusChip({required this.icon, required this.label});

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Chip(
      avatar: Icon(icon, size: 16),
      label: Text(label),
      visualDensity: VisualDensity.compact,
      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
    );
  }
}

class _ErrorCard extends StatelessWidget {
  const _ErrorCard({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      color: theme.colorScheme.errorContainer,
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Row(
          children: [
            Icon(
              Icons.error_outline,
              color: theme.colorScheme.onErrorContainer,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                message,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onErrorContainer,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
