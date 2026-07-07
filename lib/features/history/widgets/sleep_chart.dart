import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../core/protocol/sleep_parser.dart';
import '../../../core/ui/ui_constants.dart';

/// Horizontal sleep timeline — one row per [SleepStage] showing the
/// cumulative minutes spent in each stage, with hour-of-day ticks along
/// the bottom.
///
/// Sleep can cross midnight, so the display range is derived from the
/// actual segment bounds rather than a fixed calendar day. The plot clips to
/// its drawing area and supports drag, pinch, tap selection, and zoom controls.
class SleepTimeline extends StatefulWidget {
  const SleepTimeline({super.key, required this.segments, this.height = 64});

  final List<SleepSegment> segments;
  final double height;

  @override
  State<SleepTimeline> createState() => _SleepTimelineState();
}

class _SleepTimelineState extends State<SleepTimeline> {
  static const int _minSpanMs = 60 * 60 * 1000;

  double _viewStart = 0;
  double _viewEnd = 1;
  double _scaleStartStart = 0;
  double _scaleStartEnd = 1;
  SleepSegment? _selected;

  @override
  void didUpdateWidget(SleepTimeline oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.segments != widget.segments) {
      _viewStart = 0;
      _viewEnd = 1;
      _selected = null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final range = _SleepRange.fromSegments(widget.segments);
    return SizedBox(
      height: widget.height,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final size = Size(constraints.maxWidth, constraints.maxHeight);
          return Stack(
            children: [
              Positioned.fill(
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTapDown: (details) =>
                      _selectSegment(details.localPosition, size, range),
                  onScaleStart: (details) {
                    _scaleStartStart = _viewStart;
                    _scaleStartEnd = _viewEnd;
                    if (details.pointerCount <= 1) {
                      _selectSegment(details.localFocalPoint, size, range);
                    }
                  },
                  onScaleUpdate: (details) =>
                      _handleScaleUpdate(details, size, range),
                  child: ClipRect(
                    child: CustomPaint(
                      painter: _SleepPainter(
                        segments: widget.segments,
                        colors: _stageColors,
                        axisColor: theme.colorScheme.outlineVariant,
                        textColor: theme.colorScheme.onSurfaceVariant,
                        range: range,
                        viewStart: _viewStart,
                        viewEnd: _viewEnd,
                        selected: _selected,
                      ),
                      size: Size.infinite,
                    ),
                  ),
                ),
              ),
              if (_selected != null)
                Positioned(
                  top: 6,
                  right: 8,
                  child: _SleepBadge(segment: _selected!),
                ),
              if (widget.segments.isNotEmpty)
                Positioned(
                  right: 6,
                  bottom: 18,
                  child: _SleepControls(
                    onZoomOut: () => _zoom(1.8, range),
                    onReset: _resetView,
                    onZoomIn: () => _zoom(0.55, range),
                  ),
                ),
            ],
          );
        },
      ),
    );
  }

  static const _stageColors = {
    SleepStage.awake: Color(0xFFE57373),
    SleepStage.rem: Color(0xFF7E57C2),
    SleepStage.light: Color(0xFF64B5F6),
    SleepStage.deep: Color(0xFF1E88E5),
  };

  void _handleScaleUpdate(
    ScaleUpdateDetails details,
    Size size,
    _SleepRange range,
  ) {
    final chartRect = _SleepPainter.chartRectFor(size);
    if (chartRect.width <= 0 || range.spanMs <= 0) return;
    final minSpan = (_minSpanMs / range.spanMs).clamp(0.02, 1.0);
    final startSpan = _scaleStartEnd - _scaleStartStart;
    if (details.pointerCount > 1 && (details.scale - 1).abs() > 0.01) {
      final focal =
          ((details.localFocalPoint.dx - chartRect.left) / chartRect.width)
              .clamp(0.0, 1.0);
      final anchor = _scaleStartStart + startSpan * focal;
      final nextSpan = (startSpan / details.scale).clamp(minSpan, 1.0);
      _setRange(
        anchor - nextSpan * focal,
        anchor + nextSpan * (1 - focal),
        minSpan,
      );
      return;
    }
    if (details.pointerCount <= 1) {
      _selectSegment(details.localFocalPoint, size, range);
      return;
    }
    final delta =
        -details.focalPointDelta.dx / chartRect.width * (_viewEnd - _viewStart);
    if (delta.abs() > 0.0001) {
      _setRange(_viewStart + delta, _viewEnd + delta, minSpan);
    }
  }

  void _selectSegment(Offset position, Size size, _SleepRange range) {
    final chartRect = _SleepPainter.chartRectFor(size);
    if (!chartRect.contains(position) || range.spanMs <= 0) return;
    final visibleStart = range.startMs + (range.spanMs * _viewStart).round();
    final visibleEnd = range.startMs + (range.spanMs * _viewEnd).round();
    final target =
        visibleStart +
        ((position.dx - chartRect.left) / chartRect.width) *
            (visibleEnd - visibleStart);
    SleepSegment? best;
    var bestDistance = double.infinity;
    for (final segment in widget.segments) {
      final start = segment.start.millisecondsSinceEpoch;
      final end = start + segment.duration.inMilliseconds;
      if (end < visibleStart || start > visibleEnd) continue;
      final distance = target < start
          ? (start - target).toDouble()
          : target > end
          ? (target - end).toDouble()
          : 0.0;
      if (distance < bestDistance) {
        best = segment;
        bestDistance = distance;
      }
    }
    if (best != null) {
      _selectSleepSegment(best);
    }
  }

  void _selectSleepSegment(SleepSegment segment) {
    final current = _selected;
    if (current?.start == segment.start &&
        current?.duration == segment.duration &&
        current?.stage == segment.stage) {
      return;
    }
    HapticFeedback.lightImpact();
    setState(() => _selected = segment);
  }

  void _zoom(double factor, _SleepRange range) {
    final minSpan = (_minSpanMs / range.spanMs).clamp(0.02, 1.0);
    final center = (_viewStart + _viewEnd) / 2;
    final nextSpan = ((_viewEnd - _viewStart) * factor).clamp(minSpan, 1.0);
    _setRange(center - nextSpan / 2, center + nextSpan / 2, minSpan);
  }

  void _resetView() {
    setState(() {
      _viewStart = 0;
      _viewEnd = 1;
      _selected = null;
    });
  }

  void _setRange(double start, double end, double minSpan) {
    final span = end - start;
    if (span >= 1) {
      setState(() {
        _viewStart = 0;
        _viewEnd = 1;
      });
      return;
    }
    var nextStart = start;
    var nextEnd = end;
    if (nextStart < 0) {
      nextEnd -= nextStart;
      nextStart = 0;
    }
    if (nextEnd > 1) {
      nextStart -= nextEnd - 1;
      nextEnd = 1;
    }
    nextStart = nextStart.clamp(0.0, 1.0 - minSpan);
    nextEnd = nextEnd.clamp(nextStart + minSpan, 1.0);
    setState(() {
      _viewStart = nextStart;
      _viewEnd = nextEnd;
    });
  }
}

