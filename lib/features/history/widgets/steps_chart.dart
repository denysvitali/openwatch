import 'package:flutter/material.dart';

import '../../../core/services/history_store.dart';
import '../../../core/ui/ui_constants.dart';

/// Vertical bar chart of step counts across a small range of days.
///
/// Designed for the dashboard's "this week" view — fits up to ~14 days
/// without crowding the bars; for longer ranges the UI should switch
/// to a denser display.
///
/// Days without a recorded step count render as a 1-px placeholder bar
/// so the spacing stays uniform (an empty bar reads better than a gap).
class StepsBarChart extends StatelessWidget {
  const StepsBarChart({
    super.key,
    required this.days,
    this.height = 120,
    this.barColor,
    this.todayColor,
  });

  /// Days in display order — first entry = leftmost bar. Typically
  /// `today.subDays(N)..today` so the right-most bar is today.
  final List<DailyHistory> days;
  final double height;
  final Color? barColor;
  final Color? todayColor;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final effectiveBarColor = barColor ?? _activityGreen(theme);
    final effectiveTodayColor = todayColor ?? theme.colorScheme.tertiary;
    if (days.isEmpty) {
      return SizedBox(
        height: height,
        child: Center(
          child: Text(
            'No step data',
            style: AppTextStyles.bodySmall(
              context,
            )?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
        ),
      );
    }
    return SizedBox(
      height: height,
      child: Semantics(
        label: 'Steps bar chart',
        excludeSemantics: true,
        child: CustomPaint(
          painter: _StepsPainter(
            days: days,
            barColor: effectiveBarColor,
            todayColor: effectiveTodayColor,
            axisColor: theme.colorScheme.outlineVariant,
            textColor: theme.colorScheme.onSurfaceVariant,
          ),
          size: Size.infinite,
        ),
      ),
    );
  }
}

Color _activityGreen(ThemeData theme) {
  return theme.brightness == Brightness.dark
      ? const Color(0xFF30D158)
      : const Color(0xFF34C759);
}

class _StepsPainter extends CustomPainter {
  _StepsPainter({
    required this.days,
    required this.barColor,
    required this.todayColor,
    required this.axisColor,
    required this.textColor,
  });

  final List<DailyHistory> days;
  final Color barColor;
  final Color todayColor;
  final Color axisColor;
  final Color textColor;

  static const double _topLabelHeight = 16;
  static const double _bottomAxisHeight = 18;

  @override
  void paint(Canvas canvas, Size size) {
    if (days.isEmpty) return;
    final chartRect = Rect.fromLTWH(
      0,
      _topLabelHeight,
      size.width,
      size.height - _bottomAxisHeight - _topLabelHeight,
    );

    // Y-axis: max of (steps, 1000) so a brand-new user with no data
    // still sees a usable scale rather than a flat line.
    final maxSteps = [
      for (final d in days) d.steps ?? 0,
    ].fold<int>(1000, (a, b) => a > b ? a : b);

    final today = DateOnly.today();
    final barCount = days.length;
    final slot = chartRect.width / barCount;
    final barW = (slot * 0.6).clamp(2.0, 24.0);
    final paint = Paint()..style = PaintingStyle.fill;
    final gridPaint = Paint()
      ..color = axisColor.withValues(alpha: 0.32)
      ..strokeWidth = 0.5;

    // Y-axis: a minimal Apple-style grid: enough scale without clutter.
    for (final frac in [0.5, 1.0]) {
      final y = chartRect.bottom - frac * chartRect.height;
      canvas.drawLine(
        Offset(chartRect.left, y),
        Offset(chartRect.right, y),
        gridPaint,
      );
      _paintText(
        canvas,
        _formatSteps((maxSteps * frac).round()),
        Offset(0, y - 12),
        color: textColor.withValues(alpha: 0.56),
        size: kLabelSmall,
      );
    }
    // Baseline.
    canvas.drawLine(
      Offset(chartRect.left, chartRect.bottom),
      Offset(chartRect.right, chartRect.bottom),
      gridPaint,
    );

    // Bars + day labels.
    for (var i = 0; i < days.length; i++) {
      final d = days[i];
      final centerX = chartRect.left + (i + 0.5) * slot;
      final steps = d.steps ?? 0;
      final h = steps <= 0 ? 1.0 : (steps / maxSteps) * chartRect.height;
      paint.color = d.day == today ? todayColor : barColor;
      final rect = RRect.fromRectAndRadius(
        Rect.fromLTWH(centerX - barW / 2, chartRect.bottom - h, barW, h),
        Radius.circular(barW / 2),
      );
      canvas.drawRRect(rect, paint);
      if (steps > 0 && barCount <= 7) {
        final label = _formatSteps(steps);
        final labelWidth = _measureText(label, size: kLabelSmall);
        _paintText(
          canvas,
          label,
          Offset(centerX - labelWidth / 2, chartRect.bottom - h - 14),
          color: textColor.withValues(alpha: 0.56),
          size: kLabelSmall,
        );
      }
      // Day-of-week label below the bar.
      final weekday = _weekdayShort(d.day);
      final labelWidth = _measureText(weekday, size: kLabelSmall);
      _paintText(
        canvas,
        weekday,
        Offset(centerX - labelWidth / 2, chartRect.bottom + 5),
        color: textColor.withValues(alpha: 0.72),
        size: kLabelSmall,
      );
    }
  }

  double _measureText(String text, {double size = kLabelSmall}) {
    final tp = TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(fontSize: size, height: 1.0, letterSpacing: 0),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    return tp.width;
  }

  void _paintText(
    Canvas canvas,
    String text,
    Offset at, {
    double size = kLabelSmall,
    required Color color,
  }) {
    final tp = TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(
          color: color,
          fontSize: size,
          height: 1.0,
          letterSpacing: 0,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(canvas, at);
  }

  String _formatSteps(int n) {
    if (n >= 1000) return '${(n / 1000).toStringAsFixed(n >= 10000 ? 0 : 1)}k';
    return '$n';
  }

  static const _weekdays = ['Mo', 'Tu', 'We', 'Th', 'Fr', 'Sa', 'Su'];
  String _weekdayShort(DateOnly d) {
    final dt = DateTime(d.year, d.month, d.day);
    // DateTime.weekday: 1 = Monday, 7 = Sunday.
    return _weekdays[dt.weekday - 1];
  }

  @override
  bool shouldRepaint(_StepsPainter old) =>
      old.days != days ||
      old.barColor != barColor ||
      old.todayColor != todayColor;
}
