import 'package:flutter_test/flutter_test.dart';
import 'package:openwatch/core/services/opentelemetry_service.dart';

void main() {
  group('OpenTelemetryService config', () {
    // Use the singleton — config is static and read-only after init.
    final otel = OpenTelemetryService();

    test('ships to the shared collector endpoint', () {
      expect(otel.configuredEndpoint, 'https://otel.k2.k8s.best');
    });

    test('tracing, metrics, and logs are all enabled by default', () {
      // Auto-log-events stay off — they auto-emit lifecycle/navigation/error
      // log records that would triple the volume for marginal debug value.
      expect(otel.configuredTracingEnabledByDefault, isTrue);
      expect(otel.configuredEnableMetrics, isTrue);
      expect(otel.configuredEnableLogs, isTrue);
      expect(otel.configuredEnableAutoLogEvents, isFalse);
    });

    test('logs and metrics use batched export cadences', () {
      expect(otel.configuredMetricExportInterval, const Duration(seconds: 60));
      expect(otel.configuredLogBatchScheduleDelay, const Duration(seconds: 5));
      expect(otel.configuredLogBatchMaxExportBatchSize, 512);
    });

    test('service name matches the happy_flutter convention', () {
      expect(OpenTelemetryService.serviceName, 'openwatch');
    });
  });
}
