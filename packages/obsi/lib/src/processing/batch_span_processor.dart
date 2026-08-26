import 'dart:async';
import 'dart:collection';

import '../api/span.dart';
import '../common/diagnostics.dart';
import '../export/span_exporter.dart';
import 'span_processor.dart';

/// Represents batch span processor.
final class BatchSpanProcessor implements SpanProcessor {
  /// Creates a instance.
  BatchSpanProcessor(
    this.exporter, {
    this.maxQueueSize = 2048,
    this.maxExportBatchSize = 512,
    this.scheduledDelay = const Duration(seconds: 5),
    this.exportTimeout = const Duration(seconds: 30),
    this.onExportError,
  }) {
    if (maxQueueSize <= 0 || maxExportBatchSize <= 0) {
      throw ArgumentError('Queue and batch sizes must be positive');
    }
    if (maxExportBatchSize > maxQueueSize) {
      throw ArgumentError('Batch size cannot exceed queue size');
    }
    if (scheduledDelay <= Duration.zero) {
      throw ArgumentError.value(scheduledDelay, 'scheduledDelay');
    }
    validateTelemetryTimeout(exportTimeout, 'exportTimeout');
    _timer = Timer.periodic(scheduledDelay, (_) => _scheduleExport());
  }

  /// The exporter.
  final SpanExporter exporter;

  /// The max queue size.
  final int maxQueueSize;

  /// The max export batch size.
  final int maxExportBatchSize;

  /// The scheduled delay.
  final Duration scheduledDelay;

  /// The export timeout.
  final Duration? exportTimeout;

  /// The on export error.
  final TelemetryErrorHandler? onExportError;
  final Queue<SpanData> _queue = Queue();
  Future<void> _exportTail = Future.value();
  Timer? _timer;
  bool _isShutdown = false;
  int _droppedSpans = 0;
  int _exportFailures = 0;
  int _pendingSpans = 0;

  /// The dropped spans.
  int get droppedSpans => _droppedSpans;

  /// The queue size.
  int get queueSize => _queue.length + _pendingSpans;

  /// The export failures.
  int get exportFailures => _exportFailures;

  /// Performs on start.
  @override
  void onStart(Span span) {}

  /// Performs on end.
  @override
  void onEnd(SpanData span) {
    if (_isShutdown) return;
    if (queueSize >= maxQueueSize) {
      _droppedSpans++;
      return;
    }
    _queue.addLast(span);
    if (_queue.length >= maxExportBatchSize) _scheduleExport();
  }

  void _scheduleExport() {
    if (_queue.isEmpty) return;
    final batch = <SpanData>[];
    while (batch.length < maxExportBatchSize && _queue.isNotEmpty) {
      batch.add(_queue.removeFirst());
    }
    _pendingSpans += batch.length;
    _exportTail = _exportTail
        .then(
          (_) => runTelemetryOperation(
            () => exporter.export(batch),
            timeout: exportTimeout,
          ),
        )
        .catchError((Object error, StackTrace stackTrace) {
          _exportFailures++;
          reportTelemetryError(onExportError, error, stackTrace);
        })
        .whenComplete(() => _pendingSpans -= batch.length);
  }

  /// Performs force flush.
  @override
  Future<void> forceFlush() async {
    while (_queue.isNotEmpty) {
      _scheduleExport();
    }
    await _exportTail;
  }

  Future<void>? _shutdownFuture;

  /// Performs shutdown.
  @override
  Future<void> shutdown() => _shutdownFuture ??= _doShutdown();

  Future<void> _doShutdown() async {
    _isShutdown = true;
    _timer?.cancel();
    await forceFlush();
    try {
      await runTelemetryOperation(exporter.shutdown, timeout: exportTimeout);
    } catch (error, stackTrace) {
      _exportFailures++;
      reportTelemetryError(onExportError, error, stackTrace);
    }
  }
}