class _SleepRange {
  const _SleepRange(this.startMs, this.endMs);

  final int startMs;
  final int endMs;

  int get spanMs => math.max(1, endMs - startMs);

  factory _SleepRange.fromSegments(List<SleepSegment> segments) {
    if (segments.isEmpty) {
      final now = DateTime.now();
      final start = DateTime(
        now.year,
        now.month,
        now.day,
      ).millisecondsSinceEpoch;
      return _SleepRange(start, start + const Duration(days: 1).inMilliseconds);
    }
    var minStart = segments.first.start.millisecondsSinceEpoch;
    var maxEnd = minStart + segments.first.duration.inMilliseconds;
    for (final segment in segments.skip(1)) {
      final start = segment.start.millisecondsSinceEpoch;
      final end = start + segment.duration.inMilliseconds;
      if (start < minStart) minStart = start;
      if (end > maxEnd) maxEnd = end;
    }
    const pad = Duration(minutes: 30);
    minStart -= pad.inMilliseconds;
    maxEnd += pad.inMilliseconds;

    const minSpan = Duration(hours: 4);
    if (maxEnd - minStart < minSpan.inMilliseconds) {
      final center = ((minStart + maxEnd) / 2).round();
      minStart = center - minSpan.inMilliseconds ~/ 2;
      maxEnd = center + minSpan.inMilliseconds ~/ 2;
    }
    return _SleepRange(minStart, maxEnd);
  }
}

