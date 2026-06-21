import 'dart:io';

import 'package:path_provider/path_provider.dart';

import 'cloud_api.dart';
import 'opentelemetry_service.dart';

/// A firmware image stored on the local filesystem.
class LocalFirmware {
  const LocalFirmware({
    required this.name,
    required this.path,
    required this.sizeBytes,
  });
  final String name;
  final String path;
  final int sizeBytes;
}

/// Manages firmware images on the device filesystem.
///
/// Fetching the latest firmware requires the cloud (an explicit user action,
/// never automatic). Once downloaded, images live under the app documents
/// directory and can be flashed entirely **offline** via the Channel-B DFU flow.
class FirmwareService {
  FirmwareService();

  Future<Directory> _dir() async {
    final base = await getApplicationDocumentsDirectory();
    final dir = Directory('${base.path}/firmware');
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  /// Lists firmware images already stored locally (usable offline).
  Future<List<LocalFirmware>> listLocal() async {
    final dir = await _dir();
    final files = await dir
        .list()
        .where((e) => e is File && e.path.toLowerCase().endsWith('.bin'))
        .cast<File>()
        .toList();
    return [
      for (final f in files)
        LocalFirmware(
          name: f.uri.pathSegments.last,
          path: f.path,
          sizeBytes: await f.length(),
        ),
    ]..sort((a, b) => b.name.compareTo(a.name));
  }

  /// Reads a stored firmware image into memory for flashing.
  Future<List<int>> readBytes(LocalFirmware fw) => File(fw.path).readAsBytes();

  Future<void> delete(LocalFirmware fw) async {
    final f = File(fw.path);
    if (await f.exists()) await f.delete();
  }

  /// Explicit on-demand fetch: queries the cloud for the latest firmware and,
  /// if newer, downloads it to the filesystem. [cloud] must be a constructed
  /// (cloud-enabled) client. Returns the stored file, or null if up to date.
  Future<LocalFirmware?> fetchLatest({
    required CloudApi cloud,
    required String model,
    required String currentVersion,
    String? mac,
    void Function(int received, int total)? onProgress,
  }) async {
    // Spans the full cloud-lookup + download + write-as-bytes pass
    // for one on-demand firmware pull. The two CloudApi calls will
    // be visible as child spans (cloud.firmware.lookup / .download).
    final span = OpenTelemetryService().startChildSpan(
      'firmware.fetch_latest',
      attributes: {
        'firmware.model': model,
        'firmware.current_version': currentVersion,
      },
    );
    try {
      final info = await cloud.getLatestFirmware(
        model: model,
        currentVersion: currentVersion,
        mac: mac,
      );
      if (info == null) {
        span?.setAttribute('firmware.up_to_date', true);
        return null;
      }
      span?.setAttribute('firmware.latest_version', info.version);

      final bytes = await cloud.download(info.url, onProgress: onProgress);
      if (bytes.isEmpty) {
        throw const FirmwareException('Downloaded firmware was empty');
      }

      final dir = await _dir();
      final safeModel = model.replaceAll(RegExp(r'[^A-Za-z0-9_.-]'), '_');
      final safeVer = info.version.replaceAll(RegExp(r'[^A-Za-z0-9_.-]'), '_');
      final file = File('${dir.path}/${safeModel}_$safeVer.bin');
      await file.writeAsBytes(bytes, flush: true);

      return LocalFirmware(
        name: file.uri.pathSegments.last,
        path: file.path,
        sizeBytes: bytes.length,
      );
    } catch (e, st) {
      span?.recordError(e, st);
      rethrow;
    } finally {
      span?.end();
    }
  }
}

class FirmwareException implements Exception {
  const FirmwareException(this.message);
  final String message;
  @override
  String toString() => 'FirmwareException: $message';
}
