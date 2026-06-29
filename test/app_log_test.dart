import 'package:flutter_test/flutter_test.dart';
import 'package:openwatch/core/services/app_log.dart';

void main() {
  test('AppLog notifies registered sinks with emitted entries', () {
    final log = AppLog.instance;
    log.clear();

    final seen = <LogEntry>[];
    void sink(LogEntry entry) => seen.add(entry);

    log.addSink(sink);
    addTearDown(() => log.removeSink(sink));

    log.warn('test', 'sent to sink');

    expect(seen, hasLength(1));
    expect(seen.single.tag, 'test');
    expect(seen.single.level, LogLevel.warn);
    expect(seen.single.message, 'sent to sink');
  });

  test('AppLog stops notifying removed sinks', () {
    final log = AppLog.instance;
    log.clear();

    var seen = 0;
    void sink(LogEntry entry) => seen++;

    log.addSink(sink);
    log.removeSink(sink);
    log.info('test', 'not sent');

    expect(seen, 0);
  });
}
