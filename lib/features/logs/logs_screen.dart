import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers/app_providers.dart';
import '../../core/services/app_log.dart';
import '../../core/services/opentelemetry_service.dart';
import '../widgets/health_widgets.dart';

/// Diagnostics: live BLE/app log + copy-to-clipboard for bug reports,
/// plus a JSON export of every persisted history day.
class LogsScreen extends ConsumerWidget {
  const LogsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final log = AppLog.instance;
    final storeAsync = ref.watch(historyStoreProvider);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Diagnostics'),
        actions: [
          IconButton(
            icon: const Icon(Icons.copy_all),
            tooltip: 'Copy all',
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: log.dump()));
              if (context.mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Logs copied to clipboard')),
                );
              }
            },
          ),
          IconButton(
            icon: const Icon(Icons.download),
            tooltip: 'Export history',
            onPressed: () => _exportHistory(context, storeAsync.value),
          ),
          IconButton(
            icon: const Icon(Icons.delete_sweep),
            tooltip: 'Clear',
            onPressed: log.clear,
          ),
        ],
      ),
      body: Column(
        children: [
          // OpenTelemetry status card — surfaces tracer state at a
          // glance so a failed OTLP handshake is visible without
          // scrolling through the in-memory log buffer.
          const Padding(
            padding: EdgeInsets.fromLTRB(18, 12, 18, 0),
            child: _OtelStatusCard(),
          ),
          const HealthSectionHeader(title: 'Log stream'),
          Expanded(
            child: AnimatedBuilder(
              animation: log,
              builder: (context, _) {
                final entries = log.entries;
                if (entries.isEmpty) {
                  return const Center(
                    child: Padding(
                      padding: EdgeInsets.all(24),
                      child: HealthCard(
                        icon: Icons.notes,
                        title: 'No logs yet',
                        caption:
                            'Connect to your watch and try an action, '
                            'then copy the log here and share it.',
                      ),
                    ),
                  );
                }
                return ListView.builder(
                  reverse: true,
                  padding: const EdgeInsets.all(8),
                  itemCount: entries.length,
                  itemBuilder: (context, i) {
                    final e = entries[entries.length - 1 - i];
                    return Padding(
                      padding: const EdgeInsets.symmetric(vertical: 1),
                      child: SelectableText(
                        e.toString(),
                        style: TextStyle(
                          fontFamily: 'monospace',
                          fontSize: 11.5,
                          color: _color(context, e.level),
                        ),
                      ),
                    );
                  },
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  /// Copies a JSON dump of every persisted history day + sync watermarks
  /// to the clipboard. Designed for testers on the bus: no adb, no
  /// cloud sync, no share-sheet plugin — just one tap and paste.
  Future<void> _exportHistory(BuildContext context, dynamic store) async {
    final messenger = ScaffoldMessenger.of(context);
    final storeObj = store;
    if (storeObj == null) {
      messenger.showSnackBar(
        const SnackBar(
          content: Text(
            'History store not loaded yet — connect to your watch first.',
          ),
        ),
      );
      return;
    }
    try {
      final bundle = await storeObj.exportAll() as Map<String, dynamic>;
      final days = (bundle['days'] as List?) ?? const [];
      // Pretty-print so the pasted JSON is readable in chat.
      final pretty = const JsonEncoder.withIndent('  ').convert(bundle);
      await Clipboard.setData(ClipboardData(text: pretty));
      if (!context.mounted) return;
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            'Exported ${days.length} day(s) (${pretty.length} chars) — '
            'paste into a file or chat',
          ),
        ),
      );
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('Export failed: $e')));
    }
  }

  Color _color(BuildContext context, LogLevel level) {
    final scheme = Theme.of(context).colorScheme;
    return switch (level) {
      LogLevel.error => scheme.error,
      LogLevel.warn => scheme.tertiary,
      LogLevel.tx => scheme.primary,
      LogLevel.rx => scheme.secondary,
      LogLevel.debug => scheme.onSurface.withValues(alpha: 0.5),
      LogLevel.info => scheme.onSurface,
    };
  }
}

/// Compact card at the top of the Logs screen showing the current
/// OpenTelemetry tracer state. Renders in green when active, red on
/// failure (with the error message), and grey while init is pending.
///
/// Uses a post-frame polling loop because the [OpenTelemetryService]
/// singleton is a plain class (no ChangeNotifier); the polling cost is
/// one setState per frame which the framework already coalesces.
class _OtelStatusCard extends StatefulWidget {
  const _OtelStatusCard();

  @override
  State<_OtelStatusCard> createState() => _OtelStatusCardState();
}

class _OtelStatusCardState extends State<_OtelStatusCard> {
  @override
  void initState() {
    super.initState();
    _scheduleRefresh();
  }

  void _scheduleRefresh() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      setState(() {});
      _scheduleRefresh();
    });
  }

  @override
  Widget build(BuildContext context) {
    final otel = OpenTelemetryService();
    final scheme = Theme.of(context).colorScheme;
    final status = otel.statusLabel;
    final (
      Color metricColor,
      IconData icon,
      String title,
      String caption,
    ) = switch (status) {
      'active' => (
        scheme.secondary,
        Icons.check_circle,
        'OpenTelemetry active',
        'Traces shipping to ${OpenTelemetryService.endpoint}',
      ),
      'failed' => (
        scheme.error,
        Icons.error,
        'OpenTelemetry failed',
        otel.initErrorMessage ?? 'Spans are NOT being exported.',
      ),
      _ => (
        scheme.onSurfaceVariant,
        Icons.hourglass_empty,
        'OpenTelemetry pending',
        'Waiting for tracer initialization…',
      ),
    };
    return HealthCard(
      icon: icon,
      metricColor: metricColor,
      title: title,
      value: status[0].toUpperCase() + status.substring(1),
      caption: caption,
      trailing: IconButton(
        icon: const Icon(Icons.copy),
        tooltip: 'Copy status',
        onPressed: () {
          final body =
              'OTel status: ${otel.statusLabel}\n'
              'Endpoint: ${OpenTelemetryService.endpoint}\n'
              'Error: ${otel.initErrorMessage ?? "none"}';
          Clipboard.setData(ClipboardData(text: body));
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('OpenTelemetry status copied to clipboard'),
            ),
          );
        },
      ),
      child: Padding(
        padding: const EdgeInsets.only(top: 12),
        child: StatusPill(
          icon: status == 'active'
              ? Icons.check_circle
              : status == 'failed'
              ? Icons.error
              : Icons.hourglass_empty,
          label: status == 'active'
              ? 'Exporting'
              : status == 'failed'
              ? 'Not exporting'
              : 'Initializing',
          color: metricColor,
        ),
      ),
    );
  }
}