class _SleepPainter extends CustomPainter {
  _SleepPainter({
    required this.segments,
    required this.colors,
    required this.axisColor,
    required this.textColor,
    required this.range,
    required this.viewStart,
    required this.viewEnd,
    required this.selected,
  });

  final List<SleepSegment> segments;
  final Map<SleepStage, Color> colors;
  final Color axisColor;
  final Color textColor;
  final _SleepRange range;
  final double viewStart;
  final double viewEnd;
  final SleepSegment? selected;

  static const double _leftLabelWidth = 40;
  static const double _bottomAxisHeight = 16;

  static Rect chartRectFor(Size size) {
    return Rect.fromLTWH(
      _leftLabelWidth,
      2,
      math.max(0, size.width - _leftLabelWidth),
      math.max(0, size.height - _bottomAxisHeight - 2),
    );
  }

  @override
  void paint(Canvas canvas, Size size) {
    if (segments.isEmpty) {
      _paintEmpty(canvas, size);
      return;
    }

    final chartRect = chartRectFor(size);
    if (chartRect.width <= 0 || chartRect.height <= 0) return;
    final visibleStart = range.startMs + (range.spanMs * viewStart).round();
    final visibleEnd = range.startMs + (range.spanMs * viewEnd).round();
    final visibleSpan = math.max(1, visibleEnd - visibleStart);

    final paint = Paint()..style = PaintingStyle.fill;
    const lanes = [
      SleepStage.awake,
      SleepStage.rem,
      SleepStage.light,
      SleepStage.deep,
    ];
    final laneH = chartRect.height / lanes.length;

    canvas.save();
    canvas.clipRect(chartRect);
    for (var i = 0; i < segments.length; i++) {
      final s = segments[i];
      final lane = lanes.indexOf(s.stage);
      if (lane < 0) continue;
      final startMs = s.start.millisecondsSinceEpoch;
      final endMs = startMs + s.duration.inMilliseconds;
      if (endMs < visibleStart || startMs > visibleEnd) continue;
      final x0 =
          chartRect.left +
          ((startMs - visibleStart) / visibleSpan) * chartRect.width;
      final x1 =
          chartRect.left +
          ((endMs - visibleStart) / visibleSpan) * chartRect.width;
      final y = chartRect.top + lane * laneH + 2;
      paint.color = colors[s.stage] ?? Colors.blueGrey;
      final rect = RRect.fromRectAndRadius(
        Rect.fromLTRB(x0, y, x1, y + laneH - 4),
        const Radius.circular(5),
      );
      canvas.drawRRect(rect, paint);
    }
    _paintSelected(canvas, chartRect, visibleStart, visibleSpan);
    canvas.restore();

    _paintLaneLabels(canvas, chartRect, laneH, lanes);
    _paintAxes(canvas, chartRect, visibleStart, visibleSpan);
  }

  void _paintSelected(
    Canvas canvas,
    Rect chartRect,
    int visibleStart,
    int visibleSpan,
  ) {
    final segment = selected;
    if (segment == null) return;
    final startMs = segment.start.millisecondsSinceEpoch;
    final endMs = startMs + segment.duration.inMilliseconds;
    if (endMs < visibleStart || startMs > visibleStart + visibleSpan) return;
    final x =
        chartRect.left +
        (((startMs + endMs) / 2 - visibleStart) / visibleSpan) *
            chartRect.width;
    canvas.drawLine(
      Offset(x, chartRect.top),
      Offset(x, chartRect.bottom),
      Paint()
        ..color = (colors[segment.stage] ?? Colors.blueGrey).withValues(
          alpha: 0.35,
        )
        ..strokeWidth = 1,
    );
  }

