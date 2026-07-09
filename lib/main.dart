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
import 'core/ui/app_colors.dart';
import 'core/ui/ui_constants.dart';

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
  final colors = isDark ? AppColors.dark : AppColors.light;

  final scheme =
      ColorScheme.fromSeed(
        seedColor: colors.accent,
        brightness: brightness,
      ).copyWith(
        primary: colors.accent,
        secondary: colors.activity,
        tertiary: colors.nutrition,
        error: colors.heart,
        surface: colors.cardSurface,
        surfaceContainerHighest: colors.cardSurfaceElevated,
        onSurfaceVariant: colors.secondaryText,
        outline: colors.divider,
        outlineVariant: colors.divider,
      );

  final base = ThemeData(
    colorScheme: scheme,
    useMaterial3: true,
    brightness: brightness,
    scaffoldBackgroundColor: colors.pageBackground,
    fontFamily: 'Roboto',
    extensions: <ThemeExtension<dynamic>>[colors],
  );

  final pageBackground = colors.pageBackground;
  final cardSurface = colors.cardSurface;
  final divider = colors.divider;
  final secondaryText = colors.secondaryText;

  final textTheme = base.textTheme.copyWith(
    displayLarge: base.textTheme.displayLarge?.copyWith(
      fontSize: kDisplayLarge,
      fontWeight: FontWeight.w700,
      height: 1.0,
      letterSpacing: -0.02,
    ),
    displayMedium: base.textTheme.displayMedium?.copyWith(
      fontSize: kDisplayMedium,
      fontWeight: FontWeight.w700,
      height: 1.0,
    ),
    displaySmall: base.textTheme.displaySmall?.copyWith(
      fontSize: kDisplaySmall,
      fontWeight: FontWeight.w700,
      height: 1.0,
    ),
    headlineLarge: base.textTheme.headlineLarge?.copyWith(
      fontSize: kHeadlineLarge,
      fontWeight: FontWeight.w700,
      height: 1.1,
    ),
    headlineMedium: base.textTheme.headlineMedium?.copyWith(
      fontSize: kHeadlineMedium,
      fontWeight: FontWeight.w700,
      height: 1.1,
    ),
    headlineSmall: base.textTheme.headlineSmall?.copyWith(
      fontSize: kHeadlineSmall,
      fontWeight: FontWeight.w700,
      height: 1.2,
    ),
    titleLarge: base.textTheme.titleLarge?.copyWith(
      fontSize: kTitleLarge,
      fontWeight: FontWeight.w700,
      height: 1.25,
    ),
    titleMedium: base.textTheme.titleMedium?.copyWith(
      fontSize: kTitleMedium,
      fontWeight: FontWeight.w600,
      height: 1.2,
      color: secondaryText,
    ),
    titleSmall: base.textTheme.titleSmall?.copyWith(
      fontSize: kTitleSmall,
      fontWeight: FontWeight.w600,
      height: 1.2,
    ),
    bodyLarge: base.textTheme.bodyLarge?.copyWith(
      fontSize: kBodyLarge,
      fontWeight: FontWeight.w400,
      height: 1.35,
    ),
    bodyMedium: base.textTheme.bodyMedium?.copyWith(
      fontSize: kBodyMedium,
      fontWeight: FontWeight.w400,
      height: 1.3,
    ),
    bodySmall: base.textTheme.bodySmall?.copyWith(
      fontSize: kBodySmall,
      fontWeight: FontWeight.w400,
      height: 1.3,
      color: secondaryText,
    ),
    labelLarge: base.textTheme.labelLarge?.copyWith(
      fontSize: kLabelLarge,
      fontWeight: FontWeight.w600,
      height: 1.25,
    ),
    labelMedium: base.textTheme.labelMedium?.copyWith(
      fontSize: kLabelMedium,
      fontWeight: FontWeight.w600,
      height: 1.0,
    ),
    labelSmall: base.textTheme.labelSmall?.copyWith(
      fontSize: kLabelSmall,
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
      shadowColor: Colors.black.withValues(alpha: isDark ? 0.22 : 0.06),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(kCardRadius + 4),
        side: BorderSide(color: divider.withValues(alpha: isDark ? 0.8 : 0.7)),
      ),
    ),
    dividerTheme: DividerThemeData(color: divider, thickness: 1, space: 1),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        minimumSize: Size(0, kIconCircleSizeSmall + kListTilePaddingV),
        padding: const EdgeInsets.symmetric(horizontal: kCardPadding),
        elevation: 0,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        textStyle: textTheme.labelLarge?.copyWith(
          fontSize: kLabelLarge,
          color: scheme.onPrimary,
        ),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        minimumSize: Size(0, kIconCircleSizeSmall + kListTilePaddingV),
        padding: const EdgeInsets.symmetric(horizontal: kCardPadding),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        side: BorderSide(color: divider),
        textStyle: textTheme.labelLarge?.copyWith(
          fontSize: kLabelLarge,
          color: scheme.onSurface,
        ),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        minimumSize: const Size(44, 44),
        textStyle: textTheme.labelSmall?.copyWith(
          fontSize: kLabelSmall,
          fontWeight: FontWeight.w700,
        ),
      ),
    ),
    iconButtonTheme: IconButtonThemeData(
      style: IconButton.styleFrom(
        minimumSize: const Size(44, 44),
        backgroundColor: scheme.surface.withValues(alpha: 0.72),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      ),
    ),
    navigationBarTheme: NavigationBarThemeData(
      height: 72,
      backgroundColor: Colors.transparent,
      elevation: 0,
      indicatorColor: scheme.primary.withValues(alpha: isDark ? 0.24 : 0.13),
      indicatorShape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
      ),
      labelTextStyle: WidgetStateProperty.resolveWith((states) {
        final selected = states.contains(WidgetState.selected);
        return textTheme.labelSmall?.copyWith(
          fontSize: kLabelSmall,
          color: selected ? scheme.primary : secondaryText,
          fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
        );
      }),
      iconTheme: WidgetStateProperty.resolveWith((states) {
        final selected = states.contains(WidgetState.selected);
        return IconThemeData(
          color: selected ? scheme.primary : secondaryText,
          size: kIconSizeSmall,
        );
      }),
    ),
    navigationRailTheme: NavigationRailThemeData(
      backgroundColor: scheme.surface.withValues(alpha: 0.94),
      elevation: 0,
      selectedIconTheme: IconThemeData(
        color: scheme.primary,
        size: kIconSizeSmall,
      ),
      unselectedIconTheme: IconThemeData(
        color: secondaryText,
        size: kIconSizeSmall,
      ),
      selectedLabelTextStyle: textTheme.labelMedium?.copyWith(
        fontSize: kLabelMedium,
        color: scheme.primary,
        fontWeight: FontWeight.w700,
      ),
      unselectedLabelTextStyle: textTheme.labelMedium?.copyWith(
        fontSize: kLabelMedium,
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
      contentPadding: const EdgeInsets.symmetric(
        horizontal: kListTilePaddingH,
        vertical: kListTilePaddingV,
      ),
      titleTextStyle: textTheme.bodyMedium?.copyWith(
        fontSize: kBodyMedium,
        color: scheme.onSurface,
        fontWeight: FontWeight.w600,
      ),
      subtitleTextStyle: textTheme.bodySmall?.copyWith(
        fontSize: kBodySmall,
        color: secondaryText,
      ),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: cardSurface,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(kCardRadius),
      ),
      titleTextStyle: textTheme.titleLarge?.copyWith(color: scheme.onSurface),
      contentTextStyle: textTheme.bodyMedium?.copyWith(
        color: scheme.onSurfaceVariant,
        height: 1.4,
      ),
    ),
    switchTheme: SwitchThemeData(
      thumbColor: WidgetStateProperty.resolveWith((states) {
        if (states.contains(WidgetState.selected)) return scheme.onPrimary;
        return scheme.outline;
      }),
      trackColor: WidgetStateProperty.resolveWith((states) {
        if (states.contains(WidgetState.selected)) return scheme.primary;
        return scheme.surfaceContainerHighest;
      }),
      trackOutlineColor: WidgetStateProperty.resolveWith((states) {
        if (states.contains(WidgetState.selected)) return Colors.transparent;
        return divider;
      }),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: scheme.surfaceContainerHighest.withValues(alpha: 0.5),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(kChipRadius + 4),
        borderSide: BorderSide(color: divider),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(kChipRadius + 4),
        borderSide: BorderSide(color: divider),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(kChipRadius + 4),
        borderSide: BorderSide(color: scheme.primary, width: 1.5),
      ),
      contentPadding: const EdgeInsets.symmetric(
        horizontal: kCardPadding,
        vertical: kListTilePaddingV,
      ),
    ),
    bottomSheetTheme: BottomSheetThemeData(
      backgroundColor: cardSurface,
      elevation: 0,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(kCardRadius)),
      ),
      showDragHandle: true,
    ),
    popupMenuTheme: PopupMenuThemeData(
      color: cardSurface,
      elevation: 4,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(kChipRadius + 4),
      ),
      textStyle: textTheme.bodyMedium,
    ),
  );
}
