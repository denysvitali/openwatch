import 'package:flutter/material.dart';

import '../../../core/services/history_store.dart';

/// Vertical bar chart of step counts across a small range of days.
///
/// Designed for the dashboard's "this week" view — fits up to ~14 days
/// without crowding the bars; for longer ranges the UI should switch
/// to a denser display.
///
/// Days without a recorded step count render as a 1-px placeholder bar
/// so the spacing stays uniform (an empty bar reads better than a gap).
class StepsBarChart extends StatelessWidget {
  const StepsBarChart({super.key, required this.days});

  /// Days in display order — first entry = leftmost bar. Typically
  /// `today.subDays(N)..today` so the right-most bar is today.
  final List<DailyHistory> days;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 120,
      child: CustomPaint(
        painter: _StepsPainter(
          days: days,
          barColor: Theme.of(context).colorScheme.primary,
          todayColor: Theme.of(context).colorScheme.tertiary,
          axisColor: Theme.of(context).colorScheme.outlineVariant,
          textColor: Theme.of(context).colorScheme.onSurfaceVariant,
        ),
        size: Size.infinite,
      ),
    );
  }
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

  static const double _bottomAxisHeight = 22;

  @override
  void paint(Canvas canvas, Size size) {
    if (days.isEmpty) return;
    final chartRect = Rect.fromLTWH(
      0,
      4,
      size.width,
      size.height - _bottomAxisHeight - 4,
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
      ..color = axisColor
      ..strokeWidth = 0.5;

    // Y-axis: 3 horizontal gridlines at 25 / 50 / 100% of maxSteps.
    for (final frac in [0.25, 0.5, 1.0]) {
      final y = chartRect.bottom - frac * chartRect.height;
      canvas.drawLine(
        Offset(chartRect.left, y),
        Offset(chartRect.right, y),
        gridPaint,
      );
      _paintText(
        canvas,
        _formatSteps((maxSteps * frac).round()),
        Offset(2, y - 12),
        color: textColor,
        size: 10,
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
        const Radius.circular(2),
      );
      canvas.drawRRect(rect, paint);
      // Day-of-week label below the bar.
      _paintText(
        canvas,
        _weekdayShort(d.day),
        Offset(centerX - 6, chartRect.bottom + 4),
        color: textColor,
        size: 9,
      );
    }
  }

  void _paintText(
    Canvas canvas,
    String text,
    Offset at, {
    double size = 11,
    required Color color,
  }) {
    final tp = TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(color: color, fontSize: size),
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