  void _paintLaneLabels(
    Canvas canvas,
    Rect chartRect,
    double laneH,
    List<SleepStage> lanes,
  ) {
    final textStyle = TextStyle(
      color: textColor,
      fontSize: kLabelSmall,
      height: 1.0,
      letterSpacing: 0,
    );
    for (var i = 0; i < lanes.length; i++) {
      final tp = TextPainter(
        text: TextSpan(text: _label(lanes[i]), style: textStyle),
        textDirection: TextDirection.ltr,
      )..layout();
      final y = chartRect.top + i * laneH + 2;
      final swatchPaint = Paint()..color = colors[lanes[i]] ?? Colors.blueGrey;
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(0, y + (laneH - 10) / 2, 6, 6),
          const Radius.circular(3),
        ),
        swatchPaint,
      );
      tp.paint(canvas, Offset(10, y + (laneH - 4 - tp.height) / 2));
    }
  }

  void _paintAxes(
    Canvas canvas,
    Rect chartRect,
    int visibleStart,
    int visibleSpan,
  ) {
    final gridPaint = Paint()
      ..color = axisColor.withValues(alpha: 0.48)
      ..strokeWidth = 0.5;
    canvas.drawLine(
      Offset(chartRect.left, chartRect.bottom),
      Offset(chartRect.right, chartRect.bottom),
      gridPaint,
    );
    for (var i = 0; i < 5; i++) {
      final ms = visibleStart + (visibleSpan * (i / 4)).round();
      final x = chartRect.left + (i / 4) * chartRect.width;
      _paintText(
        canvas,
        _clock(DateTime.fromMillisecondsSinceEpoch(ms)),
        Offset(x - 12, chartRect.bottom + 4),
        size: kLabelSmall,
        color: textColor,
      );
    }
  }

  void _paintEmpty(Canvas canvas, Size size) {
    final tp = TextPainter(
      text: TextSpan(
        text: 'No sleep data',
        style: TextStyle(
          color: textColor.withValues(alpha: 0.6),
          fontSize: kBodySmall,
          height: 1.0,
          letterSpacing: 0,
        ),
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

  String _label(SleepStage s) => switch (s) {
    SleepStage.awake => 'Awake',
    SleepStage.rem => 'REM',
    SleepStage.light => 'Light',
    SleepStage.deep => 'Deep',
  };

  String _clock(DateTime t) =>
      '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

  @override
  bool shouldRepaint(_SleepPainter old) =>
      old.segments != segments ||
      old.colors != colors ||
      old.range.startMs != range.startMs ||
      old.range.endMs != range.endMs ||
      old.viewStart != viewStart ||
      old.viewEnd != viewEnd ||
      old.selected != selected;
}

class _SleepBadge extends StatelessWidget {
  const _SleepBadge({required this.segment});

  final SleepSegment segment;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest.withValues(
          alpha: 0.94,
        ),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: theme.colorScheme.outlineVariant),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        child: Text(
          '${_label(segment.stage)}  ${_clock(segment.start)}  ${segment.duration.inMinutes}m',
          style: AppTextStyles.labelMedium(context),
        ),
      ),
    );
  }

  static String _label(SleepStage s) => switch (s) {
    SleepStage.awake => 'Awake',
    SleepStage.rem => 'REM',
    SleepStage.light => 'Light',
    SleepStage.deep => 'Deep',
  };

  static String _clock(DateTime t) =>
      '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
}

class _SleepControls extends StatelessWidget {
  const _SleepControls({
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
        color: theme.colorScheme.surface.withValues(alpha: 0.88),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: theme.colorScheme.outlineVariant),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _SleepIconButton(
            icon: Icons.remove_rounded,
            tooltip: 'Zoom out',
            onPressed: onZoomOut,
          ),
          _SleepIconButton(
            icon: Icons.center_focus_strong_rounded,
            tooltip: 'Reset view',
            onPressed: onReset,
          ),
          _SleepIconButton(
            icon: Icons.add_rounded,
            tooltip: 'Zoom in',
            onPressed: onZoomIn,
          ),
        ],
      ),
    );
  }
}

class _SleepIconButton extends StatelessWidget {
  const _SleepIconButton({
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
