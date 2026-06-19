import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/ble/ble_transport.dart';
import '../../core/providers/app_providers.dart';
import '../../core/services/history_sync.dart';

/// History view: pulls stored HR + sleep from the watch and shows them.
/// On-demand, no cloud involved.
class HistoryScreen extends ConsumerStatefulWidget {
  const HistoryScreen({super.key});

  @override
  ConsumerState<HistoryScreen> createState() => _HistoryScreenState();
}

class _HistoryScreenState extends ConsumerState<HistoryScreen> {
  late HistorySync _sync;

  @override
  void initState() {
    super.initState();
    _sync = HistorySync(
      ref.read(bleTransportProvider),
      (_) {}, // totals already shown on dashboard
    )..addListener(_onChange);
  }

  void _onChange() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _sync.removeListener(_onChange);
    _sync.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ready = ref.watch(linkStateProvider).value == LinkState.ready;
    final samples = _sync.hr;
    final sleep = _sync.sleep;
    return Scaffold(
      appBar: AppBar(
        title: const Text('History'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: 'Sync from watch',
            onPressed: ready && !_sync.syncing ? _sync.syncAll : null,
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: () => _sync.syncAll(),
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            if (_sync.syncing) const LinearProgressIndicator(),
            const SizedBox(height: 8),
            Text(
              'Heart rate (last sync)',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            if (samples.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 24),
                child: Center(
                  child: Text(
                    'No HR history yet.\nTap sync to pull from the watch.',
                    textAlign: TextAlign.center,
                  ),
                ),
              )
            else
              SizedBox(height: 180, child: _HrChart(samples: samples)),
            const SizedBox(height: 24),
            Text('Sleep', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            if (sleep.isEmpty)
              const Text('No sleep data synced yet.')
            else
              ...sleep.map(
                (s) => ListTile(
                  dense: true,
                  leading: Icon(_iconFor(s.stage)),
                  title: Text('${s.stage.name} — ${s.duration.inMinutes} min'),
                  subtitle: Text(s.start.toLocal().toString()),
                ),
              ),
            const SizedBox(height: 16),
            Text(
              'Days with data (32-day window)',
              style: Theme.of(context).textTheme.titleSmall,
            ),
            Wrap(
              spacing: 6,
              children: [
                for (var d = 0; d < 32; d++)
                  _availableDayChip(d, _sync.availableDays.contains(d)),
              ],
            ),
            const SizedBox(height: 24),
            OutlinedButton.icon(
              icon: const Icon(Icons.cloud_download),
              label: const Text('Back to device'),
              onPressed: () => context.go('/dashboard'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _availableDayChip(int d, bool has) {
    return Tooltip(
      message: d == 0 ? 'Today' : '$d day(s) ago',
      child: Container(
        width: 22,
        height: 22,
        margin: const EdgeInsets.symmetric(vertical: 4),
        decoration: BoxDecoration(
          color: has
              ? Theme.of(context).colorScheme.primary
              : Theme.of(context).colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(4),
        ),
        alignment: Alignment.center,
        child: Text(
          '$d',
          style: TextStyle(
            fontSize: 10,
            color: has
                ? Theme.of(context).colorScheme.onPrimary
                : Theme.of(context).colorScheme.onSurface,
          ),
        ),
      ),
    );
  }

  IconData _iconFor(SleepStage s) => switch (s) {
    SleepStage.awake => Icons.wb_sunny,
    SleepStage.light => Icons.bedtime,
    SleepStage.deep => Icons.nights_stay,
    SleepStage.rem => Icons.visibility,
  };
}

class _HrChart extends StatelessWidget {
  const _HrChart({required this.samples});
  final List<HrSample> samples;

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      painter: _HrPainter(samples, Theme.of(context).colorScheme.primary),
      size: Size.infinite,
    );
  }
}

class _HrPainter extends CustomPainter {
  _HrPainter(this.samples, this.color);
  final List<HrSample> samples;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    if (samples.isEmpty) return;
    final minBpm = 40.0;
    final maxBpm = 200.0;
    final range = maxBpm - minBpm;
    final paint = Paint()
      ..color = color
      ..strokeWidth = 1.5
      ..style = PaintingStyle.stroke;
    final fillPaint = Paint()
      ..color = color.withValues(alpha: 0.15)
      ..style = PaintingStyle.fill;
    final path = Path();
    final fillPath = Path();
    for (var i = 0; i < samples.length; i++) {
      final x = (i / (samples.length - 1).clamp(1, 9999)) * size.width;
      final yNorm = (samples[i].bpm - minBpm) / range;
      final y = size.height - (yNorm * size.height).clamp(0.0, size.height);
      if (i == 0) {
        path.moveTo(x, y);
        fillPath.moveTo(x, size.height);
        fillPath.lineTo(x, y);
      } else {
        path.lineTo(x, y);
        fillPath.lineTo(x, y);
      }
    }
    fillPath.lineTo(size.width, size.height);
    fillPath.close();
    canvas.drawPath(fillPath, fillPaint);
    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(_HrPainter old) => old.samples != samples;
}
