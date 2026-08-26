import '../api/span.dart';
import '../common/diagnostics.dart';
import '../export/span_exporter.dart';
import 'span_processor.dart';

/// Represents simple span processor.
final class SimpleSpanProcessor implements SpanProcessor {
  /// Creates a instance.
  SimpleSpanProcessor(
    this.exporter, {
    this.maxPendingExports = 2048,
    this.exportTimeout = const Duration(seconds: 30),
    this.onExportError,
  }) {
    if (maxPendingExports <= 0) {
      throw ArgumentError.value(maxPendingExports, 'maxPendingExports');
    }
    validateTelemetryTimeout(exportTimeout, 'exportTimeout');
  }

  /// The exporter.
  final SpanExporter exporter;

  /// The on export error.
  final TelemetryErrorHandler? onExportError;

  /// The max pending exports.
  final int maxPendingExports;

  /// The export timeout.
  final Duration? exportTimeout;
  final Set<Future<void>> _pending = {};
  bool _isShutdown = false;
  int _droppedSpans = 0;
  int _exportFailures = 0;

  /// The pending exports.
  int get pendingExports => _pending.length;

  /// The dropped spans.
  int get droppedSpans => _droppedSpans;

  /// The export failures.
  int get exportFailures => _exportFailures;

  /// Performs on start.
  @override
  void onStart(Span span) {}

  /// Performs on end.
  @override
  void onEnd(SpanData span) {
    if (_isShutdown) return;
    if (_pending.length >= maxPendingExports) {
      _droppedSpans++;
      return;
    }
    late final Future<void> operation;
    operation =
        runTelemetryOperation(
              () => exporter.export([span]),
              timeout: exportTimeout,
            )
            .catchError((Object error, StackTrace stackTrace) {
              _exportFailures++;
              reportTelemetryError(onExportError, error, stackTrace);
            })
            .whenComplete(() => _pending.remove(operation));
    _pending.add(operation);
  }

  /// Performs force flush.
  @override
  Future<void> forceFlush() async {
    while (_pending.isNotEmpty) {
      await Future.wait(_pending.toList(growable: false));
    }
  }

  Future<void>? _shutdownFuture;

  /// Performs shutdown.
  @override
  Future<void> shutdown() => _shutdownFuture ??= _doShutdown();

  Future<void> _doShutdown() async {
    _isShutdown = true;
    await forceFlush();
    try {
      await runTelemetryOperation(exporter.shutdown, timeout: exportTimeout);
    } catch (error, stackTrace) {
      _exportFailures++;
      reportTelemetryError(onExportError, error, stackTrace);
    }
  }
}
