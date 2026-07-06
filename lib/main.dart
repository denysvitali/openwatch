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
  final isDark = brightness == Brightness.dark;

  // Design-system semantic health colors.
  final primaryAccent = isDark
      ? const Color(0xFF0A84FF)
      : const Color(0xFF007AFF);
  final heartRed = isDark ? const Color(0xFFFF453A) : const Color(0xFFFF3B30);
  final activityGreen = isDark
      ? const Color(0xFF30D158)
      : const Color(0xFF34C759);
  final nutritionOrange = isDark
      ? const Color(0xFFFF9F0A)
      : const Color(0xFFFF9500);
  final pageBackground = isDark
      ? const Color(0xFF000000)
      : const Color(0xFFF5F5F7);
  final cardSurface = isDark
      ? const Color(0xFF1C1C1E)
      : const Color(0xFFFFFFFF);
  final cardSurfaceElevated = isDark
      ? const Color(0xFF2C2C2E)
      : const Color(0xFFFFFFFF);
  final divider = isDark ? const Color(0xFF38383A) : const Color(0xFFE5E5EA);
  final secondaryText = const Color(0xFF8E8E93);

  final scheme =
      ColorScheme.fromSeed(
        seedColor: primaryAccent,
        brightness: brightness,
      ).copyWith(
        primary: primaryAccent,
        secondary: activityGreen,
        tertiary: nutritionOrange,
        error: heartRed,
        surface: cardSurface,
        surfaceContainerHighest: cardSurfaceElevated,
        onSurfaceVariant: secondaryText,
        outline: divider,
        outlineVariant: divider,
      );

  final base = ThemeData(
    colorScheme: scheme,
    useMaterial3: true,
    brightness: brightness,
    scaffoldBackgroundColor: pageBackground,
    fontFamily: 'Roboto',
  );

  final textTheme = base.textTheme.copyWith(
    displayLarge: base.textTheme.displayLarge?.copyWith(
      fontSize: 56,
      fontWeight: FontWeight.w700,
      height: 1.0,
      letterSpacing: -0.02,
    ),
    headlineMedium: base.textTheme.headlineMedium?.copyWith(
      fontSize: 32,
      fontWeight: FontWeight.w700,
      height: 1.0,
    ),
    headlineSmall: base.textTheme.headlineSmall?.copyWith(
      fontSize: 28,
      fontWeight: FontWeight.w700,
      height: 1.2,
    ),
    titleLarge: base.textTheme.titleLarge?.copyWith(
      fontSize: 20,
      fontWeight: FontWeight.w700,
      height: 1.25,
    ),
    titleMedium: base.textTheme.titleMedium?.copyWith(
      fontSize: 20,
      fontWeight: FontWeight.w600,
      height: 1.2,
      color: secondaryText,
    ),
    bodyLarge: base.textTheme.bodyLarge?.copyWith(
      fontSize: 17,
      fontWeight: FontWeight.w400,
      height: 1.35,
    ),
    bodySmall: base.textTheme.bodySmall?.copyWith(
      fontSize: 13,
      fontWeight: FontWeight.w400,
      height: 1.3,
      color: secondaryText,
    ),
    labelLarge: base.textTheme.labelLarge?.copyWith(
      fontSize: 16,
      fontWeight: FontWeight.w600,
      height: 1.25,
    ),
    labelMedium: base.textTheme.labelMedium?.copyWith(
      fontSize: 14,
      fontWeight: FontWeight.w600,
      height: 1.0,
    ),
    labelSmall: base.textTheme.labelSmall?.copyWith(
      fontSize: 11,
      fontWeight: FontWeight.w700,
      height: 1.0,
      letterSpacing: 0.8,
    ),
  );

  return base.copyWith(
    textTheme: textTheme,
    appBarTheme: AppBarTheme(
      elevation: 0,
      scrolledUnderElevation: 0,
      centerTitle: false,
      backgroundColor: pageBackground,
      foregroundColor: scheme.onSurface,
      titleTextStyle: textTheme.headlineSmall?.copyWith(
        color: scheme.onSurface,
        fontWeight: FontWeight.w700,
      ),
    ),
    cardTheme: CardThemeData(
      elevation: 0,
      margin: EdgeInsets.zero,
      color: scheme.surface,
      shadowColor: Colors.transparent,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
    ),
    dividerTheme: DividerThemeData(color: divider, thickness: 1, space: 1),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        minimumSize: const Size(0, 54),
        padding: const EdgeInsets.symmetric(horizontal: 24),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        textStyle: textTheme.labelLarge?.copyWith(
          fontSize: 16,
          fontWeight: FontWeight.w600,
          height: 1.25,
        ),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        minimumSize: const Size(0, 54),
        padding: const EdgeInsets.symmetric(horizontal: 24),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        side: BorderSide(color: divider),
        textStyle: textTheme.labelLarge?.copyWith(
          fontSize: 16,
          fontWeight: FontWeight.w600,
          height: 1.25,
        ),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        minimumSize: const Size(44, 44),
        textStyle: textTheme.labelSmall?.copyWith(fontWeight: FontWeight.w700),
      ),
    ),
    iconButtonTheme: IconButtonThemeData(
      style: IconButton.styleFrom(
        minimumSize: const Size(44, 44),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
    ),
    navigationBarTheme: NavigationBarThemeData(
      height: 68,
      backgroundColor: Colors.transparent,
      elevation: 0,
      indicatorColor: scheme.primary.withValues(alpha: 0.12),
      indicatorShape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
      ),
      labelTextStyle: WidgetStateProperty.resolveWith((states) {
        final selected = states.contains(WidgetState.selected);
        return textTheme.labelSmall?.copyWith(
          color: selected ? scheme.primary : secondaryText,
          fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
        );
      }),
      iconTheme: WidgetStateProperty.resolveWith((states) {
        final selected = states.contains(WidgetState.selected);
        return IconThemeData(
          color: selected ? scheme.primary : secondaryText,
          size: 24,
        );
      }),
    ),
    navigationRailTheme: NavigationRailThemeData(
      backgroundColor: scheme.surface.withValues(alpha: 0.94),
      elevation: 0,
      selectedIconTheme: IconThemeData(color: scheme.primary),
      unselectedIconTheme: IconThemeData(color: secondaryText),
      selectedLabelTextStyle: textTheme.labelMedium?.copyWith(
        color: scheme.primary,
        fontWeight: FontWeight.w700,
      ),
      unselectedLabelTextStyle: textTheme.labelMedium?.copyWith(
        color: secondaryText,
      ),
      indicatorColor: scheme.primary.withValues(alpha: 0.12),
      indicatorShape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
      ),
    ),
    chipTheme: base.chipTheme.copyWith(
      backgroundColor: cardSurface,
      side: BorderSide(color: divider),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      labelStyle: textTheme.labelMedium?.copyWith(color: secondaryText),
    ),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      backgroundColor: scheme.inverseSurface,
      contentTextStyle: textTheme.bodyMedium?.copyWith(
        color: scheme.onInverseSurface,
      ),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
    ),
    listTileTheme: ListTileThemeData(
      iconColor: scheme.primary,
      minLeadingWidth: 28,
      contentPadding: const EdgeInsets.symmetric(horizontal: 18, vertical: 16),
      titleTextStyle: textTheme.bodyLarge?.copyWith(
        color: scheme.onSurface,
        fontWeight: FontWeight.w600,
      ),
      subtitleTextStyle: textTheme.bodySmall?.copyWith(color: secondaryText),
    ),
  );
}
