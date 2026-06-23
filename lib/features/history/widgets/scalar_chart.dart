import 'package:flutter/material.dart';

import '../../../core/services/history_sync.dart';

/// Compact line chart for scalar day metrics such as stress and HRV.
class ScalarMetricChart extends StatelessWidget {
  const ScalarMetricChart({
    super.key,
    required this.samples,
    required this.color,
    this.minValue,
    this.maxValue,
    this.now,
  });

  final List<HealthMetricSample> samples;
  final Color color;
  final int? minValue;
  final int? maxValue;
  final DateTime? now;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cutoff = now ?? DateTime.now();
    final visible = [
      for (final sample in samples)
        if (!sample.timestamp.isAfter(cutoff)) sample,
    ];
    return CustomPaint(
      painter: _ScalarMetricPainter(
        samples: visible,
        color: color,
        axisColor: theme.colorScheme.outlineVariant,
        textColor: theme.colorScheme.onSurfaceVariant,
        minValue: minValue,
        maxValue: maxValue,
      ),
      child: const SizedBox.expand(),
    );
  }
}

class _ScalarMetricPainter extends CustomPainter {
  const _ScalarMetricPainter({
    required this.samples,
    required this.color,
    required this.axisColor,
    required this.textColor,
    this.minValue,
    this.maxValue,
  });

  final List<HealthMetricSample> samples;
  final Color color;
  final Color axisColor;
  final Color textColor;
  final int? minValue;
  final int? maxValue;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.width <= 0 || size.height <= 0) return;
    final rect = Rect.fromLTWH(34, 8, size.width - 42, size.height - 30);
    if (rect.width <= 0 || rect.height <= 0) return;

    final axis = Paint()
      ..color = axisColor
      ..strokeWidth = 1;
    canvas
      ..drawLine(rect.bottomLeft, rect.bottomRight, axis)
      ..drawLine(rect.bottomLeft, rect.topLeft, axis);

    if (samples.isEmpty) return;
    final values = samples.map((s) => s.value);
    var min = minValue ?? values.reduce((a, b) => a < b ? a : b);
    var max = maxValue ?? values.reduce((a, b) => a > b ? a : b);
    if (min == max) {
      min -= 1;
      max += 1;
    }

    _label(canvas, Offset(0, rect.top - 4), '$max');
    _label(canvas, Offset(0, rect.bottom - 10), '$min');
    _label(canvas, Offset(rect.left, rect.bottom + 6), '00');
    _label(canvas, Offset(rect.right - 18, rect.bottom + 6), '24');

    final sorted = samples.toList()
      ..sort((a, b) => a.timestamp.compareTo(b.timestamp));
    final path = Path();
    for (var i = 0; i < sorted.length; i++) {
      final sample = sorted[i];
      final minute = sample.timestamp.hour * 60 + sample.timestamp.minute;
      final x = rect.left + rect.width * (minute / (24 * 60));
      final y =
          rect.bottom -
          rect.height * ((sample.value - min) / (max - min)).clamp(0.0, 1.0);
      if (i == 0) {
        path.moveTo(x, y);
      } else {
        path.lineTo(x, y);
      }
    }
    final line = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    canvas.drawPath(path, line);

    final dot = Paint()..color = color;
    for (final sample in sorted) {
      final minute = sample.timestamp.hour * 60 + sample.timestamp.minute;
      final x = rect.left + rect.width * (minute / (24 * 60));
      final y =
          rect.bottom -
          rect.height * ((sample.value - min) / (max - min)).clamp(0.0, 1.0);
      canvas.drawCircle(Offset(x, y), 2.5, dot);
    }
  }

  void _label(Canvas canvas, Offset offset, String text) {
    final painter = TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(color: textColor, fontSize: 10),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    painter.paint(canvas, offset);
  }

  @override
  bool shouldRepaint(covariant _ScalarMetricPainter oldDelegate) {
    return oldDelegate.samples != samples ||
        oldDelegate.color != color ||
        oldDelegate.axisColor != axisColor ||
        oldDelegate.textColor != textColor ||
        oldDelegate.minValue != minValue ||
        oldDelegate.maxValue != maxValue;
  }
}
