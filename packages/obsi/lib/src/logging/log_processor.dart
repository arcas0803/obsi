import 'dart:async';
import 'dart:collection';

import '../common/diagnostics.dart';
import 'log_api.dart';
import 'log_exporter.dart';

/// Represents log processor.
abstract interface class LogProcessor {
  /// Performs emit.
  void emit(LogRecord record);

  /// Performs force flush.
  Future<void> forceFlush();

  /// Performs shutdown.
  Future<void> shutdown();
}

/// Represents simple log processor.
final class SimpleLogProcessor implements LogProcessor {
  /// Creates a instance.
  SimpleLogProcessor(
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
  final LogExporter exporter;

  /// The on export error.
  final TelemetryErrorHandler? onExportError;

  /// The max pending exports.
  final int maxPendingExports;

  /// The export timeout.
  final Duration? exportTimeout;
  final Set<Future<void>> _pending = {};
  bool _shutdown = false;
  int _droppedRecords = 0;
  int _exportFailures = 0;

  /// The pending exports.
  int get pendingExports => _pending.length;

  /// The dropped records.
  int get droppedRecords => _droppedRecords;

  /// The export failures.
  int get exportFailures => _exportFailures;

  /// Performs emit.
  @override
  void emit(LogRecord record) {
    if (_shutdown) return;
    if (_pending.length >= maxPendingExports) {
      _droppedRecords++;
      return;
    }
    late final Future<void> operation;
    operation =
        runTelemetryOperation(
              () => exporter.export([record]),
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
    _shutdown = true;
    await forceFlush();
    try {
      await runTelemetryOperation(exporter.shutdown, timeout: exportTimeout);
    } catch (error, stackTrace) {
      _exportFailures++;
      reportTelemetryError(onExportError, error, stackTrace);
    }
  }
}

/// Represents multi log processor.
final class MultiLogProcessor implements LogProcessor {
  /// Creates a instance.
  MultiLogProcessor(Iterable<LogProcessor> processors, {this.onInternalError})
    : processors = List.unmodifiable(processors);

  /// The processors.
  final List<LogProcessor> processors;

  /// The on internal error.
  final TelemetryErrorHandler? onInternalError;
  bool _shutdown = false;
  Future<void>? _shutdownFuture;

  /// Performs emit.
  @override
  void emit(LogRecord record) {
    if (_shutdown) return;
    for (final processor in processors) {
      try {
        processor.emit(record);
      } catch (error, stackTrace) {
        reportTelemetryError(onInternalError, error, stackTrace);
      }
    }
  }

  /// Performs force flush.
  @override
  Future<void> forceFlush() => _shutdownFuture ?? _flushAll();

  Future<void> _flushAll() =>
      Future.wait([for (final processor in processors) _flush(processor)]);

  /// Performs shutdown.
  @override
  Future<void> shutdown() => _shutdownFuture ??= _doShutdown();

  Future<void> _doShutdown() async {
    _shutdown = true;
    await _flushAll();
    await Future.wait([
      for (final processor in processors) _shutdownProcessor(processor),
    ]);
  }

  Future<void> _flush(LogProcessor processor) async {
    try {
      await processor.forceFlush();
    } catch (error, stackTrace) {
      reportTelemetryError(onInternalError, error, stackTrace);
    }
  }

  Future<void> _shutdownProcessor(LogProcessor processor) async {
    try {
      await processor.shutdown();
    } catch (error, stackTrace) {
      reportTelemetryError(onInternalError, error, stackTrace);
    }
  }
}

/// Represents batch log processor.
final class BatchLogProcessor implements LogProcessor {
  /// Creates a instance.
  BatchLogProcessor(
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
  final LogExporter exporter;

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
  final Queue<LogRecord> _queue = Queue();
  Future<void> _exportTail = Future.value();
  Timer? _timer;
  bool _shutdown = false;
  int _droppedRecords = 0;
  int _exportFailures = 0;
  int _pendingRecords = 0;

  /// The dropped records.
  int get droppedRecords => _droppedRecords;

  /// The queue size.
  int get queueSize => _queue.length + _pendingRecords;

  /// The export failures.
  int get exportFailures => _exportFailures;

  /// Performs emit.
  @override
  void emit(LogRecord record) {
    if (_shutdown) return;
    if (queueSize >= maxQueueSize) {
      _droppedRecords++;
      return;
    }
    _queue.addLast(record);
    if (_queue.length >= maxExportBatchSize) _scheduleExport();
  }

  void _scheduleExport() {
    if (_queue.isEmpty) return;
    final batch = <LogRecord>[];
    while (batch.length < maxExportBatchSize && _queue.isNotEmpty) {
      batch.add(_queue.removeFirst());
    }
    _pendingRecords += batch.length;
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
        .whenComplete(() => _pendingRecords -= batch.length);
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
    _shutdown = true;
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
