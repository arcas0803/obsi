import 'dart:convert';

import '../api/span.dart';
import 'span_exporter.dart';

/// Represents console span exporter.
final class ConsoleSpanExporter implements SpanExporter {
  /// Creates a instance.
  const ConsoleSpanExporter();

  /// Performs export.
  @override
  Future<void> export(List<SpanData> spans) async {
    for (final span in spans) {
      // ignore: avoid_print
      print(
        jsonEncode({
          'name': span.name,
          'traceId': span.context.traceId,
          'spanId': span.context.spanId,
          'parentSpanId': span.parentSpanId,
          'kind': span.kind.name,
          'status': span.status.name,
          'statusDescription': span.statusDescription,
          'startTime': span.startTime.toUtc().toIso8601String(),
          'endTime': span.endTime.toUtc().toIso8601String(),
          'durationMicros': span.duration.inMicroseconds,
          'attributes': span.attributes,
          'events': [
            for (final event in span.events)
              {
                'name': event.name,
                'timestamp': event.timestamp.toUtc().toIso8601String(),
                'attributes': event.attributes,
              },
          ],
        }),
      );
    }
  }

  /// Performs shutdown.
  @override
  Future<void> shutdown() async {}
}
