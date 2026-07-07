import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/protocol/dfu.dart';
import '../../core/protocol/firmware_container.dart';
import '../../core/protocol/firmware_version.dart';
import '../../core/providers/app_providers.dart';
import '../../core/services/app_log.dart';
import '../../core/services/firmware_service.dart';
import '../../core/ui/ui_constants.dart';
import '../widgets/health_widgets.dart';

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
    if (!ref.read(watchManagerProvider).isReady) {
      _toast('Connect to the watch first.');
      return;
    }
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(
          'Flash firmware?',
          style: AppTextStyles.titleLarge(context),
        ),
        content: Text(
          'Install ${fw.name}? Keep the watch close and charged. '
          'Interrupting an OTA can brick the device.',
          style: AppTextStyles.bodyMedium(context),
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
          validateImageChkA: true,
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
    final theme = Theme.of(context);
    final mutedColor = theme.colorScheme.onSurfaceVariant;

    return Scaffold(
      appBar: AppBar(title: const Text('Firmware (OTA)')),
      body: ListView(
        padding: const EdgeInsets.only(bottom: kCardPadding),
        children: [
          if (manager.firmwareRevision.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(
                kCardPadding,
                kSpacingSmall,
                kCardPadding,
                0,
              ),
              child: HealthCard(
                icon: Icons.watch_outlined,
                metricColor: mutedColor,
                title: 'Current device firmware',
                value: currentVer.isStructured
                    ? '${currentVer.hardwareId} v${currentVer.version}'
                    : currentVer.raw,
                caption: 'Installed on the connected watch',
                trailing: StatusPill(
                  icon: cloudOn ? Icons.update : Icons.cloud_off,
                  label: _updateLabel(cloudOn),
                  color: mutedColor,
                ),
              ),
            ),
          Padding(
            padding: const EdgeInsets.fromLTRB(
              kCardPadding,
              kSpacingSmall,
              kCardPadding,
              0,
            ),
            child: HealthCard(
              icon: cloudOn ? Icons.cloud_download : Icons.cloud_off,
              metricColor: mutedColor,
              title: 'Fetch latest firmware',
              caption: cloudOn
                  ? 'Download the newest image to this device for offline flashing.'
                  : 'Requires cloud integration in Settings.',
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const SizedBox(height: kSpacingSmall),
                  PrimaryHealthButton(
                    icon: Icons.download,
                    label: 'Fetch',
                    onPressed: _busy || !cloudOn ? null : _fetchLatest,
                  ),
                ],
              ),
            ),
          ),
          if (_busy)
            Padding(
              padding: const EdgeInsets.fromLTRB(
                kCardPadding,
                kSpacingSmall,
                kCardPadding,
                0,
              ),
              child: HealthCard(
                icon: Icons.system_update,
                metricColor: mutedColor,
                title: 'OTA progress',
                value: _progress == null
                    ? '–'
                    : (_progress! * 100).toStringAsFixed(0),
                unit: '%',
                caption: _status ?? 'Working…',
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const SizedBox(height: kSpacingSmall),
                    LinearProgressIndicator(value: _progress),
                  ],
                ),
              ),
            ),
          const HealthSectionHeader(title: 'Stored images (offline)'),
          if (_local.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: kCardPadding),
              child: HealthCard(
                icon: Icons.sd_card_alert_outlined,
                metricColor: mutedColor,
                title: 'No firmware downloaded',
                caption:
                    'Tap Fetch to download the newest image for offline flashing.',
              ),
            )
          else
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: kCardPadding),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (final fw in _local)
                    Padding(
                      padding: const EdgeInsets.only(bottom: kSpacingSmall),
                      child: _FirmwareImageCard(
                        fw: fw,
                        busy: _busy,
                        onFlash: () => _flash(fw),
                        onDelete: () async {
                          await ref.read(firmwareServiceProvider).delete(fw);
                          await _reloadLocal();
                        },
                      ),
                    ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  String _updateLabel(bool cloudOn) {
    if (!cloudOn) return 'Cloud disabled';
    if (_local.isNotEmpty) return 'Update available';
    return 'Check for updates';
  }
}

class _FirmwareImageCard extends StatelessWidget {
  const _FirmwareImageCard({
    required this.fw,
    required this.busy,
    required this.onFlash,
    required this.onDelete,
  });

  final LocalFirmware fw;
  final bool busy;
  final VoidCallback onFlash;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final ver = FirmwareVersion.parse(fw.name);
    final sizeKb = (fw.sizeBytes / 1024).toStringAsFixed(0);
    return HealthCard(
      icon: Icons.memory,
      metricColor: theme.colorScheme.onSurfaceVariant,
      title: ver.isStructured ? '${ver.hardwareId} v${ver.version}' : fw.name,
      value: sizeKb,
      unit: 'KB',
      caption: ver.isStructured ? fw.name : 'Local firmware image',
      trailing: IconButton(
        icon: const Icon(Icons.delete_outline),
        tooltip: 'Delete',
        iconSize: kIconSizeSmall,
        color: theme.colorScheme.onSurfaceVariant,
        onPressed: busy ? null : onDelete,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SizedBox(height: kSpacingSmall),
          PrimaryHealthButton(
            icon: Icons.flash_on,
            label: 'Flash',
            onPressed: busy ? null : onFlash,
          ),
        ],
      ),
    );
  }
}
