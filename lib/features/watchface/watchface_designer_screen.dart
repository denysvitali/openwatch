import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers/app_providers.dart';
import '../../core/ui/ui_constants.dart';
import '../widgets/health_widgets.dart';

/// Diagnostic DIY watch-face designer for the APK-era Channel-B `0x3a` upload.
///
/// H59MA v14 does not implement the `0x3a` Channel-B handler; the send path is
/// retained as a diagnostic surface and reports the unsupported command error.
class WatchFaceDesignerScreen extends ConsumerStatefulWidget {
  const WatchFaceDesignerScreen({super.key});

  @override
  ConsumerState<WatchFaceDesignerScreen> createState() =>
      _WatchFaceDesignerScreenState();
}

class _WatchFaceDesignerScreenState
    extends ConsumerState<WatchFaceDesignerScreen> {
  final List<_Element> _elements = [];
  int _selectedType = 1; // 1 = circle, 2 = square, 3 = digit (firmware-defined)
  Color _color = const Color(0xFFFF3B30);
  bool _sending = false;

  static const _palette = <Color>[
    Color(0xFFFF3B30),
    Color(0xFFFF9500),
    Color(0xFFFFCC00),
    Color(0xFF34C759),
    Color(0xFF00C7BE),
    Color(0xFF007AFF),
    Color(0xFF5856D6),
    Color(0xFFAF52DE),
    Color(0xFFFF2D55),
    Color(0xFFA2845E),
    Color(0xFF8E8E93),
    Color(0xFFFFFFFF),
  ];

  @override
  Widget build(BuildContext context) {
    final manager = ref.watch(watchManagerProvider);
    final ready = manager.isReady;
    // Reasonable default canvas; firmware uses screen geometry. Most
    // H59MA-class devices are 240×280. The Oudmon SDK's coordinates
    // are device-relative; we use the manager's reported dims when
    // available, otherwise fall back to a 240×280 box.
    final caps = manager.capabilities;
    final w = caps.screenWidth > 0 ? caps.screenWidth : 240;
    final h = caps.screenHeight > 0 ? caps.screenHeight : 280;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Custom watch face'),
        actions: [
          IconButton(
            tooltip: 'Send to watch',
            icon: const Icon(Icons.cloud_upload_outlined),
            onPressed: (ready && !_sending && _elements.isNotEmpty)
                ? _send
                : null,
          ),
        ],
      ),
      body: Column(
        children: [
          const Padding(
            padding: EdgeInsets.fromLTRB(
              kCardPadding,
              kSpacingSmall,
              kCardPadding,
              0,
            ),
            child: ExperimentalBanner(
              message:
                  'Experimental / diagnostic only. Custom face upload (Channel-B 0x3a) is not implemented on H59MA v14 — send may fail even if the app accepts it.',
            ),
          ),
          Expanded(
            child: Center(
              child: AspectRatio(
                aspectRatio: w / h,
                child: Container(
                  margin: const EdgeInsets.all(kCardPadding),
                  decoration: BoxDecoration(
                    color: Colors.black,
                    borderRadius: BorderRadius.circular(kCardRadius),
                  ),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(kCardRadius),
                    child: LayoutBuilder(
                      builder: (ctx, c) {
                        final scaleX = c.maxWidth / w;
                        final scaleY = c.maxHeight / h;
                        return GestureDetector(
                          onTapDown: (d) =>
                              _addAt(d.localPosition, scaleX, scaleY),
                          child: CustomPaint(
                            painter: _CanvasPainter(
                              elements: _elements,
                              canvasWidth: w.toDouble(),
                              canvasHeight: h.toDouble(),
                              colorOf: _colorOfType,
                            ),
                          ),
                        );
                      },
                    ),
                  ),
                ),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(
              kCardPadding,
              0,
              kCardPadding,
              kCardPadding,
            ),
            child: _Toolbar(
              selectedType: _selectedType,
              onTypeChanged: (t) => setState(() => _selectedType = t),
              color: _color,
              palette: _palette,
              onColorChanged: (c) => setState(() => _color = c),
              onUndo: _elements.isEmpty
                  ? null
                  : () => setState(() => _elements.removeLast()),
              onClear: _elements.isEmpty
                  ? null
                  : () => setState(_elements.clear),
              canSend: ready && !_sending && _elements.isNotEmpty,
              onSend: _send,
            ),
          ),
        ],
      ),
    );
  }

  void _addAt(Offset local, double scaleX, double scaleY) {
    if (_elements.length >= 32) {
      _toast('Watch faces cap at 32 elements');
      return;
    }
    setState(() {
      _elements.add(
        _Element(
          type: _selectedType,
          x: (local.dx / scaleX).round().clamp(0, 9999),
          y: (local.dy / scaleY).round().clamp(0, 9999),
          r: (_color.r * 255.0).round().clamp(0, 255),
          g: (_color.g * 255.0).round().clamp(0, 255),
          b: (_color.b * 255.0).round().clamp(0, 255),
        ),
      );
    });
  }

  Future<void> _send() async {
    setState(() => _sending = true);
    try {
      final elements = _elements
          .map((e) => (type: e.type, x: e.x, y: e.y, r: e.r, g: e.g, b: e.b))
          .toList();
      await ref.read(watchManagerProvider).writeCustomWatchFace(elements);
      _toast('Sent ${elements.length} elements');
    } catch (e) {
      _toast('Send failed: $e');
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  Color _colorOfType(int type) => _color;

  void _toast(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }
}

class _Element {
  const _Element({
    required this.type,
    required this.x,
    required this.y,
    required this.r,
    required this.g,
    required this.b,
  });
  final int type;
  final int x;
  final int y;
  final int r;
  final int g;
  final int b;
}

class _CanvasPainter extends CustomPainter {
  const _CanvasPainter({
    required this.elements,
    required this.canvasWidth,
    required this.canvasHeight,
    required this.colorOf,
  });

  final List<_Element> elements;
  final double canvasWidth;
  final double canvasHeight;
  final Color Function(int type) colorOf;

  @override
  void paint(Canvas canvas, Size size) {
    final scaleX = size.width / canvasWidth;
    final scaleY = size.height / canvasHeight;
    for (final e in elements) {
      final color = Color.fromARGB(255, e.r, e.g, e.b);
      final paint = Paint()..color = color;
      final c = Offset(e.x * scaleX, e.y * scaleY);
      switch (e.type) {
        case 2:
          // Square
          canvas.drawRect(
            Rect.fromCenter(center: c, width: 16, height: 16),
            paint,
          );
        case 3:
          // Ring
          paint.style = PaintingStyle.stroke;
          paint.strokeWidth = 3;
          canvas.drawCircle(c, 8, paint);
        default:
          // Dot (circle)
          canvas.drawCircle(c, 6, paint);
      }
    }
  }

  @override
  bool shouldRepaint(covariant _CanvasPainter old) =>
      old.elements != elements ||
      old.canvasWidth != canvasWidth ||
      old.canvasHeight != canvasHeight;
}

class _Toolbar extends StatelessWidget {
  const _Toolbar({
    required this.selectedType,
    required this.onTypeChanged,
    required this.color,
    required this.palette,
    required this.onColorChanged,
    required this.onUndo,
    required this.onClear,
    required this.canSend,
    required this.onSend,
  });

  final int selectedType;
  final ValueChanged<int> onTypeChanged;
  final Color color;
  final List<Color> palette;
  final ValueChanged<Color> onColorChanged;
  final VoidCallback? onUndo;
  final VoidCallback? onClear;
  final bool canSend;
  final VoidCallback onSend;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return HealthCard(
      icon: Icons.palette_outlined,
      metricColor: theme.colorScheme.onSurface,
      title: 'Tools',
      caption:
          'Tap the preview to place an element. Choose shape and color below.',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SizedBox(height: kSpacingSmall),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                _TypeChip(
                  label: 'Dot',
                  selected: selectedType == 1,
                  onTap: () => onTypeChanged(1),
                ),
                const SizedBox(width: kSpacingTiny),
                _TypeChip(
                  label: 'Square',
                  selected: selectedType == 2,
                  onTap: () => onTypeChanged(2),
                ),
                const SizedBox(width: kSpacingTiny),
                _TypeChip(
                  label: 'Ring',
                  selected: selectedType == 3,
                  onTap: () => onTypeChanged(3),
                ),
                const SizedBox(width: kSpacingSmall),
                IconButton(
                  tooltip: 'Undo',
                  iconSize: kIconSizeSmall,
                  onPressed: onUndo,
                  icon: const Icon(Icons.undo),
                ),
                IconButton(
                  tooltip: 'Clear',
                  iconSize: kIconSizeSmall,
                  onPressed: onClear,
                  icon: const Icon(Icons.clear_all),
                ),
              ],
            ),
          ),
          const SizedBox(height: kSpacingSmall),
          SizedBox(
            height: kIconCircleSizeSmall,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: palette.length,
              separatorBuilder: (_, _) => const SizedBox(width: kSpacingSmall),
              itemBuilder: (ctx, i) {
                final c = palette[i];
                final selected = c.toARGB32() == color.toARGB32();
                return GestureDetector(
                  onTap: () => onColorChanged(c),
                  child: Container(
                    width: kIconCircleSizeSmall,
                    height: kIconCircleSizeSmall,
                    decoration: BoxDecoration(
                      color: c,
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: selected ? Colors.white : Colors.black26,
                        width: selected ? 3 : 1,
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
          const SizedBox(height: kCardInternalSpacing),
          PrimaryHealthButton(
            icon: Icons.cloud_upload_outlined,
            label: 'Send to watch',
            onPressed: canSend ? onSend : null,
          ),
        ],
      ),
    );
  }
}

class _TypeChip extends StatelessWidget {
  const _TypeChip({
    required this.label,
    required this.selected,
    required this.onTap,
  });
  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return ChoiceChip(
      label: Text(label, style: AppTextStyles.labelMedium(context)),
      selected: selected,
      onSelected: (_) => onTap(),
    );
  }
}
