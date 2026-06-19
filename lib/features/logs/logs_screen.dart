import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/services/app_log.dart';

/// Diagnostics: live BLE/app log with copy-to-clipboard for bug reports.
class LogsScreen extends StatelessWidget {
  const LogsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final log = AppLog.instance;
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
            icon: const Icon(Icons.delete_sweep),
            tooltip: 'Clear',
            onPressed: log.clear,
          ),
        ],
      ),
      body: AnimatedBuilder(
        animation: log,
        builder: (context, _) {
          final entries = log.entries;
          if (entries.isEmpty) {
            return const Center(
              child: Padding(
                padding: EdgeInsets.all(24),
                child: Text(
                  'No logs yet.\nConnect to your watch and try an action, '
                  'then copy the log here and share it.',
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
    );
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
