import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../core/services/history_sync.dart';
import '../../../core/ui/ui_constants.dart';

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
class HrLineChart extends StatefulWidget {
  const HrLineChart({
    super.key,
    required this.samples,
    this.minBpm = 40,
    this.maxBpm = 200,
    this.showAxes = true,
    this.now,
    this.color,
  });

  final List<HrSample> samples;
  final int minBpm;
  final int maxBpm;
  final bool showAxes;
  final DateTime? now;
  final Color? color;

  @override
  State<HrLineChart> createState() => _HrLineChartState();
}

class _HrLineChartState extends State<HrLineChart> {
  static const double _minSpan = 1 / 24; // one hour

  double _viewStart = 0;
  double _viewEnd = 1;
  double _scaleStartStart = 0;
  double _scaleStartEnd = 1;
  HrSample? _selected;

  @override
  void didUpdateWidget(HrLineChart oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.samples != widget.samples) {
      _viewStart = 0;
      _viewEnd = _maxViewEnd(widget.samples, widget.now ?? DateTime.now());
      _selected = null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = widget.color ?? theme.colorScheme.primary;
    // Build one chart data set and use it for paint, hit-testing, badges, and
    // scroll limits. Otherwise future fixed-slot watch records can be hidden
    // visually while still being selectable.
    final now = widget.now ?? DateTime.now();
    final visible = _visibleSamples(widget.samples, now);
    final maxViewEnd = _maxViewEnd(widget.samples, now);
    final viewStart = _viewStart.clamp(0.0, maxViewEnd);
    final viewEnd = _viewEnd.clamp(viewStart, maxViewEnd);
    final selected = _selectedVisibleIn(_selected, visible);
    return LayoutBuilder(
      builder: (context, constraints) {
        final size = Size(
          constraints.maxWidth,
          constraints.maxHeight.isFinite ? constraints.maxHeight : 184,
        );
        return Stack(
          children: [
            Positioned.fill(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTapDown: (details) =>
                    _selectNearest(details.localPosition, size),
                onScaleStart: (details) {
                  _scaleStartStart = _viewStart;
                  _scaleStartEnd = _viewEnd;
                  if (details.pointerCount <= 1) {
                    _selectNearest(details.localFocalPoint, size);
                  }
                },
                onScaleUpdate: (details) => _handleScaleUpdate(details, size),
                child: ClipRect(
                  child: CustomPaint(
                    painter: _HrPainter(
                      samples: visible,
                      color: color,
                      axisColor: theme.colorScheme.outlineVariant,
                      textColor: theme.colorScheme.onSurfaceVariant,
                      minBpm: widget.minBpm.toDouble(),
                      maxBpm: widget.maxBpm.toDouble(),
                      showAxes: widget.showAxes,
                      viewStart: viewStart,
                      viewEnd: viewEnd,
                      selected: selected,
                    ),
                    size: Size.infinite,
                  ),
                ),
              ),
            ),
            if (widget.showAxes && selected != null)
              Positioned(
                top: 8,
                right: 8,
                child: _PointBadge(sample: selected),
              ),
            if (widget.showAxes && widget.samples.isNotEmpty)
              Positioned(
                right: 6,
                bottom: 22,
                child: _ChartControls(
                  onZoomOut: () => _zoom(1.8),
                  onReset: _resetView,
                  onZoomIn: () => _zoom(0.55),
                ),
              ),
          ],
        );
      },
    );
  }

  void _handleScaleUpdate(ScaleUpdateDetails details, Size size) {
    final chartRect = _HrPainter.chartRectFor(size, widget.showAxes);
    if (chartRect.width <= 0) return;
    final startSpan = _scaleStartEnd - _scaleStartStart;
    if (details.pointerCount > 1 && (details.scale - 1).abs() > 0.01) {
      final focal =
          ((details.localFocalPoint.dx - chartRect.left) / chartRect.width)
              .clamp(0.0, 1.0);
      final anchor = _scaleStartStart + startSpan * focal;
      final maxViewEnd = _maxViewEnd(
        widget.samples,
        widget.now ?? DateTime.now(),
      );
      final minSpan = _minSpanFor(maxViewEnd);
      final nextSpan = (startSpan / details.scale).clamp(minSpan, maxViewEnd);
      _setRange(
        anchor - nextSpan * focal,
        anchor + nextSpan * (1 - focal),
        maxViewEnd: maxViewEnd,
      );
      return;
    }
    if (details.pointerCount <= 1) {
      _selectNearest(details.localFocalPoint, size);
      return;
    }
    final delta =
        -details.focalPointDelta.dx / chartRect.width * (_viewEnd - _viewStart);
    if (delta.abs() > 0.0001) {
      _setRange(_viewStart + delta, _viewEnd + delta);
    }
  }

  void _selectNearest(Offset position, Size size) {
    final now = widget.now ?? DateTime.now();
    final samples = _visibleSamples(widget.samples, now);
    if (samples.isEmpty) return;
    final chartRect = _HrPainter.chartRectFor(size, widget.showAxes);
    if (!chartRect.contains(position)) return;
    final maxViewEnd = _maxViewEnd(widget.samples, now);
    final viewStart = _viewStart.clamp(0.0, maxViewEnd);
    final viewEnd = _viewEnd.clamp(viewStart, maxViewEnd);
    final target =
        viewStart +
        ((position.dx - chartRect.left) / chartRect.width) *
            (viewEnd - viewStart);
    HrSample? best;
    var bestDistance = double.infinity;
    for (final sample in samples) {
      final fraction = _HrPainter.dayFraction(sample.timestamp, samples);
      if (fraction < viewStart || fraction > viewEnd) continue;
      final distance = (fraction - target).abs();
      if (distance < bestDistance) {
        best = sample;
        bestDistance = distance;
      }
    }
    if (best != null) {
      _selectSample(best);
    }
  }

  void _selectSample(HrSample sample) {
    final current = _selected;
    if (current?.timestamp == sample.timestamp && current?.bpm == sample.bpm) {
      return;
    }
    HapticFeedback.lightImpact();
    setState(() => _selected = sample);
  }

  void _zoom(double factor) {
    final center = (_viewStart + _viewEnd) / 2;
    final maxViewEnd = _maxViewEnd(
      widget.samples,
      widget.now ?? DateTime.now(),
    );
    final minSpan = _minSpanFor(maxViewEnd);
    final nextSpan = ((_viewEnd - _viewStart) * factor).clamp(
      minSpan,
      maxViewEnd,
    );
    _setRange(
      center - nextSpan / 2,
      center + nextSpan / 2,
      maxViewEnd: maxViewEnd,
    );
  }

  void _resetView() {
    final maxViewEnd = _maxViewEnd(
      widget.samples,
      widget.now ?? DateTime.now(),
    );
    setState(() {
      _viewStart = 0;
      _viewEnd = maxViewEnd;
      _selected = null;
    });
  }

  void _setRange(double start, double end, {double? maxViewEnd}) {
    final maxEnd =
        maxViewEnd ?? _maxViewEnd(widget.samples, widget.now ?? DateTime.now());
    final minSpan = _minSpanFor(maxEnd);
    final span = end - start;
    if (span >= maxEnd) {
      setState(() {
        _viewStart = 0;
        _viewEnd = maxEnd;
      });
      return;
    }
    var nextStart = start;
    var nextEnd = end;
    if (nextStart < 0) {
      nextEnd -= nextStart;
      nextStart = 0;
    }
    if (nextEnd > maxEnd) {
      nextStart -= nextEnd - maxEnd;
      nextEnd = maxEnd;
    }
    nextStart = nextStart.clamp(0.0, math.max(0.0, maxEnd - minSpan));
    nextEnd = nextEnd.clamp(nextStart + minSpan, maxEnd);
    setState(() {
      _viewStart = nextStart;
      _viewEnd = nextEnd;
    });
  }

  static double _minSpanFor(double maxViewEnd) {
    return math.min(_minSpan, math.max(1 / (24 * 12), maxViewEnd));
  }

  static double _maxViewEnd(List<HrSample> samples, DateTime now) {
    if (samples.isEmpty) return 1;
    final first = samples.first.timestamp;
    final dayStart = DateTime(first.year, first.month, first.day);
    final todayStart = DateTime(now.year, now.month, now.day);
    if (dayStart != todayStart) return 1;
    final dayEnd = dayStart.add(const Duration(days: 1));
    final dayMs =
        dayEnd.millisecondsSinceEpoch - dayStart.millisecondsSinceEpoch;
    final elapsedMs =
        now.millisecondsSinceEpoch - dayStart.millisecondsSinceEpoch;
    return (elapsedMs / dayMs).clamp(1 / (24 * 12), 1.0);
  }

  static List<HrSample> _visibleSamples(List<HrSample> samples, DateTime now) {
    final bySlot = <int, HrSample>{};
    for (final sample in samples) {
      final snapped = _snapToSlot(sample.timestamp);
      if (snapped.isAfter(now)) continue;
      final key = snapped.millisecondsSinceEpoch;
      final existing = bySlot[key];
      if (existing == null || sample.timestamp.isAfter(existing.timestamp)) {
        bySlot[key] = HrSample(snapped, sample.bpm);
      }
    }
    return bySlot.values.toList()
      ..sort((a, b) => a.timestamp.compareTo(b.timestamp));
  }

  static HrSample? _selectedVisibleIn(
    HrSample? selected,
    List<HrSample> visible,
  ) {
    if (selected == null) return null;
    final snapped = _snapToSlot(selected.timestamp);
    for (final sample in visible) {
      if (sample.timestamp == snapped && sample.bpm == selected.bpm) {
        return sample;
      }
    }
    return null;
  }

  static DateTime _snapToSlot(DateTime t) =>
      DateTime(t.year, t.month, t.day, t.hour, (t.minute ~/ 5) * 5);
}

