import 'dart:convert';

import '../api/span.dart';
import '../common/console_formatting.dart';
import 'span_exporter.dart';

/// Represents console span exporter.
final class ConsoleSpanExporter implements SpanExporter {
  /// Creates an exporter that writes one JSON object per span.
  const ConsoleSpanExporter({this.writer})
    : _pretty = false,
      options = const PrettyConsoleOptions();

  /// Creates an exporter optimized for human-readable development output.
  const ConsoleSpanExporter.pretty({
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
  Future<void> export(List<SpanData> spans) async {
    for (final span in spans) {
      final message = _pretty
          ? _prettySpan(span, options)
          : jsonEncode({
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

String _prettySpan(SpanData span, PrettyConsoleOptions options) {
  final printer = ConsolePrettyPrinter(options);
  final (symbol, color) = switch (span.status) {
    SpanStatus.ok => ('✓', consoleInfoColor),
    SpanStatus.error => ('✗', consoleErrorColor),
    SpanStatus.unset => ('•', consoleDebugColor),
  };
  final duration = _formatDuration(span.duration);
  final buffer = StringBuffer(
    printer.heading(
      timestamp: span.endTime,
      label: 'SPAN',
      message: '$symbol ${span.name} · ${span.kind.name} · $duration',
      scope: span.instrumentationScope.name,
      scopeVersion: span.instrumentationScope.version,
      color: color,
    ),
  );
  if (span.statusDescription != null) {
    printer.detail(buffer, 'status', span.statusDescription);
  }
  if (options.includeTraceContext) {
    printer.detail(
      buffer,
      'trace',
      '${printer.identifier(span.context.traceId)} / '
          '${printer.identifier(span.context.spanId)}',
    );
    if (span.parentSpanId != null) {
      printer.detail(buffer, 'parent', printer.identifier(span.parentSpanId!));
    }
  }
  printer.attributes(buffer, span.attributes);
  if (span.events.isNotEmpty) {
    printer.block(
      buffer,
      'events',
      span.events.map((event) {
        final offset = event.timestamp.difference(span.startTime);
        final attributes = event.attributes.isEmpty
            ? ''
            : ' · ${printer.compactMap(event.attributes)}';
        return '+${_formatDuration(offset).padLeft(9)}  '
            '${event.name}$attributes';
      }),
    );
  }
  if (span.links.isNotEmpty) {
    printer.block(
      buffer,
      'links',
      span.links.map(
        (link) =>
            '${printer.identifier(link.context.traceId)} / '
            '${printer.identifier(link.context.spanId)}'
            '${link.attributes.isEmpty ? '' : ' · ${printer.compactMap(link.attributes)}'}',
      ),
    );
  }
  final dropped = <String>[
    if (span.droppedAttributes > 0) 'attributes=${span.droppedAttributes}',
    if (span.droppedEvents > 0) 'events=${span.droppedEvents}',
    if (span.droppedLinks > 0) 'links=${span.droppedLinks}',
  ];
  if (dropped.isNotEmpty) printer.detail(buffer, 'dropped', dropped.join(' '));
  printer.resource(buffer, span.resource.attributes);
  return buffer.toString();
}

String _formatDuration(Duration duration) {
  if (duration.inMicroseconds < 1000) return '${duration.inMicroseconds} µs';
  if (duration.inMilliseconds < 1000) {
    return '${(duration.inMicroseconds / 1000).toStringAsFixed(2)} ms';
  }
  return '${(duration.inMicroseconds / Duration.microsecondsPerSecond).toStringAsFixed(2)} s';
}
