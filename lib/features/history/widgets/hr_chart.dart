import 'package:flutter/material.dart';

import '../../../core/services/history_sync.dart';

/// Full-width heart-rate line chart for one day.
///
/// Renders the day's HR samples as a smoothed line + soft fill, with a
/// left-edge BPM axis (40..200) and a bottom-edge hour-of-day axis.
/// The chart tolerates sparse / missing data — gaps are skipped rather
/// than drawn as 0, which would be misleading (a 0 BPM is not a real
/// reading, the watch reports `0xff` for empty slots and we filter
/// those out before they reach this widget).
///
/// The widget is pure presentation — it does not own the data, only
/// paints what it's given. This keeps it cheap to rebuild on every
/// `setState` and trivially testable.
class HrLineChart extends StatelessWidget {
  const HrLineChart({
    super.key,
    required this.samples,
    this.minBpm = 40,
    this.maxBpm = 200,
    this.showAxes = true,
  });

  final List<HrSample> samples;
  final int minBpm;
  final int maxBpm;
  final bool showAxes;

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      painter: _HrPainter(
        samples: samples,
        color: Theme.of(context).colorScheme.primary,
        axisColor: Theme.of(context).colorScheme.outlineVariant,
        textColor: Theme.of(context).colorScheme.onSurfaceVariant,
        minBpm: minBpm.toDouble(),
        maxBpm: maxBpm.toDouble(),
        showAxes: showAxes,
      ),
      size: Size.infinite,
    );
  }
}

/// Tiny heart-rate sparkline for a day-summary card.
///
/// No axes, no labels — just a thin filled line. Designed to fit a
/// ~64 px-tall card row.
class MiniHrSpark extends StatelessWidget {
  const MiniHrSpark({super.key, required this.samples, this.height = 48});
  final List<HrSample> samples;
  final double height;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: height,
      child: CustomPaint(
        painter: _HrPainter(
          samples: samples,
          color: Theme.of(context).colorScheme.primary,
          axisColor: Colors.transparent,
          textColor: Colors.transparent,
          minBpm: 40,
          maxBpm: 200,
          showAxes: false,
        ),
        size: Size.infinite,
      ),
    );
  }
}

class _HrPainter extends CustomPainter {
  _HrPainter({
    required this.samples,
    required this.color,
    required this.axisColor,
    required this.textColor,
    required this.minBpm,
    required this.maxBpm,
    required this.showAxes,
  });

  final List<HrSample> samples;
  final Color color;
  final Color axisColor;
  final Color textColor;
  final double minBpm;
  final double maxBpm;
  final bool showAxes;

  // Chart geometry: leave room for the BPM axis on the left and the
  // hour labels along the bottom when axes are visible.
  static const double _leftAxisWidth = 36;
  static const double _bottomAxisHeight = 18;

  @override
  void paint(Canvas canvas, Size size) {
    if (samples.isEmpty) {
      _paintEmpty(canvas, size);
      return;
    }

    final chartRect = showAxes
        ? Rect.fromLTWH(
            _leftAxisWidth,
            4,
            size.width - _leftAxisWidth - 4,
            size.height - _bottomAxisHeight - 4,
          )
        : Rect.fromLTWH(0, 0, size.width, size.height);

    if (showAxes) _paintAxes(canvas, size, chartRect);

    final linePaint = Paint()
      ..color = color
      ..strokeWidth = 1.6
      ..style = PaintingStyle.stroke
      ..strokeJoin = StrokeJoin.round
      ..strokeCap = StrokeCap.round;
    final fillPaint = Paint()
      ..color = color.withValues(alpha: 0.15)
      ..style = PaintingStyle.fill;

    // The day boundary is whichever midnight the first sample falls
    // after (UTC samples land inside the user's day when
    // displayed in local time — `HrSample.timestamp` is already
    // local). Plot from 00:00 to 24:00 regardless of when the
    // first / last sample actually arrived.
    final first = samples.first.timestamp;
    final dayStart = DateTime(first.year, first.month, first.day);
    final dayEnd = dayStart.add(const Duration(days: 1));
    final dayMs =
        dayEnd.millisecondsSinceEpoch - dayStart.millisecondsSinceEpoch;

    final path = Path();
    final fillPath = Path();
    bool started = false;

    for (var i = 0; i < samples.length; i++) {
      final s = samples[i];
      // Out-of-range BPM clamps — guard against pathological data.
      final clamped = s.bpm.clamp(minBpm.toInt(), maxBpm.toInt()).toDouble();
      final t =
          (s.timestamp.millisecondsSinceEpoch -
              dayStart.millisecondsSinceEpoch) /
          dayMs;
      final x = chartRect.left + t * chartRect.width;
      final yNorm = (clamped - minBpm) / (maxBpm - minBpm);
      final y = chartRect.bottom - yNorm * chartRect.height;
      if (!started) {
        path.moveTo(x, y);
        fillPath.moveTo(x, chartRect.bottom);
        fillPath.lineTo(x, y);
        started = true;
      } else {
        path.lineTo(x, y);
        fillPath.lineTo(x, y);
      }
    }
    if (started) {
      fillPath.lineTo(chartRect.right, chartRect.bottom);
      fillPath.close();
      canvas.drawPath(fillPath, fillPaint);
      canvas.drawPath(path, linePaint);
    }
  }

  void _paintEmpty(Canvas canvas, Size size) {
    if (!showAxes) return;
    final tp = TextPainter(
      text: TextSpan(
        text: 'No data',
        style: TextStyle(color: textColor.withValues(alpha: 0.6), fontSize: 12),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(
      canvas,
      Offset((size.width - tp.width) / 2, (size.height - tp.height) / 2),
    );
  }

  void _paintAxes(Canvas canvas, Size size, Rect chartRect) {
    final gridPaint = Paint()
      ..color = axisColor
      ..strokeWidth = 0.5;

    // Horizontal BPM gridlines at 60, 100, 140, 180.
    for (final bpm in [60.0, 100.0, 140.0, 180.0]) {
      final yNorm = (bpm - minBpm) / (maxBpm - minBpm);
      final y = chartRect.bottom - yNorm * chartRect.height;
      canvas.drawLine(
        Offset(chartRect.left, y),
        Offset(chartRect.right, y),
        gridPaint,
      );
      _paintText(canvas, bpm.toInt().toString(), Offset(2, y - 7), size: 10);
    }
    // Bottom axis baseline.
    canvas.drawLine(
      Offset(chartRect.left, chartRect.bottom),
      Offset(chartRect.right, chartRect.bottom),
      gridPaint,
    );
    // Hour labels at 0, 6, 12, 18, 24.
    for (final hour in [0, 6, 12, 18, 24]) {
      final x = chartRect.left + (hour / 24) * chartRect.width;
      _paintText(
        canvas,
        '$hour',
        Offset(x - 6, chartRect.bottom + 4),
        size: 10,
      );
    }
  }

  void _paintText(Canvas canvas, String text, Offset at, {double size = 11}) {
    final tp = TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(color: textColor, fontSize: size),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(canvas, at);
  }

  @override
  bool shouldRepaint(_HrPainter old) =>
      old.samples != samples ||
      old.color != color ||
      old.minBpm != minBpm ||
      old.maxBpm != maxBpm ||
      old.showAxes != showAxes;
}
