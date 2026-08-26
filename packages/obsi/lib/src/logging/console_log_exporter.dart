import 'dart:convert';

import 'log_api.dart';
import 'log_exporter.dart';

/// Represents console log exporter.
final class ConsoleLogExporter implements LogExporter {
  /// Creates a instance.
  const ConsoleLogExporter();

  /// Performs export.
  @override
  Future<void> export(List<LogRecord> records) async {
    for (final record in records) {
      // ignore: avoid_print
      print(
        jsonEncode({
          'timestamp': record.timestamp.toUtc().toIso8601String(),
          'severity': record.severity.name,
          'body': record.body?.toString(),
          'traceId': record.spanContext?.traceId,
          'spanId': record.spanContext?.spanId,
          'attributes': record.attributes,
          'resource': record.resource.attributes,
          'scope': record.instrumentationScope.name,
          if (record.error != null) 'error': record.error.toString(),
          if (record.stackTrace != null)
            'stackTrace': record.stackTrace.toString(),
        }),
      );
    }
  }

  /// Performs shutdown.
  @override
  Future<void> shutdown() async {}
}
