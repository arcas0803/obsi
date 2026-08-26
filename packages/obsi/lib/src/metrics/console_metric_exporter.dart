import 'dart:convert';

import 'metric_api.dart';

/// Represents console metric exporter.
final class ConsoleMetricExporter implements MetricExporter {
  /// Creates a instance.
  const ConsoleMetricExporter();

  /// Performs export.
  @override
  Future<void> export(List<MetricData> metrics) async {
    for (final metric in metrics) {
      // ignore: avoid_print
      print(
        jsonEncode({
          'name': metric.name,
          'kind': metric.kind.name,
          'unit': metric.unit,
          'resource': metric.resource.attributes,
          'scope': metric.instrumentationScope.name,
          'points': [
            for (final point in metric.points)
              {
                'attributes': point.attributes,
                'timestamp': point.timestamp.toUtc().toIso8601String(),
                'value': point.value,
                'count': point.count,
                'sum': point.sum,
                'min': point.min,
                'max': point.max,
                'boundaries': point.boundaries,
                'bucketCounts': point.bucketCounts,
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
