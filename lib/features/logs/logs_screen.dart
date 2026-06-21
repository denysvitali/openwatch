import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers/app_providers.dart';
import '../../core/services/app_log.dart';
import '../../core/services/opentelemetry_service.dart';

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
          // OpenTelemetry status banner — surfaces tracer state at a
          // glance so a failed OTLP handshake is visible without
          // scrolling through the in-memory log buffer.
          const _OtelStatusBanner(),
          Expanded(
            child: AnimatedBuilder(
              animation: log,
              builder: (context, _) {
                final entries = log.entries;
                if (entries.isEmpty) {
                  return const Center(
                    child: Padding(
                      padding: EdgeInsets.all(24),
                      child: Text(
                        'No logs yet.\nConnect to your watch and try an '
                        'action, then copy the log here and share it.',
                        textAlign: TextAlign.center,
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
      LogLevel.warn => Colors.orange,
      LogLevel.tx => Colors.blueAccent,
      LogLevel.rx => Colors.green,
      LogLevel.debug => scheme.onSurface.withValues(alpha: 0.5),
      LogLevel.info => scheme.onSurface,
    };
  }
}

/// Compact banner at the top of the Logs screen showing the current
/// OpenTelemetry tracer state. Renders in green when active, red on
/// failure (with the error message), and grey while init is pending.
///
/// Uses a post-frame polling loop because the [OpenTelemetryService]
/// singleton is a plain class (no ChangeNotifier); the polling cost is
/// one setState per frame which the framework already coalesces.
class _OtelStatusBanner extends StatefulWidget {
  const _OtelStatusBanner();

  @override
  State<_OtelStatusBanner> createState() => _OtelStatusBannerState();
}

class _OtelStatusBannerState extends State<_OtelStatusBanner> {
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
    final (
      Color bg,
      Color fg,
      IconData icon,
      String text,
    ) = switch (otel.statusLabel) {
      'active' => (
        Colors.green.shade700,
        Colors.white,
        Icons.check_circle,
        'OpenTelemetry: active — traces shipping to '
            '${OpenTelemetryService.endpoint}',
      ),
      'failed' => (
        scheme.errorContainer,
        scheme.onErrorContainer,
        Icons.error,
        'OpenTelemetry: FAILED — ${otel.initErrorMessage ?? "unknown error"}. '
            'Spans are NOT being exported.',
      ),
      _ => (
        scheme.surfaceContainerHighest,
        scheme.onSurfaceVariant,
        Icons.hourglass_empty,
        'OpenTelemetry: pending initialization…',
      ),
    };
    return Material(
      color: bg,
      child: InkWell(
        onTap: () {
          // Copy the current status + endpoint to the clipboard so
          // users can paste it into a bug report.
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
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          child: Row(
            children: [
              Icon(icon, color: fg, size: 18),
              const SizedBox(width: 8),
              Expanded(
                child: Text(text, style: TextStyle(color: fg, fontSize: 12)),
              ),
              Icon(Icons.copy, color: fg.withValues(alpha: 0.6), size: 16),
            ],
          ),
        ),
      ),
    );
  }
}
