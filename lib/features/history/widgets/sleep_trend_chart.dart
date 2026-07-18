import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../core/services/history_store.dart';
import '../../../core/ui/ui_constants.dart';

/// Compact daily sleep-duration trend with a weekly average marker.
///
/// Missing days render as a small placeholder so gaps in local history remain
/// visible without implying zero sleep.
class SleepTrendChart extends StatelessWidget {
  const SleepTrendChart({
    super.key,
    required this.days,
    this.height = 112,
    this.sleepColor,
  });

  /// Days in display order, first entry = leftmost bar.
  final List<DailyHistory> days;
  final double height;
  final Color? sleepColor;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final effectiveSleepColor = sleepColor ?? _sleepPurple(theme);
    if (days.isEmpty) {
      return SizedBox(
        height: height,
        child: Center(
          child: Text(
            'No sleep data',
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
        label: 'Sleep trend chart',
        excludeSemantics: true,
        child: CustomPaint(
          painter: _SleepTrendPainter(
            days: days,
            sleepColor: effectiveSleepColor,
            todayColor: theme.colorScheme.tertiary,
            averageColor: theme.colorScheme.secondary,
            axisColor: theme.colorScheme.outlineVariant,
            textColor: theme.colorScheme.onSurfaceVariant,
          ),
          size: Size.infinite,
        ),
      ),
    );
  }
}

Color _sleepPurple(ThemeData theme) {
  return theme.brightness == Brightness.dark
      ? const Color(0xFF5E5CE6)
      : const Color(0xFF5856D6);
}

@immutable
class SleepTrendSummary {
  const SleepTrendSummary({
    required this.average,
    required this.latest,
    required this.previous,
  });

  final Duration average;
  final Duration? latest;
  final Duration? previous;

  bool get hasData => average > Duration.zero;

  int? get trendMinutes {
    final current = latest;
    final prior = previous;
    if (current == null || prior == null) return null;
    return current.inMinutes - prior.inMinutes;
  }

  factory SleepTrendSummary.fromDays(Iterable<DailyHistory> days) {
    final totals = <Duration>[];
    Duration? latest;
    Duration? previous;
    for (final day in days) {
      final total = totalSleep(day);
      if (total <= Duration.zero) continue;
      totals.add(total);
      previous = latest;
      latest = total;
    }
    if (totals.isEmpty) {
      return const SleepTrendSummary(
        average: Duration.zero,
        latest: null,
        previous: null,
      );
    }
    final minutes = totals.fold<int>(0, (sum, d) => sum + d.inMinutes);
    return SleepTrendSummary(
      average: Duration(minutes: (minutes / totals.length).round()),
      latest: latest,
      previous: previous,
    );
  }

  static Duration totalSleep(DailyHistory day) {
    return day.sleep.fold<Duration>(Duration.zero, (a, s) => a + s.duration);
  }
}

class _SleepTrendPainter extends CustomPainter {
  _SleepTrendPainter({
    required this.days,
    required this.sleepColor,
    required this.todayColor,
    required this.averageColor,
    required this.axisColor,
    required this.textColor,
  });

  final List<DailyHistory> days;
  final Color sleepColor;
  final Color todayColor;
  final Color averageColor;
  final Color axisColor;
  final Color textColor;

  static const double _topLabelHeight = 14;
  static const double _bottomAxisHeight = 20;

  @override
  void paint(Canvas canvas, Size size) {
    if (days.isEmpty) return;
    final chartRect = Rect.fromLTWH(
      0,
      _topLabelHeight,
      size.width,
      math.max(0, size.height - _topLabelHeight - _bottomAxisHeight),
    );
    if (chartRect.width <= 0 || chartRect.height <= 0) return;

    final totals = [for (final d in days) SleepTrendSummary.totalSleep(d)];
    final recorded = totals.where((d) => d > Duration.zero).toList();
    final averageMinutes = recorded.isEmpty
        ? 0
        : (recorded.fold<int>(0, (sum, d) => sum + d.inMinutes) /
                  recorded.length)
              .round();
    final maxMinutes = math.max(
      60,
      [
        averageMinutes,
        for (final d in totals) d.inMinutes,
      ].fold<int>(8 * 60, math.max),
    );

    final gridPaint = Paint()
      ..color = axisColor.withValues(alpha: 0.38)
      ..strokeWidth = 0.5;
    _paintGrid(canvas, chartRect, gridPaint, maxMinutes);
    if (averageMinutes > 0) {
      _paintAverageLine(canvas, chartRect, averageMinutes, maxMinutes);
    }
    _paintBars(canvas, chartRect, totals, maxMinutes);
  }

