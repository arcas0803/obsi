import 'log_api.dart';

/// Represents log exporter.
abstract interface class LogExporter {
  /// Performs export.
  Future<void> export(List<LogRecord> records);

  /// Performs shutdown.
  Future<void> shutdown();
}
