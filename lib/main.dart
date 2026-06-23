import 'dart:async';
import 'dart:convert' show base64;
import 'dart:io' show Platform, SecurityContext;
import 'dart:typed_data' show Uint8List;

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
      theme: _buildTheme(Brightness.light),
      darkTheme: _buildTheme(Brightness.dark),
      routerConfig: router,
    );
  }
}

ThemeData _buildTheme(Brightness brightness) {
  const accent = Color(0xFF007AFF);
  final isDark = brightness == Brightness.dark;
  final scheme = ColorScheme.fromSeed(seedColor: accent, brightness: brightness)
      .copyWith(
        primary: accent,
        secondary: const Color(0xFF34C759),
        tertiary: const Color(0xFFFF9500),
        surface: isDark ? const Color(0xFF1C1C1E) : Colors.white,
        surfaceContainerHighest: isDark
            ? const Color(0xFF2C2C2E)
            : const Color(0xFFF2F2F7),
      );

  final base = ThemeData(
    colorScheme: scheme,
    useMaterial3: true,
    brightness: brightness,
    scaffoldBackgroundColor: isDark
        ? const Color(0xFF000000)
        : const Color(0xFFF5F5F7),
    fontFamily: 'Roboto',
  );

  return base.copyWith(
    appBarTheme: AppBarTheme(
      elevation: 0,
      scrolledUnderElevation: 0,
      centerTitle: false,
      backgroundColor: isDark
          ? const Color(0xFF000000)
          : const Color(0xFFF5F5F7),
      foregroundColor: scheme.onSurface,
      titleTextStyle: base.textTheme.headlineSmall?.copyWith(
        color: scheme.onSurface,
        fontWeight: FontWeight.w700,
      ),
    ),
    cardTheme: CardThemeData(
      elevation: 0,
      margin: EdgeInsets.zero,
      color: scheme.surface,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
    ),
    dividerTheme: DividerThemeData(
      color: scheme.outlineVariant.withValues(alpha: 0.65),
      thickness: 0.6,
      space: 1,
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        minimumSize: const Size(44, 44),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        textStyle: const TextStyle(fontWeight: FontWeight.w600),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        minimumSize: const Size(44, 44),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        side: BorderSide(color: scheme.outlineVariant),
        textStyle: const TextStyle(fontWeight: FontWeight.w600),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        minimumSize: const Size(44, 44),
        textStyle: const TextStyle(fontWeight: FontWeight.w600),
      ),
    ),
    iconButtonTheme: IconButtonThemeData(
      style: IconButton.styleFrom(
        minimumSize: const Size(44, 44),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      ),
    ),
    navigationBarTheme: NavigationBarThemeData(
      height: 68,
      backgroundColor: Colors.transparent,
      elevation: 0,
      indicatorColor: scheme.primary.withValues(alpha: 0.12),
      labelTextStyle: WidgetStateProperty.resolveWith((states) {
        final selected = states.contains(WidgetState.selected);
        return base.textTheme.labelSmall?.copyWith(
          color: selected ? scheme.primary : scheme.onSurfaceVariant,
          fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
        );
      }),
      iconTheme: WidgetStateProperty.resolveWith((states) {
        final selected = states.contains(WidgetState.selected);
        return IconThemeData(
          color: selected ? scheme.primary : scheme.onSurfaceVariant,
          size: 24,
        );
      }),
    ),
    navigationRailTheme: NavigationRailThemeData(
      backgroundColor: scheme.surface.withValues(alpha: 0.94),
      elevation: 0,
      selectedIconTheme: IconThemeData(color: scheme.primary),
      unselectedIconTheme: IconThemeData(color: scheme.onSurfaceVariant),
      selectedLabelTextStyle: base.textTheme.labelMedium?.copyWith(
        color: scheme.primary,
        fontWeight: FontWeight.w700,
      ),
      unselectedLabelTextStyle: base.textTheme.labelMedium?.copyWith(
        color: scheme.onSurfaceVariant,
      ),
      indicatorColor: scheme.primary.withValues(alpha: 0.12),
    ),
    chipTheme: base.chipTheme.copyWith(
      side: BorderSide(color: scheme.outlineVariant),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      labelStyle: base.textTheme.labelMedium?.copyWith(
        color: scheme.onSurfaceVariant,
      ),
    ),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
    ),
    listTileTheme: ListTileThemeData(
      iconColor: scheme.primary,
      minLeadingWidth: 28,
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      titleTextStyle: base.textTheme.bodyLarge?.copyWith(
        color: scheme.onSurface,
        fontWeight: FontWeight.w600,
      ),
      subtitleTextStyle: base.textTheme.bodySmall?.copyWith(
        color: scheme.onSurfaceVariant,
      ),
    ),
  );
}