/// Tiny heart-rate sparkline for a day-summary card.
///
/// No axes, no labels — just a thin filled line. Designed to fit a
/// ~64 px-tall card row.
class MiniHrSpark extends StatelessWidget {
  const MiniHrSpark({
    super.key,
    required this.samples,
    this.height = 48,
    this.now,
    this.color,
  });
  final List<HrSample> samples;
  final double height;
  final DateTime? now;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final visible = _HrLineChartState._visibleSamples(
      samples,
      now ?? DateTime.now(),
    );
    return SizedBox(
      height: height,
      child: CustomPaint(
        painter: _HrPainter(
          samples: visible,
          color: color ?? theme.colorScheme.primary,
          axisColor: Colors.transparent,
          textColor: Colors.transparent,
          minBpm: 40,
          maxBpm: 200,
          showAxes: false,
          viewStart: 0,
          viewEnd: 1,
          selected: null,
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
    required this.viewStart,
    required this.viewEnd,
    required this.selected,
  });

  final List<HrSample> samples;
  final Color color;
  final Color axisColor;
  final Color textColor;
  final double minBpm;
  final double maxBpm;
  final bool showAxes;
  final double viewStart;
  final double viewEnd;
  final HrSample? selected;

  // Chart geometry: leave room for the BPM axis on the left and the
  // hour labels along the bottom when axes are visible.
  static const double _leftAxisWidth = 36;
  static const double _bottomAxisHeight = 18;

  static Rect chartRectFor(Size size, bool showAxes) {
    if (!showAxes) return Rect.fromLTWH(0, 0, size.width, size.height);
    return Rect.fromLTWH(
      _leftAxisWidth,
      4,
      math.max(0, size.width - _leftAxisWidth - 4),
      math.max(0, size.height - _bottomAxisHeight - 4),
    );
  }

  static double dayFraction(DateTime timestamp, List<HrSample> samples) {
    if (samples.isEmpty) return 0;
    final first = samples.first.timestamp;
    final dayStart = DateTime(first.year, first.month, first.day);
    final dayEnd = dayStart.add(const Duration(days: 1));
    final dayMs =
        dayEnd.millisecondsSinceEpoch - dayStart.millisecondsSinceEpoch;
    return (timestamp.millisecondsSinceEpoch -
            dayStart.millisecondsSinceEpoch) /
        dayMs;
  }

  @override
  void paint(Canvas canvas, Size size) {
    if (samples.isEmpty) {
      _paintEmpty(canvas, size);
      return;
    }

    final chartRect = chartRectFor(size, showAxes);
    if (chartRect.width <= 0 || chartRect.height <= 0) return;

    if (showAxes) _paintAxes(canvas, size, chartRect);

    final linePaint = Paint()
      ..color = color
      ..strokeWidth = showAxes ? 2.2 : 1.8
      ..style = PaintingStyle.stroke
      ..strokeJoin = StrokeJoin.round
      ..strokeCap = StrokeCap.round;
    final fillPaint = Paint()
      ..color = color.withValues(alpha: showAxes ? 0.12 : 0.10)
      ..style = PaintingStyle.fill;

    final span = math.max(_HrLineChartState._minSpan, viewEnd - viewStart);

    final path = Path();
    final fillPath = Path();
    bool started = false;
    Offset? lastPoint;

    canvas.save();
    canvas.clipRect(chartRect);
    for (var i = 0; i < samples.length; i++) {
      final s = samples[i];
      // Out-of-range BPM clamps — guard against pathological data.
      final clamped = s.bpm.clamp(minBpm.toInt(), maxBpm.toInt()).toDouble();
      final absoluteT = dayFraction(s.timestamp, samples);
      if (absoluteT < viewStart || absoluteT > viewEnd) continue;
      final t = (absoluteT - viewStart) / span;
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
      lastPoint = Offset(x, y);
    }
    if (started) {
      fillPath.lineTo(lastPoint!.dx, chartRect.bottom);
      fillPath.close();
      canvas.drawPath(fillPath, fillPaint);
      canvas.drawPath(path, linePaint);
    }
    final selectedPoint = _pointFor(selected, chartRect, span);
    if (showAxes && selectedPoint != null) {
      final markerPaint = Paint()..color = color;
      canvas.drawLine(
        Offset(selectedPoint.dx, chartRect.top),
        Offset(selectedPoint.dx, chartRect.bottom),
        Paint()
          ..color = color.withValues(alpha: 0.22)
          ..strokeWidth = 1,
      );
      canvas.drawCircle(selectedPoint, 5.5, markerPaint);
      canvas.drawCircle(
        selectedPoint,
        2.4,
        Paint()..color = const Color(0xFFFFFFFF),
      );
    } else if (showAxes && lastPoint != null) {
      canvas.drawCircle(lastPoint, 4.5, Paint()..color = color);
      canvas.drawCircle(
        lastPoint,
        2.2,
        Paint()..color = const Color(0xFFFFFFFF),
      );
    }
    canvas.restore();
  }

  void _paintEmpty(Canvas canvas, Size size) {
    if (!showAxes) return;
    final tp = TextPainter(
      text: TextSpan(
        text: 'No data',
        style: TextStyle(
          color: textColor.withValues(alpha: 0.54),
          fontSize: kBodySmall,
        ),
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
      ..color = axisColor.withValues(alpha: 0.48)
      ..strokeWidth = 0.5;

    // Horizontal BPM gridlines at calm, readable intervals.
    for (final bpm in [60.0, 100.0, 140.0]) {
      final yNorm = (bpm - minBpm) / (maxBpm - minBpm);
      final y = chartRect.bottom - yNorm * chartRect.height;
      canvas.drawLine(
        Offset(chartRect.left, y),
        Offset(chartRect.right, y),
        gridPaint,
      );
      _paintText(
        canvas,
        bpm.toInt().toString(),
        Offset(2, y - 7),
        size: kLabelSmall,
      );
    }
    // Bottom axis baseline.
    canvas.drawLine(
      Offset(chartRect.left, chartRect.bottom),
      Offset(chartRect.right, chartRect.bottom),
      gridPaint,
    );
    // Hour labels follow the current viewport.
    for (var i = 0; i < 5; i++) {
      final frac = viewStart + (viewEnd - viewStart) * (i / 4);
      final x = chartRect.left + (i / 4) * chartRect.width;
      _paintText(
        canvas,
        _formatHourFraction(frac),
        Offset(x - 6, chartRect.bottom + 4),
        size: kLabelSmall,
      );
    }
  }

  Offset? _pointFor(HrSample? sample, Rect chartRect, double span) {
    if (sample == null) return null;
    final absoluteT = dayFraction(sample.timestamp, samples);
    if (absoluteT < viewStart || absoluteT > viewEnd) return null;
    final t = (absoluteT - viewStart) / span;
    final clamped = sample.bpm.clamp(minBpm.toInt(), maxBpm.toInt()).toDouble();
    final yNorm = (clamped - minBpm) / (maxBpm - minBpm);
    return Offset(
      chartRect.left + t * chartRect.width,
      chartRect.bottom - yNorm * chartRect.height,
    );
  }

  String _formatHourFraction(double fraction) {
    final minutes = (fraction.clamp(0.0, 1.0) * 24 * 60).round();
    final h = (minutes ~/ 60).clamp(0, 24);
    final m = minutes.remainder(60);
    if (m == 0) return h == 24 ? '24' : '${h}h';
    return '${h.toString().padLeft(2, '0')}:${m.toString().padLeft(2, '0')}';
  }

  void _paintText(
    Canvas canvas,
    String text,
    Offset at, {
    double size = kLabelSmall,
  }) {
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
      old.showAxes != showAxes ||
      old.viewStart != viewStart ||
      old.viewEnd != viewEnd ||
      old.selected != selected;
}

class _PointBadge extends StatelessWidget {
  const _PointBadge({required this.sample});

  final HrSample sample;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest.withValues(
          alpha: 0.88,
        ),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: theme.colorScheme.outlineVariant),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        child: Text(
          '${_clock(sample.timestamp)}  ${sample.bpm} bpm',
          style: theme.textTheme.labelMedium,
        ),
      ),
    );
  }

