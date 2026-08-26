import 'api/tracer.dart';
import 'errors/error_manager.dart';
import 'errors/errors.dart';
import 'logging/log_api.dart';
import 'logging/logger_provider.dart';
import 'logging/logs.dart';
import 'metrics/meter_provider.dart';
import 'metrics/metric_api.dart';
import 'metrics/metrics.dart';
import 'sdk/tracer_provider.dart';
import 'trace.dart';

/// Groups the signal providers that make up one Obsi installation.
///
/// This object owns every non-null provider supplied to it. Calling [shutdown]
/// drains and shuts those providers down concurrently.
final class ObsiProvider {
  /// Creates a provider from any combination of telemetry signals.
  ObsiProvider({this.traces, this.logs, this.metrics, this.errors});

  /// Provider used for tracing, or `null` when tracing is disabled.
  final TracerProvider? traces;

  /// Provider used for logging, or `null` when logging is disabled.
  final LoggerProvider? logs;

  /// Provider used for metrics, or `null` when metrics are disabled.
  final MeterProvider? metrics;

  /// Manager used for error reporting, or `null` when reporting is disabled.
  final ErrorManager? errors;
  Future<void>? _shutdownFuture;

  /// Waits concurrently for every configured signal to flush accepted data.
  Future<void> forceFlush() {
    final shutdown = _shutdownFuture;
    if (shutdown != null) return shutdown;
    return _flushSignals();
  }

  Future<void> _flushSignals() async {
    await Future.wait([
      if (traces != null) traces!.forceFlush(),
      if (logs != null) logs!.forceFlush(),
      if (metrics != null) metrics!.forceFlush(),
      if (errors != null) errors!.forceFlush(),
    ]);
  }

  /// Drains and shuts down every owned signal provider concurrently.
  ///
  /// Built-in providers make this operation idempotent.
  Future<void> shutdown() => _shutdownFuture ??= _shutdownSignals();

  Future<void> _shutdownSignals() async {
    await Future.wait([
      if (traces != null) traces!.shutdown(),
      if (logs != null) logs!.shutdown(),
      if (metrics != null) metrics!.shutdown(),
      if (errors != null) errors!.shutdown(),
    ]);
  }
}

/// Global facade for a process-wide Obsi installation.
///
/// Dart isolates do not share static state, so each isolate must be configured
/// independently.
final class Obsi {
  Obsi._();

  static ObsiProvider? _provider;
  static Future<void> _transitionTail = Future.value();
  static var _pendingTransitions = 0;

  /// Currently installed provider, or `null` when Obsi is disabled.
  static ObsiProvider? get provider => _provider;

  /// Current tracer, falling back to a no-op tracer when disabled.
  static Tracer get tracer => Trace.tracer;

  /// Installs [provider] without shutting down the previously installed one.
  ///
  /// Use [replace] when Obsi owns the previous provider and it must be drained.
  static void configure(ObsiProvider provider) {
    if (_pendingTransitions != 0) {
      throw StateError('Obsi is replacing or shutting down its provider');
    }
    _install(provider);
  }

  static void _install(ObsiProvider provider) {
    _provider = provider;
    final traces = provider.traces;
    traces == null ? Trace.disable() : Trace.configure(traces);
    final logs = provider.logs;
    logs == null ? Logs.disable() : Logs.configure(logs);
    final metrics = provider.metrics;
    metrics == null ? Metrics.disable() : Metrics.configure(metrics);
    final errors = provider.errors;
    errors == null ? Errors.disable() : Errors.configure(errors);
  }

  /// Detaches and shuts down the current provider, then installs [provider].
  static Future<void> replace(ObsiProvider provider) =>
      _enqueueTransition(() async {
        if (identical(_provider, provider)) return;
        final previous = _provider;
        _detach();
        await previous?.shutdown();
        _install(provider);
      });

  /// Returns a logger for [name], or a no-op logger when logging is disabled.
  static Logger logger(String name, {String? version}) =>
      Logs.getLogger(name, version: version);

  /// Returns a meter for [name], or `null` when metrics are disabled.
  static Meter? meter(String name, {String? version}) =>
      Metrics.getMeter(name, version: version);

  /// Detaches all global facades without flushing or shutting providers down.
  static void disable() {
    if (_pendingTransitions != 0) {
      throw StateError('Obsi is replacing or shutting down its provider');
    }
    _detach();
  }

  static void _detach() {
    _provider = null;
    Trace.disable();
    Logs.disable();
    Metrics.disable();
    Errors.disable();
  }

  /// Disables global telemetry immediately, then drains the previous provider.
  static Future<void> shutdown() => _enqueueTransition(() async {
    final current = _provider;
    _detach();
    await current?.shutdown();
  });

  static Future<void> _enqueueTransition(Future<void> Function() operation) {
    _pendingTransitions++;
    final scheduled = _transitionTail.then((_) => operation());
    final settled = scheduled.whenComplete(() => _pendingTransitions--);
    _transitionTail = settled.catchError((_) {});
    return settled;
  }
}
