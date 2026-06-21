import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/widgets.dart';
import 'package:flutterrific_opentelemetry/flutterrific_opentelemetry.dart'
    hide Logger;
import 'package:package_info_plus/package_info_plus.dart';

import 'app_log.dart';

/// Process-wide OpenTelemetry tracer.
///
/// Mirrors the happy_flutter integration so traces land in the same
/// collector (`otel.k2.k8s.best`).
///
/// * [serviceName] — `openwatch` (matches happy_flutter's `happy-flutter`)
/// * [endpoint] — `https://otel.k2.k8s.best`
/// * Tracing is enabled by default; metrics + logs + auto-log-events stay
///   off (matches happy_flutter).
///
/// A single-threaded "current span" pointer is maintained here because
/// the OTel package does not ship a `currentContext` helper. Long-running
/// listeners (BLE inbound frames, sync ticks) push a span, fan out child
/// spans, and pop when done. The HTTP interceptor (cloud API) reads it
/// to parent its outbound request span.
class OpenTelemetryService {
  factory OpenTelemetryService() => _instance;
  OpenTelemetryService._() : _routeObserver = _OpenWatchOtelRouteObserver();

  static final OpenTelemetryService _instance = OpenTelemetryService._();

  static const String serviceName = 'openwatch';
  static const String endpoint = 'https://otel.k2.k8s.best';
  static const bool tracingEnabledByDefault = true;
  static const bool metricsEnabled = false;
  static const bool logsEnabled = false;
  static const bool autoLogEventsEnabled = false;

  final NavigatorObserver _routeObserver;

  bool _initialized = false;
  bool _initFailed = false;
  String? _initErrorMessage;
  Future<void>? _initializeFuture;
  Future<void>? _trustedCertsFuture;
  _OpenWatchOtelLifecycleObserver? _lifecycleObserver;

  bool get isInitialized => _initialized;

  /// True if the last [initialize] attempt failed (e.g. OTLP handshake
  /// rejected, or the collector endpoint is unreachable). The Logs
  /// screen reads this to render a status banner.
  bool get initFailed => _initFailed;

  /// Human-readable failure message from the last [initialize] attempt,
  /// or null when init succeeded. Surfaced in the Logs screen so the
  /// user can see *why* spans never appeared.
  String? get initErrorMessage => _initErrorMessage;

  /// Static status string for the Logs screen: "active", "failed", or
  /// "pending" (init not yet attempted / still in flight).
  String get statusLabel {
    if (_initialized) return 'active';
    if (_initFailed) return 'failed';
    return 'pending';
  }

  NavigatorObserver get routeObserver => _routeObserver;

  final List<OTelSpan> _currentSpanStack = <OTelSpan>[];

  /// Returns the currently-active OTel span, or null when no span is
  /// active on this isolate.
  OTelSpan? get currentSpan =>
      _currentSpanStack.isEmpty ? null : _currentSpanStack.last;

  /// Push [span] onto the active span stack. The previously-active
  /// span (if any) is restored when [popCurrentSpan] is called.
  void pushCurrentSpan(OTelSpan span) {
    _currentSpanStack.add(span);
  }

  /// Pop the most recently pushed active span. Returns the span that
  /// was popped so callers can end it before/after the pop.
  OTelSpan? popCurrentSpan() {
    if (_currentSpanStack.isEmpty) return null;
    return _currentSpanStack.removeLast();
  }

  /// Run [body] with [span] set as the active span on this isolate.
  /// The previous active span (if any) is restored on return, even
  /// when [body] throws.
  Future<T> withActiveSpan<T>(OTelSpan span, Future<T> Function() body) async {
    pushCurrentSpan(span);
    try {
      return await body();
    } finally {
      popCurrentSpan();
    }
  }

  @visibleForTesting
  String get configuredEndpoint => endpoint;

  @visibleForTesting
  bool get configuredEnableMetrics => metricsEnabled;

  @visibleForTesting
  bool get configuredEnableLogs => logsEnabled;

  @visibleForTesting
  bool get configuredEnableAutoLogEvents => autoLogEventsEnabled;

  @visibleForTesting
  bool get configuredTracingEnabledByDefault => tracingEnabledByDefault;

  /// Wire up a future that resolves once the host's user-installed
  /// certificate store (e.g. Android user CA bundle, corporate MITM
  /// proxy) is loaded into [SecurityContext.defaultContext]. Mirrors
  /// happy_flutter — without this, the OTLP/HTTPS handshake rejects
  /// the collector's cert and `initialize()` fails silently (well,
  /// loudly in the Logs screen, but no spans ever make it out).
  void setTrustedCertificatesFuture(Future<void> future) {
    _trustedCertsFuture = future;
  }

  Future<void> initialize() async {
    if (_initialized) return;
    final existing = _initializeFuture;
    if (existing != null) return existing;

    final future = _initialize();
    _initializeFuture = future;
    return future;
  }

