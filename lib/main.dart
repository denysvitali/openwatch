import 'dart:async';
import 'dart:convert' show base64;
import 'dart:io' show Platform, SecurityContext;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_user_certificates_android/flutter_user_certificates_android.dart';

import 'core/routing/app_router.dart';
import 'core/services/opentelemetry_service.dart';

/// Converts a DER-encoded certificate to PEM format.
Uint8List _derToPem(Uint8List der) {
  final b64 = base64.encode(der);
  final buf = StringBuffer()..writeln('-----BEGIN CERTIFICATE-----');
  for (var i = 0; i < b64.length; i += 64) {
    buf.writeln(b64.substring(i, i + 64 < b64.length ? i + 64 : b64.length));
  }
  buf.write('-----END CERTIFICATE-----');
  return Uint8List.fromList(buf.toString().codeUnits);
}

/// Loads the OS-level user-installed certificate store into
/// [SecurityContext.defaultContext]. Required for the OTLP/HTTPS
/// handshake to trust the same CA the user trusts (e.g. corporate MITM
/// proxy, custom dev cert). Mirrors happy_flutter.
Future<void> _loadAndroidUserCertificates() async {
  if (kIsWeb) return;
  if (!Platform.isAndroid) return;

  final certs = await FlutterUserCertificatesAndroid().getUserCertificates();
  for (final derBytes in (certs ?? {}).values) {
    final pem = _derToPem(derBytes);
    SecurityContext.defaultContext.setTrustedCertificatesBytes(pem);
  }
}

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  FlutterBluePlus.setLogLevel(LogLevel.warning);

  // Wire the Android user-cert store load into the OTEL service before
  // kicking off initialization. The service awaits this future inside
  // _initialize() so the SecurityContext is populated before the OTLP
  // handshake runs.
  final userCertsFuture = _loadAndroidUserCertificates();
  OpenTelemetryService().setTrustedCertificatesFuture(userCertsFuture);

  // OpenTelemetry init runs in parallel with runApp so the first frame
  // isn't blocked on OTLP handshake. Sync + BLE operations tolerate the
  // tracer not being ready yet — startTrace returns null until then.
  unawaited(OpenTelemetryService().initialize());

  runApp(const ProviderScope(child: OpenWatchApp()));
}

class OpenWatchApp extends ConsumerWidget {
  const OpenWatchApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final router = ref.watch(appRouterProvider);
    return MaterialApp.router(
      title: 'OpenWatch',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF1565C0)),
        useMaterial3: true,
      ),
      darkTheme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF1565C0),
          brightness: Brightness.dark,
        ),
        useMaterial3: true,
      ),
      routerConfig: router,
    );
  }
}
