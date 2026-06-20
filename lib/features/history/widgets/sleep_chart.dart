import 'package:flutter/material.dart';

import '../../../core/protocol/sleep_parser.dart';

/// Horizontal sleep timeline — one row per [SleepStage] showing the
/// cumulative minutes spent in each stage, with hour-of-day ticks along
/// the bottom.
///
/// The chart expects segments from a single day; multi-day data should
/// be split upstream and rendered as one row per day (or use the
/// dashboard's per-day summary cards instead).
class SleepTimeline extends StatelessWidget {
  const SleepTimeline({super.key, required this.segments, this.height = 64});

  final List<SleepSegment> segments;
  final double height;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: height,
      child: CustomPaint(
        painter: _SleepPainter(
          segments: segments,
          // Material 3 tonal palette per stage — picked for
          // distinguishable hues at small sizes.
          colors: {
            SleepStage.awake: const Color(0xFFE57373),
            SleepStage.rem: const Color(0xFF7E57C2),
            SleepStage.light: const Color(0xFF64B5F6),
            SleepStage.deep: const Color(0xFF1E88E5),
          },
          axisColor: Theme.of(context).colorScheme.outlineVariant,
          textColor: Theme.of(context).colorScheme.onSurfaceVariant,
        ),
        size: Size.infinite,
      ),
    );
  }
}

class _SleepPainter extends CustomPainter {
  _SleepPainter({
    required this.segments,
    required this.colors,
    required this.axisColor,
    required this.textColor,
  });

  final List<SleepSegment> segments;
  final Map<SleepStage, Color> colors;
  final Color axisColor;
  final Color textColor;

  static const double _bottomAxisHeight = 18;

  @override
  void paint(Canvas canvas, Size size) {
    if (segments.isEmpty) {
      _paintEmpty(canvas, size);
      return;
    }

    final chartRect = Rect.fromLTWH(
      0,
      4,
      size.width,
      size.height - _bottomAxisHeight - 4,
    );
    final first = segments.first.start;
    final dayStart = DateTime(first.year, first.month, first.day);
    final dayEnd = dayStart.add(const Duration(days: 1));
    final dayMs =
        dayEnd.millisecondsSinceEpoch - dayStart.millisecondsSinceEpoch;

    final paint = Paint()..style = PaintingStyle.fill;

    // One lane per stage, stacked top → bottom: awake → REM → light → deep.
    const lanes = [
      SleepStage.awake,
      SleepStage.rem,
      SleepStage.light,
      SleepStage.deep,
    ];
    final laneH = chartRect.height / lanes.length;

    for (var i = 0; i < segments.length; i++) {
      final s = segments[i];
      final lane = lanes.indexOf(s.stage);
      if (lane < 0) continue;
      final startMs =
          s.start.millisecondsSinceEpoch - dayStart.millisecondsSinceEpoch;
      final endMs = startMs + s.duration.inMilliseconds;
      final x0 = chartRect.left + (startMs / dayMs) * chartRect.width;
      final x1 = chartRect.left + (endMs / dayMs) * chartRect.width;
      final y = chartRect.top + lane * laneH + 2;
      paint.color = colors[s.stage] ?? Colors.blueGrey;
      final rect = RRect.fromRectAndRadius(
        Rect.fromLTRB(x0, y, x1, y + laneH - 4),
        const Radius.circular(2),
      );
      canvas.drawRRect(rect, paint);
    }

    // Lane labels at the left.
    final textStyle = TextStyle(color: textColor, fontSize: 9);
    for (var i = 0; i < lanes.length; i++) {
      final tp = TextPainter(
        text: TextSpan(text: _label(lanes[i]), style: textStyle),
        textDirection: TextDirection.ltr,
      )..layout();
      // Background swatch + label, anchored to the lane top.
      final y = chartRect.top + i * laneH + 2;
      final swatchPaint = Paint()..color = colors[lanes[i]] ?? Colors.blueGrey;
      canvas.drawRect(Rect.fromLTWH(0, y, 3, laneH - 4), swatchPaint);
      tp.paint(canvas, Offset(6, y + (laneH - 4 - tp.height) / 2));
    }

    // Hour ticks.
    final gridPaint = Paint()
      ..color = axisColor
      ..strokeWidth = 0.5;
    canvas.drawLine(
      Offset(chartRect.left, chartRect.bottom),
      Offset(chartRect.right, chartRect.bottom),
      gridPaint,
    );
    for (final hour in [0, 3, 6, 9, 12, 15, 18, 21, 24]) {
      final x = chartRect.left + (hour / 24) * chartRect.width;
      _paintText(
        canvas,
        '$hour',
        Offset(x - 6, chartRect.bottom + 4),
        size: 10,
        color: textColor,
      );
    }
  }

  void _paintEmpty(Canvas canvas, Size size) {
    final tp = TextPainter(
      text: TextSpan(
        text: 'No sleep data',
        style: TextStyle(color: textColor.withValues(alpha: 0.6), fontSize: 12),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(
      canvas,
      Offset((size.width - tp.width) / 2, (size.height - tp.height) / 2),
    );
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

  String _label(SleepStage s) => switch (s) {
    SleepStage.awake => 'Awake',
    SleepStage.rem => 'REM',
    SleepStage.light => 'Light',
    SleepStage.deep => 'Deep',
  };

  @override
  bool shouldRepaint(_SleepPainter old) =>
      old.segments != segments || old.colors != colors;
}
