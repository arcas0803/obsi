import '../api/span.dart';

/// Represents span processor.
abstract interface class SpanProcessor {
  /// Performs on start.
  void onStart(Span span);

  /// Performs on end.
  void onEnd(SpanData span);

  /// Performs force flush.
  Future<void> forceFlush();

  /// Performs shutdown.
  Future<void> shutdown();
}