  Future<void> _initialize() async {
    if (_initialized) return;

    try {
      // Wait for the user-installed certificate store (if any) to be
      // loaded into SecurityContext.defaultContext. The certs plugin is
      // a platform-channel call that can take 100ms+; running it in
      // parallel with first frame is fine, but the OTLP handshake MUST
      // happen after.
      final certsFuture = _trustedCertsFuture;
      if (certsFuture != null) {
        AppLog.instance.debug('otel', 'awaiting user trusted certificates');
        try {
          await certsFuture;
        } catch (e, stack) {
          // Cert load failure is not fatal — log it and proceed; the
          // OTLP handshake will probably fail too, and the user will
          // see that in the Logs screen.
          AppLog.instance.error(
            'otel',
            'user trusted certificates failed to load: $e\n$stack',
          );
        }
      }

      // Hard-code a service version fallback in case PackageInfo fails
      // on a stubbed platform (e.g. tests). The package_info_plus call
      // is best-effort; a missing version shouldn't block tracer init.
      String version = '0.0.0';
      try {
        final info = await PackageInfo.fromPlatform();
        version = info.version;
      } catch (_) {
        // Ignore — fall back to hard-coded version.
      }

      await FlutterOTel.initialize(
        appName: serviceName,
        endpoint: endpoint,
        secure: true,
        serviceName: serviceName,
        serviceVersion: version,
        tracerName: 'openwatch',
        tracerVersion: version,
        spanProcessor: BatchSpanProcessor(
          OtlpHttpSpanExporter(OtlpHttpExporterConfig(endpoint: endpoint)),
        ),
        enableMetrics: metricsEnabled,
        enableLogs: logsEnabled,
        enableAutoLogEvents: autoLogEventsEnabled,
      );
      _replacePackageLifecycleObserver();
      _initialized = true;
      _initFailed = false;
      _initErrorMessage = null;
      AppLog.instance.info('otel', 'initialized endpoint=$endpoint');
    } catch (e, stack) {
      _initFailed = true;
      _initErrorMessage = e.toString();
      // ERROR level (not warn) so the Logs screen renders the failure
      // in red — a tracer that can't ship spans is operationally bad
      // and the user needs to see it at a glance.
      AppLog.instance.error('otel', 'initialization failed: $e\n$stack');
    } finally {
      _initializeFuture = null;
    }
  }

  Future<void> waitUntilReady({
    Duration timeout = const Duration(milliseconds: 750),
  }) async {
    if (_initialized) return;
    final future = _initializeFuture;
    if (future == null) return;
    try {
      await future.timeout(timeout);
    } on Object {
      // Tracing should never block BLE / sync startup. initialize() logs
      // failures, and timeouts simply mean the request proceeds untraced.
    }
  }

  void _replacePackageLifecycleObserver() {
    try {
      WidgetsBinding.instance.removeObserver(FlutterOTel.lifecycleObserver);
      FlutterOTel.lifecycleObserver.dispose();
    } catch (e, stack) {
      AppLog.instance.debug(
        'otel',
        'failed to remove package lifecycle observer: $e\n$stack',
      );
    }
    _lifecycleObserver ??= _OpenWatchOtelLifecycleObserver();
    WidgetsBinding.instance.addObserver(_lifecycleObserver!);
  }

  OTelSpan? startTrace(
    String name, {
    Map<String, Object?> attributes = const {},
    SpanKind kind = SpanKind.internal,
  }) {
    if (!_initialized) return null;
    try {
      final span = OTel.tracer().startSpan(
        name,
        context: Context.root,
        kind: kind,
        attributes: OTel.attributesFromMap(_safeAttributes(attributes)),
      );
      return OTelSpan._(span);
    } catch (e, stack) {
      // Span start failures are also at error level so a malformed
      // attribute or missing tracer shows up in the Logs screen.
      AppLog.instance.error('otel', 'failed to start trace $name: $e\n$stack');
      return null;
    }
  }

  OTelSpan? startChildSpan(
    String name, {
    OTelSpan? parent,
    Map<String, Object?> attributes = const {},
    SpanKind kind = SpanKind.internal,
  }) {
    if (!_initialized) return null;
    try {
      final span = OTel.tracer().startSpan(
        name,
        context: Context.root,
        parentSpan: parent?._span,
        kind: kind,
        attributes: OTel.attributesFromMap(_safeAttributes(attributes)),
      );
      return OTelSpan._(span);
    } catch (e, stack) {
      AppLog.instance.error(
        'otel',
        'failed to start child span $name: $e\n$stack',
      );
      return null;
    }
  }

  void recordRouteChange({
    required String action,
    Route<dynamic>? route,
    Route<dynamic>? previousRoute,
  }) {
    final routeName = _safeRouteName(route);
    final previousRouteName = _safeRouteName(previousRoute);
    final span = startTrace(
      'navigation.$action',
      kind: SpanKind.client,
      attributes: {
        'navigation.action': action,
        'route.name': routeName,
        'route.previous': ?previousRouteName,
        'current_route': routeName ?? previousRouteName,
      },
    );
    span?.end();
  }

