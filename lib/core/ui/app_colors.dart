import 'package:flutter/material.dart';

/// Semantic OpenWatch colors as a [ThemeExtension].
///
/// Single source of truth for health-metric tints and surfaces. Prefer
/// `Theme.of(context).extension<AppColors>()!` (or [AppColors.of]) over
/// hardcoded hex values in feature screens.
@immutable
class AppColors extends ThemeExtension<AppColors> {
  const AppColors({
    required this.accent,
    required this.heart,
    required this.activity,
    required this.nutrition,
    required this.sleep,
    required this.stress,
    required this.spo2,
    required this.hrv,
    required this.pageBackground,
    required this.cardSurface,
    required this.cardSurfaceElevated,
    required this.divider,
    required this.secondaryText,
  });

  final Color accent;
  final Color heart;
  final Color activity;
  final Color nutrition;
  final Color sleep;
  final Color stress;
  final Color spo2;
  final Color hrv;
  final Color pageBackground;
  final Color cardSurface;
  final Color cardSurfaceElevated;
  final Color divider;
  final Color secondaryText;

  /// Light palette — Apple Health–inspired.
  static const light = AppColors(
    accent: Color(0xFF007AFF),
    heart: Color(0xFFFF3B30),
    activity: Color(0xFF34C759),
    nutrition: Color(0xFFFF9500),
    sleep: Color(0xFF5856D6),
    stress: Color(0xFFFF9500),
    spo2: Color(0xFF32ADE6),
    hrv: Color(0xFF00C7BE),
    pageBackground: Color(0xFFF5F5F7),
    cardSurface: Color(0xFFFFFFFF),
    cardSurfaceElevated: Color(0xFFFFFFFF),
    divider: Color(0xFFE5E5EA),
    secondaryText: Color(0xFF8E8E93),
  );

  /// Dark palette.
  static const dark = AppColors(
    accent: Color(0xFF0A84FF),
    heart: Color(0xFFFF453A),
    activity: Color(0xFF30D158),
    nutrition: Color(0xFFFF9F0A),
    sleep: Color(0xFF5E5CE6),
    stress: Color(0xFFFF9F0A),
    spo2: Color(0xFF64D2FF),
    hrv: Color(0xFF63E6E2),
    pageBackground: Color(0xFF000000),
    cardSurface: Color(0xFF1C1C1E),
    cardSurfaceElevated: Color(0xFF2C2C2E),
    divider: Color(0xFF38383A),
    secondaryText: Color(0xFF8E8E93),
  );

  static AppColors of(BuildContext context) {
    return Theme.of(context).extension<AppColors>() ??
        (Theme.of(context).brightness == Brightness.dark ? dark : light);
  }

  @override
  AppColors copyWith({
    Color? accent,
    Color? heart,
    Color? activity,
    Color? nutrition,
    Color? sleep,
    Color? stress,
    Color? spo2,
    Color? hrv,
    Color? pageBackground,
    Color? cardSurface,
    Color? cardSurfaceElevated,
    Color? divider,
    Color? secondaryText,
  }) {
    return AppColors(
      accent: accent ?? this.accent,
      heart: heart ?? this.heart,
      activity: activity ?? this.activity,
      nutrition: nutrition ?? this.nutrition,
      sleep: sleep ?? this.sleep,
      stress: stress ?? this.stress,
      spo2: spo2 ?? this.spo2,
      hrv: hrv ?? this.hrv,
      pageBackground: pageBackground ?? this.pageBackground,
      cardSurface: cardSurface ?? this.cardSurface,
      cardSurfaceElevated: cardSurfaceElevated ?? this.cardSurfaceElevated,
      divider: divider ?? this.divider,
      secondaryText: secondaryText ?? this.secondaryText,
    );
  }

  @override
  AppColors lerp(ThemeExtension<AppColors>? other, double t) {
    if (other is! AppColors) return this;
    return AppColors(
      accent: Color.lerp(accent, other.accent, t)!,
      heart: Color.lerp(heart, other.heart, t)!,
      activity: Color.lerp(activity, other.activity, t)!,
      nutrition: Color.lerp(nutrition, other.nutrition, t)!,
      sleep: Color.lerp(sleep, other.sleep, t)!,
      stress: Color.lerp(stress, other.stress, t)!,
      spo2: Color.lerp(spo2, other.spo2, t)!,
      hrv: Color.lerp(hrv, other.hrv, t)!,
      pageBackground: Color.lerp(pageBackground, other.pageBackground, t)!,
      cardSurface: Color.lerp(cardSurface, other.cardSurface, t)!,
      cardSurfaceElevated: Color.lerp(
        cardSurfaceElevated,
        other.cardSurfaceElevated,
        t,
      )!,
      divider: Color.lerp(divider, other.divider, t)!,
      secondaryText: Color.lerp(secondaryText, other.secondaryText, t)!,
    );
  }
}
