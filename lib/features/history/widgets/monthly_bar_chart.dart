import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../core/services/monthly_trends.dart';
import '../../../core/ui/ui_constants.dart';

/// One plotted month: the bar height value plus the label shown on top.
@immutable
class MonthlyBar {
  const MonthlyBar({
    required this.month,
    required this.value,
    required this.label,
    this.isCurrent = false,
  });

  final MonthKey month;

  /// Non-negative magnitude; <= 0 renders a placeholder stub.
  final double value;

  /// Compact value label drawn above the bar (e.g. "8.2k", "7h").
  final String label;

  final bool isCurrent;
}

/// Vertical bar chart of a single metric across a handful of months.
///
/// Sibling to [StepsBarChart] but keyed on months rather than days: the
/// x-axis labels are month abbreviations and the current month is tinted so
/// it reads as "in progress" against completed months.
class MonthlyBarChart extends StatelessWidget {
  const MonthlyBarChart({
    super.key,
    required this.bars,
    this.height = 140,
    this.barColor,
    this.averageValue,
  });

  final List<MonthlyBar> bars;
  final double height;
  final Color? barColor;

  /// Optional dashed reference line (e.g. mean across the window).
  final double? averageValue;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final effectiveColor = barColor ?? theme.colorScheme.primary;
    if (bars.isEmpty) {
      return SizedBox(
        height: height,
        child: Center(
          child: Text(
            'No monthly data',
            style: AppTextStyles.bodySmall(
              context,
            )?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
        ),
      );
    }
    return SizedBox(
      height: height,
      child: CustomPaint(
        painter: _MonthlyBarPainter(
          bars: bars,
          barColor: effectiveColor,
          todayColor: theme.colorScheme.tertiary,
          averageColor: theme.colorScheme.secondary,
          axisColor: theme.colorScheme.outlineVariant,
          textColor: theme.colorScheme.onSurfaceVariant,
          averageValue: averageValue,
        ),
        size: Size.infinite,
      ),
    );
  }
}

class _MonthlyBarPainter extends CustomPainter {
  _MonthlyBarPainter({
    required this.bars,
    required this.barColor,
    required this.todayColor,
    required this.averageColor,
    required this.axisColor,
    required this.textColor,
    required this.averageValue,
  });

  final List<MonthlyBar> bars;
  final Color barColor;
  final Color todayColor;
  final Color averageColor;
  final Color axisColor;
  final Color textColor;
  final double? averageValue;

  static const double _topLabelHeight = 16;
  static const double _bottomAxisHeight = 18;

  static const _monthShort = [
    'Jan',
    'Feb',
    'Mar',
    'Apr',
    'May',
    'Jun',
    'Jul',
    'Aug',
    'Sep',
    'Oct',
    'Nov',
    'Dec',
  ];

  @override
  void paint(Canvas canvas, Size size) {
    if (bars.isEmpty) return;
    final chartRect = Rect.fromLTWH(
      0,
      _topLabelHeight,
      size.width,
      math.max(0, size.height - _bottomAxisHeight - _topLabelHeight),
    );
    if (chartRect.width <= 0 || chartRect.height <= 0) return;

    final maxValue = [
      averageValue ?? 0,
      for (final b in bars) b.value,
    ].fold<double>(1.0, math.max);

    final gridPaint = Paint()
      ..color = axisColor.withValues(alpha: 0.32)
      ..strokeWidth = 0.5;
    canvas.drawLine(
      Offset(chartRect.left, chartRect.bottom),
      Offset(chartRect.right, chartRect.bottom),
      gridPaint,
    );

    if (averageValue != null && averageValue! > 0) {
      final y =
          chartRect.bottom - (averageValue! / maxValue) * chartRect.height;
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
      );
    }

    final slot = chartRect.width / bars.length;
    final barW = (slot * 0.56).clamp(3.0, 32.0);
    final fill = Paint()..style = PaintingStyle.fill;

    for (var i = 0; i < bars.length; i++) {
      final bar = bars[i];
      final centerX = chartRect.left + (i + 0.5) * slot;
      final h = bar.value <= 0
          ? 1.0
          : (bar.value / maxValue) * chartRect.height;
      fill.color = bar.value <= 0
          ? axisColor.withValues(alpha: 0.48)
          : bar.isCurrent
          ? todayColor
          : barColor;
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(centerX - barW / 2, chartRect.bottom - h, barW, h),
          Radius.circular(barW / 2),
        ),
        fill,
      );

      if (bar.value > 0) {
        final labelWidth = _measureText(bar.label);
        _paintText(
          canvas,
          bar.label,
          Offset(centerX - labelWidth / 2, chartRect.bottom - h - 14),
          color: textColor.withValues(alpha: 0.64),
        );
      }

      final monthLabel = _monthShort[bar.month.month - 1];
      final mw = _measureText(monthLabel);
      _paintText(
        canvas,
        monthLabel,
        Offset(centerX - mw / 2, chartRect.bottom + 5),
        color: textColor.withValues(alpha: 0.72),
      );
    }
  }

  double _measureText(String text) {
    final tp = TextPainter(
      text: TextSpan(
        text: text,
        style: const TextStyle(
          fontSize: kLabelSmall,
          height: 1.0,
          letterSpacing: 0,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    return tp.width;
  }

  void _paintText(
    Canvas canvas,
    String text,
    Offset at, {
    required Color color,
  }) {
    final tp = TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(
          color: color,
          fontSize: kLabelSmall,
          height: 1.0,
          letterSpacing: 0,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(canvas, at);
  }

  @override
  bool shouldRepaint(_MonthlyBarPainter old) =>
      old.bars != bars ||
      old.barColor != barColor ||
      old.averageValue != averageValue ||
      old.todayColor != todayColor ||
      old.averageColor != averageColor;
}