  static String? _safeRouteName(Route<dynamic>? route) {
    final name = route?.settings.name;
    if (name == null || name.isEmpty) return null;
    return name;
  }

  static Map<String, Object> _safeAttributes(Map<String, Object?> values) {
    final safe = <String, Object>{};
    for (final entry in values.entries) {
      final value = entry.value;
      if (value == null) continue;
      if (value is String) {
        safe[entry.key] = value.length > 256
            ? '${value.substring(0, 253)}...'
            : value;
      } else if (value is bool || value is int || value is double) {
        safe[entry.key] = value;
      } else if (value is List<String> ||
          value is List<bool> ||
          value is List<int> ||
          value is List<double>) {
        safe[entry.key] = value;
      }
    }
    return safe;
  }
}

/// Lightweight wrapper around the underlying [Span] so call sites can
/// fluently set attributes, record exceptions, and end the span without
/// touching the OTel API surface directly.
class OTelSpan {
  OTelSpan._(this._span);

  final Span _span;

  SpanContext get spanContext => _span.spanContext;

  void setAttribute(String key, Object? value) {
    if (value == null || _span.isEnded) return;
    if (value is String) {
      final safeValue = value.length > 256
          ? '${value.substring(0, 253)}...'
          : value;
      _span.setStringAttribute(key, safeValue);
    } else if (value is bool) {
      _span.setBoolAttribute(key, value);
    } else if (value is int) {
      _span.setIntAttribute(key, value);
    } else if (value is double) {
      _span.setDoubleAttribute(key, value);
    }
  }

  /// Record [error] (and optional [stackTrace]) as a span exception and
  /// flip the span status to error. Safe to call multiple times — the
  /// span status is only set the first time.
  void recordError(Object error, [StackTrace? stackTrace]) {
    if (_span.isEnded) return;
    _span
      ..recordException(error, stackTrace: stackTrace)
      ..setStatus(SpanStatusCode.Error, error.runtimeType.toString());
  }

  /// End the span. Pass `ok: false` to mark it as error without supplying
  /// an exception object.
  void end({bool ok = true}) {
    if (_span.isEnded) return;
    _span.end(spanStatus: ok ? SpanStatusCode.Ok : SpanStatusCode.Error);
  }
}

/// Navigator observer that emits a span on every route push/pop/replace.
/// Mirrors happy_flutter's observer so traces show user navigation.
class _OpenWatchOtelRouteObserver extends NavigatorObserver {
  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    OpenTelemetryService().recordRouteChange(
      action: 'push',
      route: route,
      previousRoute: previousRoute,
    );
    super.didPush(route, previousRoute);
  }

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    OpenTelemetryService().recordRouteChange(
      action: 'pop',
      route: route,
      previousRoute: previousRoute,
    );
    super.didPop(route, previousRoute);
  }

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) {
    OpenTelemetryService().recordRouteChange(
      action: 'replace',
      route: newRoute,
      previousRoute: oldRoute,
    );
    super.didReplace(newRoute: newRoute, oldRoute: oldRoute);
  }

  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) {
    OpenTelemetryService().recordRouteChange(
      action: 'remove',
      route: route,
      previousRoute: previousRoute,
    );
    super.didRemove(route, previousRoute);
  }
}

/// Owns app-lifecycle spans. Replaces the package's default observer so
/// we can attach our own attributes (route context, BLE link state).
class _OpenWatchOtelLifecycleObserver with WidgetsBindingObserver {
  _OpenWatchOtelLifecycleObserver() {
    _recordLifecycleChange(null);
  }

  Uint8List? _currentLifecycleId;
  AppLifecycleStates? _currentLifecycleState;
  DateTime? _currentLifecycleStartTime;

  void _recordLifecycleChange(AppLifecycleState? state) {
    final startTime = DateTime.now();
    final newStateId = OTel.spanId().bytes;
    final previousState = _currentLifecycleState;
    final previousStartTime = _currentLifecycleStartTime;
    final duration = previousState != null && previousStartTime != null
        ? startTime.difference(previousStartTime)
        : null;
    final newState = state == null
        ? AppLifecycleStates.active
        : AppLifecycleStates.appLifecycleStateFor(state.name);

    FlutterOTel.tracer
        .startAppLifecycleSpan(
          newState: newState,
          startTime: startTime,
          newStateId: newStateId,
          previousState: previousState,
          previousStateId: _currentLifecycleId,
          previousStateDuration: duration,
        )
        .end();

    FlutterOTel.forceFlush();
    FlutterOTel.currentAppLifecycleId = newStateId;
    _currentLifecycleId = newStateId;
    _currentLifecycleState = newState;
    _currentLifecycleStartTime = startTime;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _recordLifecycleChange(state);
  }
}
