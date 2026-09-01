import 'dart:convert';

import '../common/console_formatting.dart';
import 'metric_api.dart';

/// Represents console metric exporter.
final class ConsoleMetricExporter implements MetricExporter {
  /// Creates an exporter that writes one JSON object per metric.
  const ConsoleMetricExporter({this.writer})
    : _pretty = false,
      options = const PrettyConsoleOptions();

  /// Creates an exporter optimized for human-readable development output.
  const ConsoleMetricExporter.pretty({
    this.options = const PrettyConsoleOptions(),
    this.writer,
  }) : _pretty = true;

  final bool _pretty;

  /// Presentation settings used in pretty mode.
  final PrettyConsoleOptions options;

  /// Optional destination used instead of [print].
  final ConsoleWriter? writer;

  /// Performs export.
  @override
  Future<void> export(List<MetricData> metrics) async {
    for (final metric in metrics) {
      final message = _pretty
          ? _prettyMetric(metric, options)
          : jsonEncode({
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
            });
      if (writer case final output?) {
        output(message);
      } else {
        // ignore: avoid_print
        print(message);
      }
    }
  }

  /// Performs shutdown.
  @override
  Future<void> shutdown() async {}
}

String _prettyMetric(MetricData metric, PrettyConsoleOptions options) {
  final printer = ConsolePrettyPrinter(options);
  final timestamp = metric.points.isEmpty
      ? DateTime.now()
      : metric.points
            .map((point) => point.timestamp)
            .reduce((latest, value) => value.isAfter(latest) ? value : latest);
  final qualifiers = <String>[
    metric.kind.name,
    if (metric.unit != null && metric.unit!.isNotEmpty) metric.unit!,
    if (metric.temporality != null) metric.temporality!.name,
  ];
  final buffer = StringBuffer(
    printer.heading(
      timestamp: timestamp,
      label: 'METRIC',
      message: '${metric.name} · ${qualifiers.join(' · ')}',
      scope: metric.instrumentationScope.name,
      scopeVersion: metric.instrumentationScope.version,
      color: consoleDebugColor,
    ),
  );
  printer.detail(buffer, 'description', metric.description);
  if (metric.points.isEmpty) {
    printer.detail(buffer, 'points', 'none');
  } else {
    printer.block(
      buffer,
      'points',
      metric.points.expand(
        (point) => _prettyPoint(point, metric.unit, printer),
      ),
    );
  }
  printer.resource(buffer, metric.resource.attributes);
  return buffer.toString();
}

Iterable<String> _prettyPoint(
  MetricPoint point,
  String? unit,
  ConsolePrettyPrinter printer,
) sync* {
  final prefix = point.attributes.isEmpty
      ? ''
      : '{${printer.compactMap(point.attributes)}} ';
  final suffix = unit == null || unit.isEmpty || unit == '1' ? '' : ' $unit';
  if (point.value != null) {
    yield '$prefix${point.value}$suffix';
    return;
  }
  final summary = <String>[
    if (point.count != null) 'count=${point.count}',
    if (point.sum != null) 'sum=${point.sum}$suffix',
    if (point.min != null) 'min=${point.min}$suffix',
    if (point.max != null) 'max=${point.max}$suffix',
    if (point.count != null && point.count! > 0 && point.sum != null)
      'avg=${(point.sum! / point.count!).toStringAsFixed(2)}$suffix',
  ];
  yield '$prefix${summary.join(' ')}';
  if (point.bucketCounts.isNotEmpty) {
    for (var index = 0; index < point.bucketCounts.length; index++) {
      final boundary = index < point.boundaries.length
          ? '≤ ${point.boundaries[index]}$suffix'
          : '+Inf';
      yield '  ${boundary.padRight(18)} ${point.bucketCounts[index]}';
    }
  }
}
