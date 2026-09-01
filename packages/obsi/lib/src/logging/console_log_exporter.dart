import 'dart:convert';

import '../common/console_formatting.dart';
import 'log_api.dart';
import 'log_exporter.dart';

/// Represents console log exporter.
final class ConsoleLogExporter implements LogExporter {
  /// Creates an exporter that writes one JSON object per log record.
  const ConsoleLogExporter({this.writer})
    : _pretty = false,
      options = const PrettyConsoleOptions();

  /// Creates an exporter optimized for human-readable development output.
  const ConsoleLogExporter.pretty({
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
  Future<void> export(List<LogRecord> records) async {
    for (final record in records) {
      final message = _pretty ? _prettyLog(record, options) : _jsonLog(record);
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

String _jsonLog(LogRecord record) => jsonEncode({
  'timestamp': record.timestamp.toUtc().toIso8601String(),
  'severity': record.severity.name,
  'body': record.body?.toString(),
  'traceId': record.spanContext?.traceId,
  'spanId': record.spanContext?.spanId,
  'attributes': record.attributes,
  'resource': record.resource.attributes,
  'scope': record.instrumentationScope.name,
  if (record.error != null) 'error': record.error.toString(),
  if (record.stackTrace != null) 'stackTrace': record.stackTrace.toString(),
});

String _prettyLog(LogRecord record, PrettyConsoleOptions options) {
  final printer = ConsolePrettyPrinter(options);
  final (label, color) = switch (record.severity) {
    LogSeverity.trace => ('TRACE', consoleTraceColor),
    LogSeverity.debug => ('DEBUG', consoleDebugColor),
    LogSeverity.info => ('INFO', consoleInfoColor),
    LogSeverity.warn => ('WARN', consoleWarningColor),
    LogSeverity.error => ('ERROR', consoleErrorColor),
    LogSeverity.fatal => ('FATAL', consoleFatalColor),
  };
  final body = record.body?.toString() ?? 'null';
  final message = !options.multilineAttributes && record.attributes.isNotEmpty
      ? '$body · ${printer.compactMap(record.attributes)}'
      : body;
  final buffer = StringBuffer(
    printer.heading(
      timestamp: record.timestamp,
      label: label,
      message: message,
      scope: record.instrumentationScope.name,
      scopeVersion: record.instrumentationScope.version,
      color: color,
    ),
  );
  if (options.multilineAttributes) {
    printer.attributes(buffer, record.attributes);
  }
  if (options.includeTraceContext && record.spanContext != null) {
    printer.detail(
      buffer,
      'trace',
      '${printer.identifier(record.spanContext!.traceId)} / '
          '${printer.identifier(record.spanContext!.spanId)}',
    );
  }
  printer.detail(buffer, 'error', record.error);
  if (options.includeStackTrace && record.stackTrace != null) {
    printer.block(
      buffer,
      'stack',
      record.stackTrace.toString().trim().split('\n'),
    );
  }
  printer.resource(buffer, record.resource.attributes);
  return buffer.toString();
}
