import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers/app_providers.dart';

/// DIY watch-face designer (Channel B `0x3a` upload).
///
/// The H59MA firmware expects a flat list of `{type, x, y, r, g, b}`
/// elements (capped at 32) describing decals/elements to draw on the
/// vendor canvas. The exact layout/coords are device-defined; this
/// screen keeps things simple — a pixel grid sized to the device's
/// `screenWidth × screenHeight` (queried via `readAvatar` / `deviceSupport`)
/// where the user taps to place colored dots, then sends the bundle.
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
          Expanded(
            child: Center(
              child: AspectRatio(
                aspectRatio: w / h,
                child: Container(
                  decoration: BoxDecoration(
                    color: Colors.black,
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(16),
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
          const Divider(height: 1),
          _Toolbar(
            selectedType: _selectedType,
            onTypeChanged: (t) => setState(() => _selectedType = t),
            color: _color,
            palette: _palette,
            onColorChanged: (c) => setState(() => _color = c),
            onUndo: _elements.isEmpty
                ? null
                : () => setState(() => _elements.removeLast()),
            onClear: _elements.isEmpty ? null : () => setState(_elements.clear),
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
  });

  final int selectedType;
  final ValueChanged<int> onTypeChanged;
  final Color color;
  final List<Color> palette;
  final ValueChanged<Color> onColorChanged;
  final VoidCallback? onUndo;
  final VoidCallback? onClear;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 8, 8, 12),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                _TypeChip(
                  label: 'Dot',
                  selected: selectedType == 1,
                  onTap: () => onTypeChanged(1),
                ),
                const SizedBox(width: 6),
                _TypeChip(
                  label: 'Square',
                  selected: selectedType == 2,
                  onTap: () => onTypeChanged(2),
                ),
                const SizedBox(width: 6),
                _TypeChip(
                  label: 'Ring',
                  selected: selectedType == 3,
                  onTap: () => onTypeChanged(3),
                ),
                const SizedBox(width: 12),
                IconButton(
                  tooltip: 'Undo',
                  onPressed: onUndo,
                  icon: const Icon(Icons.undo),
                ),
                IconButton(
                  tooltip: 'Clear',
                  onPressed: onClear,
                  icon: const Icon(Icons.clear_all),
                ),
              ],
            ),
          ),
          const SizedBox(height: 8),
          SizedBox(
            height: 44,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: palette.length,
              separatorBuilder: (_, _) => const SizedBox(width: 8),
              itemBuilder: (ctx, i) {
                final c = palette[i];
                final selected = c.toARGB32() == color.toARGB32();
                return GestureDetector(
                  onTap: () => onColorChanged(c),
                  child: Container(
                    width: 44,
                    height: 44,
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
      label: Text(label),
      selected: selected,
      onSelected: (_) => onTap(),
    );
  }
}
