import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';

import 'app_log.dart';
import 'settings_service.dart';

/// Minimal client for the optional QC Wireless cloud backend.
///
/// **Only constructed when the user has enabled cloud sync.** It is deliberately
/// narrow: firmware lookup and the few endpoints OpenWatch actually needs. The
/// auth/signature scheme mirrors the original app (`PROTOCOL.md` §6.2).
class CloudApi {
  CloudApi({required AppSettings settings})
    : _settings = settings,
      _dio = Dio(_baseOptions(settings)) {
    if (settings.authToken == null) {
      AppLog.instance.warn(
        'cloud',
        'CloudApi constructed without a user token; firmware lookup will use '
            'the app token.',
      );
    }
    _dio.interceptors.add(_SignatureInterceptor());
  }

  final AppSettings _settings;
  final Dio _dio;
  String? _appToken;

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
    await _ensureToken();
    final body = <String, dynamic>{
      'deviceName': model,
      'version': currentVersion,
      // The vendor API validates this as 1..2. The Android app uses this
      // endpoint and token key, so keep the Android value for firmware lookup.
      'os': 1,
    };
    if (mac != null) body['mac'] = mac;
    final Response<dynamic> resp;
    final path = _settings.region == CloudRegion.china
        ? 'app-update/last-ota/china'
        : 'app-update/last-ota';
    AppLog.instance.info(
      'cloud',
      'POST ${_dio.options.baseUrl}$path body=$body',
    );
    try {
      resp = await _dio.post<dynamic>(path, data: body);
    } on DioException catch (e) {
      AppLog.instance.error(
        'cloud',
        'last-ota failed type=${e.type.name} status=${e.response?.statusCode} '
            'msg=${e.message} err=${e.error?.runtimeType}:${e.error} '
            'body=${e.response?.data}',
      );
      throw CloudException(_describe(e));
    }
    AppLog.instance.info('cloud', 'last-ota ${resp.statusCode}: ${resp.data}');
    final root = resp.data;
    if (root is Map) {
      final retCode = root['retCode'];
      if (retCode != null && retCode != 0) {
        throw CloudException(
          '${root['message'] ?? 'Firmware lookup failed'} (retCode $retCode)',
        );
      }
    }
    final data = root is Map ? root['data'] : null;
    if (data is! Map) {
      return null;
    }
    final map = data.cast<dynamic, dynamic>();
    final url =
        map['downloadUrl'] ??
        map['url'] ??
        map['fileUrl'] ??
        map['firmwareUrl'];
    if (url is! String || url.isEmpty) return null;
    return FirmwareInfo(
      version: '${map['version'] ?? map['versionName'] ?? '?'}',
      url: url,
      sizeBytes: (map['size'] as num?)?.toInt() ?? 0,
      notes: map['content']?.toString() ?? map['describe']?.toString() ?? '',
    );
  }

  Future<void> _ensureToken() async {
    if (_settings.authToken != null || _appToken != null) return;
    AppLog.instance.info('cloud', 'GET ${_dio.options.baseUrl}token/getToken');
    final Response<dynamic> resp;
    try {
      resp = await _dio.get<dynamic>(
        'token/getToken',
        queryParameters: const {'key': 'qcwx_android'},
      );
    } on DioException catch (e) {
      throw CloudException(_describe(e));
    }
    final root = resp.data;
    if (root is! Map || root['retCode'] != 0 || root['data'] is! String) {
      final message = root is Map ? root['message'] : null;
      throw CloudException('${message ?? 'Could not get cloud token'}');
    }
    _appToken = root['data'] as String;
    _dio.options.headers['token'] = _appToken;
  }

  /// Streams a firmware binary, reporting progress. Used by [FirmwareService].
  Future<List<int>> download(
    String url, {
    void Function(int received, int total)? onProgress,
  }) async {
    try {
      final resp = await _dio.get<List<int>>(
        url,
        options: Options(responseType: ResponseType.bytes),
        onReceiveProgress: onProgress,
      );
      return resp.data ?? const [];
    } on DioException catch (e) {
      throw CloudException(_describe(e));
    }
  }

  static String _describe(DioException e) => switch (e.type) {
    DioExceptionType.connectionError || DioExceptionType.connectionTimeout =>
      'Cannot reach the server. Check your '
          'internet connection (the device may be offline or the host is blocked).',
    DioExceptionType.receiveTimeout ||
    DioExceptionType.sendTimeout => 'The server took too long to respond.',
    DioExceptionType.badResponse =>
      'Server returned ${e.response?.statusCode ?? 'an error'}.',
    _ => 'Network error: ${e.message ?? e.type.name}',
  };
}

/// A user-facing cloud error with a clean message.
class CloudException implements Exception {
  const CloudException(this.message);
  final String message;
  @override
  String toString() => message;
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
    final payload = options.method.toUpperCase() == 'GET'
        ? _canonicalQuery(options.queryParameters)
        : options.data == null
        ? ''
        : jsonEncode(options.data);
    final bodyHash = md5.convert(utf8.encode(payload)).toString();
    final sig = Hmac(
      sha256,
      utf8.encode(_secret),
    ).convert(utf8.encode('$ts$bodyHash')).toString();
    options.headers['X-Timestamp'] = ts;
    options.headers['X-Signature'] = sig;
    handler.next(options);
  }

  static String _canonicalQuery(Map<String, dynamic> query) {
    final parts = <String>[];
    for (final key in query.keys.map((k) => k.toString()).toList()..sort()) {
      final value = query[key];
      if (value is Iterable) {
        for (final item in value) {
          parts.add('$key=$item');
        }
      } else if (value != null) {
        parts.add('$key=$value');
      }
    }
    return parts.join('&');
  }
}
