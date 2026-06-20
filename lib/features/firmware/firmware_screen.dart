import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/ble/ble_transport.dart';
import '../../core/protocol/dfu.dart';
import '../../core/protocol/firmware_container.dart';
import '../../core/protocol/firmware_version.dart';
import '../../core/providers/app_providers.dart';
import '../../core/services/app_log.dart';
import '../../core/services/firmware_service.dart';

/// Firmware management: fetch the latest image from the cloud (explicit, opt-in)
/// and flash a locally-stored image over the air — offline-capable.
class FirmwareScreen extends ConsumerStatefulWidget {
  const FirmwareScreen({super.key});

  @override
  ConsumerState<FirmwareScreen> createState() => _FirmwareScreenState();
}

class _FirmwareScreenState extends ConsumerState<FirmwareScreen> {
  List<LocalFirmware> _local = [];
  String? _status;
  double? _progress;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _reloadLocal();
  }

  Future<void> _reloadLocal() async {
    final list = await ref.read(firmwareServiceProvider).listLocal();
    if (mounted) setState(() => _local = list);
  }

  Future<void> _fetchLatest() async {
    final cloud = ref.read(cloudApiProvider);
    if (cloud == null) {
      AppLog.instance.warn('fw', 'Fetch blocked: cloud integration disabled');
      _toast('Enable cloud integration in Settings to fetch firmware.');
      return;
    }
    final manager = ref.read(watchManagerProvider);
    final model = manager.hardwareRevision.isNotEmpty
        ? manager.hardwareRevision
        : 'QWatch';
    setState(() {
      _busy = true;
      _status = 'Checking for updates…';
      _progress = null;
    });
    AppLog.instance.info(
      'fw',
      'Fetch latest: model="$model" current="${manager.firmwareRevision}" '
          'region=${ref.read(settingsProvider).region.name}',
    );
    try {
      final fw = await ref
          .read(firmwareServiceProvider)
          .fetchLatest(
            cloud: cloud,
            model: model,
            currentVersion: manager.firmwareRevision,
            onProgress: (r, t) =>
                setState(() => _progress = t > 0 ? r / t : null),
          );
      if (fw == null) {
        AppLog.instance.info('fw', 'Server reports no newer firmware');
        _toast('Already up to date.');
      } else {
        AppLog.instance.info(
          'fw',
          'Downloaded ${fw.name} (${fw.sizeBytes} bytes)',
        );
        _toast('Downloaded ${fw.name}');
      }
      await _reloadLocal();
    } catch (e) {
      AppLog.instance.error('fw', 'Fetch failed: $e');
      _toast('Fetch failed: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _flash(LocalFirmware fw) async {
    final ready = ref.read(linkStateProvider).value == LinkState.ready;
    if (!ready) {
      _toast('Connect to the watch first.');
      return;
    }
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Flash firmware?'),
        content: Text(
          'Install ${fw.name}? Keep the watch close and charged. '
          'Interrupting an OTA can brick the device.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Flash'),
          ),
        ],
      ),
    );
    if (confirm != true) return;

    setState(() {
      _busy = true;
      _status = 'Preparing…';
      _progress = 0;
    });
    AppLog.instance.info(
      'fw',
      'OTA flash start: ${fw.name} (${fw.sizeBytes} B)',
    );
    try {
      final bytes = Uint8List.fromList(
        await ref.read(firmwareServiceProvider).readBytes(fw),
      );

      // Verify the container header before flashing. The DfuFlasher will
      // re-check size/crc, but a corrupted or wrong-target image can brick
      // the watch — surface failures early with a typed report.
      final container = FirmwareContainer.parse(bytes);
      if (container == null) {
        throw const FormatException(
          'Not a valid H59MA firmware image (magic mismatch or too small).',
        );
      }
      final report = container.verify(
        expected: const FirmwareExpectations(
          versionPrefix: 'H59MA_',
          hwIdPrefix: 'H59MA_',
        ),
      );
      AppLog.instance.info(
        'fw',
        'image: version=${container.header.version} '
            'hw=${container.header.hwId} '
            'digest=${container.header.imageDigestHex.substring(0, 16)}… '
            '${report.summary()}',
      );
      if (!report.isValid) {
        final failed = report.failures
            .map((c) => '${c.name}: ${c.detail}')
            .join('; ');
        throw FormatException('Image rejected: $failed');
      }

      final flasher = DfuFlasher(ref.read(bleTransportProvider));
      await for (final p in flasher.flash(bytes)) {
        if (!mounted) return;
        AppLog.instance.debug(
          'fw',
          'OTA ${p.phase} ${(p.percent * 100).toStringAsFixed(0)}%',
        );
        setState(() {
          _status = p.phase;
          _progress = p.percent;
        });
      }
      AppLog.instance.info('fw', 'OTA flash complete');
      _toast('Firmware flashed. The watch will reboot.');
    } catch (e) {
      AppLog.instance.error('fw', 'OTA failed: $e');
      _toast('OTA failed: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _toast(String msg) {
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
    }
  }

  @override
  Widget build(BuildContext context) {
    final cloudOn = ref.watch(settingsProvider).cloudSyncEnabled;
    final manager = ref.watch(watchManagerProvider);
    final currentVer = FirmwareVersion.parse(manager.firmwareRevision);

    return Scaffold(
      appBar: AppBar(title: const Text('Firmware (OTA)')),
      body: Column(
        children: [
          if (_busy)
            Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                children: [
                  Text(_status ?? 'Working…'),
                  const SizedBox(height: 8),
                  LinearProgressIndicator(value: _progress),
                ],
              ),
            ),
          if (manager.firmwareRevision.isNotEmpty)
            Card(
              margin: const EdgeInsets.fromLTRB(12, 12, 12, 0),
              child: ListTile(
                leading: const Icon(Icons.info_outline),
                title: const Text('Current device firmware'),
                subtitle: Text(
                  currentVer.isStructured
                      ? '${currentVer.hardwareId} v${currentVer.version}'
                      : currentVer.raw,
                ),
              ),
            ),
          Card(
            margin: const EdgeInsets.all(12),
            child: ListTile(
              leading: Icon(cloudOn ? Icons.cloud_download : Icons.cloud_off),
              title: const Text('Fetch latest firmware'),
              subtitle: Text(
                cloudOn
                    ? 'Download newest image to this device'
                    : 'Requires cloud integration (Settings)',
              ),
              trailing: FilledButton(
                onPressed: _busy || !cloudOn ? null : _fetchLatest,
                child: const Text('Fetch'),
              ),
            ),
          ),
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 8, 16, 4),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text('Stored images (offline)'),
            ),
          ),
          Expanded(
            child: _local.isEmpty
                ? const Center(child: Text('No firmware downloaded yet.'))
                : ListView.builder(
                    itemCount: _local.length,
                    itemBuilder: (context, i) {
                      final fw = _local[i];
                      final ver = FirmwareVersion.parse(fw.name);
                      final sizeKb = (fw.sizeBytes / 1024).toStringAsFixed(0);
                      return ListTile(
                        leading: const Icon(Icons.memory),
                        title: Text(
                          ver.isStructured
                              ? '${ver.hardwareId} v${ver.version}'
                              : fw.name,
                        ),
                        subtitle: Text(
                          ver.isStructured
                              ? '${fw.name}  •  $sizeKb KB'
                              : '$sizeKb KB',
                        ),
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            IconButton(
                              icon: const Icon(Icons.delete_outline),
                              onPressed: _busy
                                  ? null
                                  : () async {
                                      await ref
                                          .read(firmwareServiceProvider)
                                          .delete(fw);
                                      await _reloadLocal();
                                    },
                            ),
                            FilledButton.tonal(
                              onPressed: _busy ? null : () => _flash(fw),
                              child: const Text('Flash'),
                            ),
                          ],
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}
