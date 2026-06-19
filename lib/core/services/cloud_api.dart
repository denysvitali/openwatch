import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';

import 'settings_service.dart';

/// Minimal client for the optional QC Wireless cloud backend.
///
/// **Only constructed when the user has enabled cloud sync.** It is deliberately
/// narrow: firmware lookup and the few endpoints OpenWatch actually needs. The
/// auth/signature scheme mirrors the original app (`PROTOCOL.md` §6.2).
class CloudApi {
  CloudApi({required AppSettings settings})
    : _dio = Dio(_baseOptions(settings)) {
    _dio.interceptors.add(_SignatureInterceptor());
  }

  final Dio _dio;

  static BaseOptions _baseOptions(AppSettings settings) {
    final headers = <String, dynamic>{'User-Agent': 'OpenWatch/0.1.0'};
    final token = settings.authToken;
    if (token != null) headers['token'] = token;
    return BaseOptions(
      baseUrl: settings.region.baseUrl,
      connectTimeout: const Duration(seconds: 15),
      receiveTimeout: const Duration(seconds: 30),
      headers: headers,
    );
  }

  /// `POST app-update/last-ota` — latest firmware metadata for a device.
  /// Returns the parsed [FirmwareInfo] or null if none is available.
  Future<FirmwareInfo?> getLatestFirmware({
    required String model,
    required String currentVersion,
    String? mac,
  }) async {
    final body = <String, dynamic>{
      'deviceName': model,
      'version': currentVersion,
    };
    if (mac != null) body['mac'] = mac;
    final resp = await _dio.post<Map<String, dynamic>>(
      'app-update/last-ota',
      data: body,
    );
    final data = resp.data?['data'] as Map<String, dynamic>?;
    if (data == null) return null;
    final url = data['downloadUrl'] ?? data['url'] ?? data['fileUrl'];
    if (url is! String || url.isEmpty) return null;
    return FirmwareInfo(
      version: '${data['version'] ?? data['versionName'] ?? '?'}',
      url: url,
      sizeBytes: (data['size'] as num?)?.toInt() ?? 0,
      notes: data['content']?.toString() ?? data['describe']?.toString() ?? '',
    );
  }

  /// Streams a firmware binary, reporting progress. Used by [FirmwareService].
  Future<List<int>> download(
    String url, {
    void Function(int received, int total)? onProgress,
  }) async {
    final resp = await _dio.get<List<int>>(
      url,
      options: Options(responseType: ResponseType.bytes),
      onReceiveProgress: onProgress,
    );
    return resp.data ?? const [];
  }
}

/// Firmware release metadata returned by the cloud.
class FirmwareInfo {
  const FirmwareInfo({
    required this.version,
    required this.url,
    required this.sizeBytes,
    required this.notes,
  });

  final String version;
  final String url;
  final int sizeBytes;
  final String notes;
}

/// Adds the `Glasses_51888` HMAC-SHA256 signature headers (§6.2).
class _SignatureInterceptor extends Interceptor {
  static const _secret = 'Glasses_51888';

  @override
  void onRequest(RequestOptions options, RequestInterceptorHandler handler) {
    final ts = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final body = options.data == null ? '' : jsonEncode(options.data);
    final bodyHash = md5.convert(utf8.encode(body)).toString();
    final sig = Hmac(
      sha256,
      utf8.encode(_secret),
    ).convert(utf8.encode('$ts$bodyHash')).toString();
    options.headers['X-Timestamp'] = ts;
    options.headers['X-Signature'] = sig;
    handler.next(options);
  }
}