  void _paintGrid(
    Canvas canvas,
    Rect chartRect,
    Paint gridPaint,
    int maxMinutes,
  ) {
    for (final frac in [0.5, 1.0]) {
      final y = chartRect.bottom - frac * chartRect.height;
      canvas.drawLine(
        Offset(chartRect.left, y),
        Offset(chartRect.right, y),
        gridPaint,
      );
      _paintText(
        canvas,
        _formatDuration(Duration(minutes: (maxMinutes * frac).round())),
        Offset(0, y - 11),
        color: textColor.withValues(alpha: 0.6),
        size: kLabelSmall,
      );
    }
    canvas.drawLine(
      Offset(chartRect.left, chartRect.bottom),
      Offset(chartRect.right, chartRect.bottom),
      gridPaint,
    );
  }

  void _paintAverageLine(
    Canvas canvas,
    Rect chartRect,
    int averageMinutes,
    int maxMinutes,
  ) {
    final y = chartRect.bottom - averageMinutes / maxMinutes * chartRect.height;
    final paint = Paint()
      ..color = averageColor.withValues(alpha: 0.84)
      ..strokeWidth = 1.2;
    const dash = 6.0;
    const gap = 4.0;
    var x = chartRect.left;
    while (x < chartRect.right) {
      canvas.drawLine(
        Offset(x, y),
        Offset(math.min(x + dash, chartRect.right), y),
        paint,
      );
      x += dash + gap;
    }
    _paintText(
      canvas,
      'avg',
      Offset(chartRect.right - 20, y - 13),
      color: averageColor,
      size: kLabelSmall,
    );
  }

  void _paintBars(
    Canvas canvas,
    Rect chartRect,
    List<Duration> totals,
    int maxMinutes,
  ) {
    final today = DateOnly.today();
    final slot = chartRect.width / days.length;
    final barW = (slot * 0.58).clamp(3.0, 24.0);
    final paint = Paint()..style = PaintingStyle.fill;

    for (var i = 0; i < days.length; i++) {
      final day = days[i];
      final total = totals[i];
      final minutes = total.inMinutes;
      final centerX = chartRect.left + (i + 0.5) * slot;
      final height = minutes <= 0
          ? 1.0
          : (minutes / maxMinutes) * chartRect.height;
      paint.color = minutes <= 0
          ? axisColor.withValues(alpha: 0.48)
          : day.day == today
          ? todayColor
          : sleepColor;
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(
            centerX - barW / 2,
            chartRect.bottom - height,
            barW,
            height,
          ),
          Radius.circular(barW / 2),
        ),
        paint,
      );

      if (minutes > 0 && days.length <= 7) {
        final label = _compactDuration(total);
        final labelWidth = _measureText(label, size: kLabelSmall);
        _paintText(
          canvas,
          label,
          Offset(centerX - labelWidth / 2, chartRect.bottom - height - 13),
          color: textColor.withValues(alpha: 0.64),
          size: kLabelSmall,
        );
      }

      final weekday = _weekdayShort(day.day);
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

  String _formatDuration(Duration d) {
    final h = d.inMinutes ~/ 60;
    final m = d.inMinutes.remainder(60);
    if (m == 0) return '${h}h';
    return '${h}h ${m}m';
  }

  String _compactDuration(Duration d) {
    final minutes = d.inMinutes;
    final hours = minutes / 60;
    return '${hours.toStringAsFixed(hours >= 10 ? 0 : 1)}h';
  }

  static const _weekdays = ['Mo', 'Tu', 'We', 'Th', 'Fr', 'Sa', 'Su'];
  String _weekdayShort(DateOnly d) {
    final dt = DateTime(d.year, d.month, d.day);
    return _weekdays[dt.weekday - 1];
  }

  @override
  bool shouldRepaint(_SleepTrendPainter old) =>
      old.days != days ||
      old.sleepColor != sleepColor ||
      old.todayColor != todayColor ||
      old.averageColor != averageColor ||
      old.axisColor != axisColor ||
      old.textColor != textColor;
}
