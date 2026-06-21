import 'dart:convert';
import 'dart:io';

import 'package:openwatch/core/protocol/watch_log_decoder.dart';

Future<void> main(List<String> args) async {
  final rest = [...args];
  final json = rest.remove('--json');
  final includeFrames = !rest.remove('--summary');
  DateTime? captureDate;

  String? dateArg;
  for (final arg in rest) {
    if (arg.startsWith('--date=')) {
      dateArg = arg;
      break;
    }
  }
  if (dateArg != null) {
    rest.remove(dateArg);
    captureDate = DateTime.tryParse(dateArg.substring('--date='.length));
    if (captureDate == null) {
      stderr.writeln('Invalid --date value. Use YYYY-MM-DD.');
      exitCode = 64;
      return;
    }
  }

  final input = rest.isEmpty
      ? await stdin.transform(utf8.decoder).join()
      : await File(rest.single).readAsString();
  final report = WatchLogDecoder(
    captureDate: captureDate,
  ).decodeNrfConnectLog(input);

  if (json) {
    const encoder = JsonEncoder.withIndent('  ');
    stdout.writeln(
      encoder.convert(report.toJson(includeFrames: includeFrames)),
    );
    return;
  }

  stdout.writeln(
    'Frames: ${report.frames.length} '
    '(${report.validFrameCount} valid, ${report.invalidFrameCount} invalid)',
  );
  stdout.writeln('Channels: ${report.channelCounts}');
  for (final series in report.heartRateSeries) {
    stdout.writeln(
      'HR: ${series.timestamp?.toIso8601String() ?? 'unknown timestamp'} '
      '${series.samples} samples '
      'min/avg/max=${series.minBpm ?? '-'}'
      '/${series.avgBpm?.toStringAsFixed(1) ?? '-'}'
      '/${series.maxBpm ?? '-'}',
    );
  }
  for (final series in report.pressureSeries) {
    stdout.writeln(
      'Pressure: ${series.byteCount} bytes '
      'nonZero=${series.nonZeroCount} '
      'min/max=${series.minNonZero ?? '-'}/${series.maxNonZero ?? '-'}',
    );
  }
  for (final series in report.hrvSeries) {
    stdout.writeln(
      'HRV: ${series.byteCount} bytes '
      'nonZero=${series.nonZeroCount} '
      'min/max=${series.minNonZero ?? '-'}/${series.maxNonZero ?? '-'}',
    );
  }
  for (final frame in report.frames) {
    stdout.writeln(
      '${frame.timestamp ?? 'no-time'} line ${frame.lineNo}: ${frame.title}',
    );
  }
}