  static String _clock(DateTime t) =>
      '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
}

class _ChartControls extends StatelessWidget {
  const _ChartControls({
    required this.onZoomOut,
    required this.onReset,
    required this.onZoomIn,
  });

  final VoidCallback onZoomOut;
  final VoidCallback onReset;
  final VoidCallback onZoomIn;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: theme.colorScheme.surface.withValues(alpha: 0.8),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: theme.colorScheme.outlineVariant),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _ChartIconButton(
            icon: Icons.remove_rounded,
            tooltip: 'Zoom out',
            onPressed: onZoomOut,
          ),
          _ChartIconButton(
            icon: Icons.center_focus_strong_rounded,
            tooltip: 'Reset view',
            onPressed: onReset,
          ),
          _ChartIconButton(
            icon: Icons.add_rounded,
            tooltip: 'Zoom in',
            onPressed: onZoomIn,
          ),
        ],
      ),
    );
  }
}

class _ChartIconButton extends StatelessWidget {
  const _ChartIconButton({
    required this.icon,
    required this.tooltip,
    required this.onPressed,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 34,
      height: 32,
      child: IconButton(
        padding: EdgeInsets.zero,
        iconSize: 18,
        tooltip: tooltip,
        icon: Icon(icon),
        onPressed: onPressed,
      ),
    );
  }
}
