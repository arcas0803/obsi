import '../api/span.dart';

/// Represents span exporter.
abstract interface class SpanExporter {
  /// Performs export.
  Future<void> export(List<SpanData> spans);

  /// Performs shutdown.
  Future<void> shutdown();
}
