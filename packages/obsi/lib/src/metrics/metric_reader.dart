import 'dart:async';

import '../common/diagnostics.dart';
import 'metric_api.dart';

/// Represents manual metric reader.
final class ManualMetricReader implements MetricReader {
  /// Creates a instance.
  ManualMetricReader(
    this.exporter, {
    this.exportTimeout = const Duration(seconds: 30),
    this.onExportError,
  }) {
    validateTelemetryTimeout(exportTimeout, 'exportTimeout');
  }

  /// The exporter.
  final MetricExporter exporter;

  /// The on export error.
  final TelemetryErrorHandler? onExportError;

  /// The export timeout.
  final Duration? exportTimeout;
  MetricProducer? _producer;
  Future<void> _tail = Future.value();
  bool _shutdown = false;

  /// Performs bind.
  @override
  void bind(MetricProducer producer) {
    if (_producer != null) throw StateError('MetricReader is already bound');
    if (_shutdown) throw StateError('MetricReader is shut down');
    _producer = producer;
  }

  /// Performs collect.
  Future<void> collect() {
    if (_shutdown) return Future.value();
    return _enqueueCollection();
  }

  Future<void> _enqueueCollection() {
    _tail = _tail
        .then((_) async {
          final metrics = _producer?.collect() ?? const <MetricData>[];
          if (metrics.isNotEmpty) {
            await runTelemetryOperation(
              () => exporter.export(metrics),
              timeout: exportTimeout,
            );
          }
        })
        .catchError((Object error, StackTrace stackTrace) {
          reportTelemetryError(onExportError, error, stackTrace);
        });
    return _tail;
  }

  /// Performs force flush.
  @override
  Future<void> forceFlush() => collect();

  Future<void>? _shutdownFuture;

  /// Performs shutdown.
  @override
  Future<void> shutdown() => _shutdownFuture ??= _doShutdown();

  Future<void> _doShutdown() async {
    _shutdown = true;
    await _enqueueCollection();
    try {
      await runTelemetryOperation(exporter.shutdown, timeout: exportTimeout);
    } catch (error, stackTrace) {
      reportTelemetryError(onExportError, error, stackTrace);
    }
  }
}

/// Represents periodic metric reader.
final class PeriodicMetricReader implements MetricReader {
  /// Creates a instance.
  PeriodicMetricReader(
    this.exporter, {
    this.interval = const Duration(seconds: 60),
    this.exportTimeout = const Duration(seconds: 30),
    this.onExportError,
  }) {
    if (interval <= Duration.zero) {
      throw ArgumentError.value(interval, 'interval');
    }
    validateTelemetryTimeout(exportTimeout, 'exportTimeout');
  }

  /// The exporter.
  final MetricExporter exporter;

  /// The interval.
  final Duration interval;

  /// The export timeout.
  final Duration? exportTimeout;

  /// The on export error.
  final TelemetryErrorHandler? onExportError;
  MetricProducer? _producer;
  Timer? _timer;
  Future<void> _tail = Future.value();
  bool _shutdown = false;

  /// Performs bind.
  @override
  void bind(MetricProducer producer) {
    if (_producer != null) throw StateError('MetricReader is already bound');
    if (_shutdown) throw StateError('MetricReader is shut down');
    _producer = producer;
    _timer ??= Timer.periodic(interval, (_) => _schedule());
  }

  void _schedule() {
    if (_shutdown) return;
    _tail = _tail
        .then((_) async {
          final metrics = _producer?.collect() ?? const <MetricData>[];
          if (metrics.isNotEmpty) {
            await runTelemetryOperation(
              () => exporter.export(metrics),
              timeout: exportTimeout,
            );
          }
        })
        .catchError((Object error, StackTrace stackTrace) {
          reportTelemetryError(onExportError, error, stackTrace);
        });
  }

  /// Performs force flush.
  @override
  Future<void> forceFlush() async {
    _schedule();
    await _tail;
  }

  Future<void>? _shutdownFuture;

  /// Performs shutdown.
  @override
  Future<void> shutdown() => _shutdownFuture ??= _doShutdown();

  Future<void> _doShutdown() async {
    _timer?.cancel();
    _shutdown = true;
    _tail = _tail
        .then((_) async {
          final metrics = _producer?.collect() ?? const <MetricData>[];
          if (metrics.isNotEmpty) {
            await runTelemetryOperation(
              () => exporter.export(metrics),
              timeout: exportTimeout,
            );
          }
        })
        .catchError((Object error, StackTrace stackTrace) {
          reportTelemetryError(onExportError, error, stackTrace);
        });
    await _tail;
    try {
      await runTelemetryOperation(exporter.shutdown, timeout: exportTimeout);
    } catch (error, stackTrace) {
      reportTelemetryError(onExportError, error, stackTrace);
    }
  }
}
