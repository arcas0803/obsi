import '../api/span.dart';
import '../common/diagnostics.dart';
import 'span_processor.dart';

/// Represents multi span processor.
final class MultiSpanProcessor implements SpanProcessor {
  /// Creates a instance.
  MultiSpanProcessor(Iterable<SpanProcessor> processors, {this.onInternalError})
    : processors = List.unmodifiable(processors);

  /// The processors.
  final List<SpanProcessor> processors;

  /// The on internal error.
  final TelemetryErrorHandler? onInternalError;
  bool _isShutdown = false;
  Future<void>? _shutdownFuture;

  /// Performs on start.
  @override
  void onStart(Span span) {
    if (_isShutdown) return;
    for (final processor in processors) {
      try {
        processor.onStart(span);
      } catch (error, stackTrace) {
        reportTelemetryError(onInternalError, error, stackTrace);
      }
    }
  }

  /// Performs on end.
  @override
  void onEnd(SpanData span) {
    if (_isShutdown) return;
    for (final processor in processors) {
      try {
        processor.onEnd(span);
      } catch (error, stackTrace) {
        reportTelemetryError(onInternalError, error, stackTrace);
      }
    }
  }

  /// Performs force flush.
  @override
  Future<void> forceFlush() => _shutdownFuture ?? _flushAll();

  Future<void> _flushAll() async {
    await Future.wait([for (final processor in processors) _flush(processor)]);
  }

  /// Performs shutdown.
  @override
  Future<void> shutdown() => _shutdownFuture ??= _doShutdown();

  Future<void> _doShutdown() async {
    _isShutdown = true;
    await _flushAll();
    await Future.wait([
      for (final processor in processors) _shutdown(processor),
    ]);
  }

  Future<void> _flush(SpanProcessor processor) async {
    try {
      await processor.forceFlush();
    } catch (error, stackTrace) {
      reportTelemetryError(onInternalError, error, stackTrace);
    }
  }

  Future<void> _shutdown(SpanProcessor processor) async {
    try {
      await processor.shutdown();
    } catch (error, stackTrace) {
      reportTelemetryError(onInternalError, error, stackTrace);
    }
  }
}
