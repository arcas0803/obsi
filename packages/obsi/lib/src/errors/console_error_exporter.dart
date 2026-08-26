import 'dart:convert';

import 'error_api.dart';
import 'error_exporter.dart';

/// Represents console error exporter.
final class ConsoleErrorExporter implements ErrorExporter {
  /// Creates a instance.
  const ConsoleErrorExporter();

  /// Performs export.
  @override
  Future<void> export(ErrorReport report) async {
    // ignore: avoid_print
    print(
      jsonEncode({
        'id': report.id.value,
        'timestamp': report.timestamp.toUtc().toIso8601String(),
        'severity': report.severity.name,
        'fatal': report.fatal,
        'handled': report.handled,
        'mechanism': report.mechanism.name,
        'message': report.message,
        'stackTrace': report.stackTrace?.toString(),
        'traceId': report.spanContext?.traceId,
        'spanId': report.spanContext?.spanId,
        'tags': report.tags,
        'attributes': report.attributes,
        'contexts': report.contexts,
        'resource': report.resource.attributes,
        'scope': report.instrumentationScope.name,
        'breadcrumbs': [
          for (final breadcrumb in report.breadcrumbs)
            {
              'timestamp': breadcrumb.timestamp.toUtc().toIso8601String(),
              'category': breadcrumb.category,
              'message': breadcrumb.message,
              'level': breadcrumb.level.name,
              'data': breadcrumb.data,
            },
        ],
      }),
    );
  }

  /// Performs force flush.
  @override
  Future<void> forceFlush() async {}

  /// Performs shutdown.
  @override
  Future<void> shutdown() async {}
}
