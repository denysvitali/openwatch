import 'package:flutter/foundation.dart';

enum LogLevel { debug, info, tx, rx, warn, error }

typedef AppLogSink = void Function(LogEntry entry);

class LogEntry {
  LogEntry(this.time, this.level, this.tag, this.message);
  final DateTime time;
  final LogLevel level;
  final String tag;
  final String message;

  String get _ts {
    String two(int n) => n.toString().padLeft(2, '0');
    String three(int n) => n.toString().padLeft(3, '0');
    return '${two(time.hour)}:${two(time.minute)}:${two(time.second)}.${three(time.millisecond)}';
  }

  @override
  String toString() =>
      '$_ts ${level.name.toUpperCase().padRight(5)} [$tag] $message';
}

/// Lightweight in-memory ring-buffer logger.
///
/// A process-wide singleton so non-widget code (the BLE transport) can log
/// without plumbing. The Diagnostics screen renders [entries] and lets the user
/// copy [dump] for bug reports.
class AppLog extends ChangeNotifier {
  AppLog._();
  static final AppLog instance = AppLog._();

  static const int _max = 2000;
  final List<LogEntry> _entries = [];
  final Set<AppLogSink> _sinks = {};

  List<LogEntry> get entries => List.unmodifiable(_entries);

  void addSink(AppLogSink sink) {
    _sinks.add(sink);
  }

  void removeSink(AppLogSink sink) {
    _sinks.remove(sink);
  }

  void log(String tag, String message, {LogLevel level = LogLevel.info}) {
    final entry = LogEntry(DateTime.now(), level, tag, message);
    _entries.add(entry);
    if (_entries.length > _max) _entries.removeAt(0);
    if (kDebugMode) debugPrint(entry.toString());
    for (final sink in List<AppLogSink>.of(_sinks)) {
      try {
        sink(entry);
      } catch (e, stack) {
        if (kDebugMode) {
          debugPrint('AppLog sink failed: $e\n$stack');
        }
      }
    }
    notifyListeners();
  }

  void debug(String tag, String m) => log(tag, m, level: LogLevel.debug);
  void info(String tag, String m) => log(tag, m, level: LogLevel.info);
  void warn(String tag, String m) => log(tag, m, level: LogLevel.warn);
  void error(String tag, String m) => log(tag, m, level: LogLevel.error);

  /// Logs a byte frame as hex with a direction marker (e.g. `TX-A`, `RX-A`).
  void frame(String tag, String dir, List<int> bytes, {LogLevel? level}) {
    log(
      tag,
      '$dir ${toHex(bytes)}',
      level: level ?? (dir.startsWith('TX') ? LogLevel.tx : LogLevel.rx),
    );
  }

  void clear() {
    _entries.clear();
    notifyListeners();
  }

  String dump() => _entries.map((e) => e.toString()).join('\n');

  static String toHex(List<int> bytes) =>
      bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join(' ');
}
