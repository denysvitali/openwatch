import 'package:flutter/material.dart';

import 'app_colors.dart';

// Text sizes -------------------------------------------------------------

const double kDisplayLarge = 40;
const double kDisplayMedium = 36;
const double kDisplaySmall = 32;
const double kHeadlineLarge = 28;
const double kHeadlineMedium = 26;
const double kHeadlineSmall = 20;
const double kTitleLarge = 17;
const double kTitleMedium = 16;
const double kTitleSmall = 14;
const double kBodyLarge = 15;
const double kBodyMedium = 14;
const double kBodySmall = 12;
const double kLabelLarge = 15;
const double kLabelMedium = 12;
const double kLabelSmall = 11;

// Spacing ----------------------------------------------------------------

const double kCardPadding = 16;
const double kCardRadius = 20;
const double kCardInternalSpacing = 16;

const double kSectionHeaderPaddingH = 4;
const double kSectionHeaderPaddingTop = 24;
const double kSectionHeaderPaddingBottom = 12;

const double kListTilePaddingH = 16;
const double kListTilePaddingV = 12;

const double kSpacingMini = 2;
const double kSpacingTiny = 4;
const double kSpacingSmall = 8;
const double kSpacingMedium = 12;
const double kSpacingLarge = 20;
const double kSpacingXLarge = 24;

const double kIconCircleSizeLarge = 48;
const double kIconCircleSizeSmall = 36;
const double kIconCircleSizeListTile = 28;

/// Minimum interactive hit area (Material/HIG accessibility guideline).
const double kMinTouchTarget = 44;

const double kIconSizeLarge = 28;
const double kIconSizeSmall = 20;
const double kIconSizeTiny = 16;

const double kGridSpacing = 12;
const double kGridChildAspectRatio = 1.65;

// Status pill -------------------------------------------------------------

const double kPillHeight = 22;
const double kPillRadius = 10;
const double kPillIconSize = 12;

// Chips / badges / tooltips ------------------------------------------------

const double kChipRadius = 8;
const double kChipPaddingH = 12;
const double kChipPaddingV = 6;

// Screen layout ------------------------------------------------------------

const double kScreenPaddingH = 16;
const double kScreenPaddingTop = 8;
const double kScreenPaddingBottom = 24;
const double kEmptyStatePadding = 24;

// Semantic tints / opacity values -----------------------------------------

const double kMetricTintOpacity = 0.08;
const double kPillTintOpacity = 0.10;
const double kCardGradientOpacityStart = 0.08;
const double kCardGradientOpacityEnd = 0.02;

// Chart / metric colors ----------------------------------------------------
//
// Prefer [AppColors.of]; these helpers remain for chart code.

Color kHeartRed(BuildContext context) => AppColors.of(context).heart;

Color kSleepPurple(BuildContext context) => AppColors.of(context).sleep;

Color kActivityGreen(BuildContext context) => AppColors.of(context).activity;

Color kStressOrange(BuildContext context) => AppColors.of(context).stress;

Color kSpo2Blue(BuildContext context) => AppColors.of(context).spo2;

Color kHrvTeal(BuildContext context) => AppColors.of(context).hrv;

/// Convenience wrappers around [TextTheme] that use the UI constants above.
///
/// Usage:
/// ```dart
/// Text('Hello', style: AppTextStyles.headlineMedium(context))
/// ```
class AppTextStyles {
  AppTextStyles._();

  static TextTheme _theme(BuildContext context) => Theme.of(context).textTheme;

  static TextStyle? _style(TextStyle? base, double fontSize) =>
      base?.copyWith(fontSize: fontSize, height: 1.2, letterSpacing: 0);

  static TextStyle? displayLarge(BuildContext context) =>
      _style(_theme(context).displayLarge, kDisplayLarge);

  static TextStyle? displayMedium(BuildContext context) =>
      _style(_theme(context).displayMedium, kDisplayMedium);

  static TextStyle? displaySmall(BuildContext context) =>
      _style(_theme(context).displaySmall, kDisplaySmall);

  static TextStyle? headlineLarge(BuildContext context) =>
      _style(_theme(context).headlineLarge, kHeadlineLarge);

  static TextStyle? headlineMedium(BuildContext context) =>
      _style(_theme(context).headlineMedium, kHeadlineMedium);

  static TextStyle? headlineSmall(BuildContext context) =>
      _style(_theme(context).headlineSmall, kHeadlineSmall);

  static TextStyle? titleLarge(BuildContext context) =>
      _style(_theme(context).titleLarge, kTitleLarge);

  static TextStyle? titleMedium(BuildContext context) =>
      _style(_theme(context).titleMedium, kTitleMedium);

  static TextStyle? titleSmall(BuildContext context) =>
      _style(_theme(context).titleSmall, kTitleSmall);

  static TextStyle? bodyLarge(BuildContext context) =>
      _style(_theme(context).bodyLarge, kBodyLarge);

  static TextStyle? bodyMedium(BuildContext context) =>
      _style(_theme(context).bodyMedium, kBodyMedium);

  static TextStyle? bodySmall(BuildContext context) =>
      _style(_theme(context).bodySmall, kBodySmall);

  static TextStyle? labelLarge(BuildContext context) =>
      _style(_theme(context).labelLarge, kLabelLarge);

  static TextStyle? labelMedium(BuildContext context) =>
      _style(_theme(context).labelMedium, kLabelMedium);

  static TextStyle? labelSmall(BuildContext context) =>
      _style(_theme(context).labelSmall, kLabelSmall);
}
