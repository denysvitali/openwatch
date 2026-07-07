import 'package:flutter/material.dart';

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

const double kSectionHeaderPaddingH = 20;
const double kSectionHeaderPaddingTop = 24;
const double kSectionHeaderPaddingBottom = 12;

const double kListTilePaddingH = 16;
const double kListTilePaddingV = 12;

const double kSpacingTiny = 4;
const double kSpacingSmall = 8;

const double kIconCircleSizeLarge = 48;
const double kIconCircleSizeSmall = 36;

const double kIconSizeLarge = 28;
const double kIconSizeSmall = 20;
const double kIconSizeTiny = 16;

const double kGridSpacing = 12;
const double kGridChildAspectRatio = 1.05;

// Status pill -------------------------------------------------------------

const double kPillHeight = 22;
const double kPillPaddingH = 8;
const double kPillRadius = 10;
const double kPillIconSize = 12;
const double kPillSpacing = 4;

// Semantic tints / opacity values -----------------------------------------

const double kMetricTintOpacity = 0.08;
const double kPillTintOpacity = 0.10;
const double kCardGradientOpacityStart = 0.08;
const double kCardGradientOpacityEnd = 0.02;

/// Convenience wrappers around [TextTheme] that use the UI constants above.
///
/// Usage:
/// ```dart
/// Text('Hello', style: AppTextStyles.headlineMedium(context))
/// ```
class AppTextStyles {
  AppTextStyles._();

  static TextTheme _theme(BuildContext context) => Theme.of(context).textTheme;

  static TextStyle? displayLarge(BuildContext context) =>
      _theme(context).displayLarge?.copyWith(fontSize: kDisplayLarge);

  static TextStyle? displayMedium(BuildContext context) =>
      _theme(context).displayMedium?.copyWith(fontSize: kDisplayMedium);

  static TextStyle? displaySmall(BuildContext context) =>
      _theme(context).displaySmall?.copyWith(fontSize: kDisplaySmall);

  static TextStyle? headlineLarge(BuildContext context) =>
      _theme(context).headlineLarge?.copyWith(fontSize: kHeadlineLarge);

  static TextStyle? headlineMedium(BuildContext context) =>
      _theme(context).headlineMedium?.copyWith(fontSize: kHeadlineMedium);

  static TextStyle? headlineSmall(BuildContext context) =>
      _theme(context).headlineSmall?.copyWith(fontSize: kHeadlineSmall);

  static TextStyle? titleLarge(BuildContext context) =>
      _theme(context).titleLarge?.copyWith(fontSize: kTitleLarge);

  static TextStyle? titleMedium(BuildContext context) =>
      _theme(context).titleMedium?.copyWith(fontSize: kTitleMedium);

  static TextStyle? titleSmall(BuildContext context) =>
      _theme(context).titleSmall?.copyWith(fontSize: kTitleSmall);

  static TextStyle? bodyLarge(BuildContext context) =>
      _theme(context).bodyLarge?.copyWith(fontSize: kBodyLarge);

  static TextStyle? bodyMedium(BuildContext context) =>
      _theme(context).bodyMedium?.copyWith(fontSize: kBodyMedium);

  static TextStyle? bodySmall(BuildContext context) =>
      _theme(context).bodySmall?.copyWith(fontSize: kBodySmall);

  static TextStyle? labelLarge(BuildContext context) =>
      _theme(context).labelLarge?.copyWith(fontSize: kLabelLarge);

  static TextStyle? labelMedium(BuildContext context) =>
      _theme(context).labelMedium?.copyWith(fontSize: kLabelMedium);

  static TextStyle? labelSmall(BuildContext context) =>
      _theme(context).labelSmall?.copyWith(fontSize: kLabelSmall);
}
