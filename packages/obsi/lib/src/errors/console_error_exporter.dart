import 'dart:convert';

import '../common/console_formatting.dart';
import 'error_api.dart';
import 'error_exporter.dart';

/// Represents console error exporter.
final class ConsoleErrorExporter implements ErrorExporter {
  /// Creates an exporter that writes one JSON object per error report.
  const ConsoleErrorExporter({this.writer})
    : _pretty = false,
      options = const PrettyConsoleOptions();

  /// Creates an exporter optimized for human-readable development output.
  const ConsoleErrorExporter.pretty({
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
  Future<void> export(ErrorReport report) async {
    final message = _pretty
        ? _prettyError(report, options)
        : jsonEncode({
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
          });
    if (writer case final output?) {
      output(message);
    } else {
      // ignore: avoid_print
      print(message);
    }
  }

  /// Performs force flush.
  @override
  Future<void> forceFlush() async {}

  /// Performs shutdown.
  @override
  Future<void> shutdown() async {}
}

String _prettyError(ErrorReport report, PrettyConsoleOptions options) {
  final printer = ConsolePrettyPrinter(options);
  final color = switch (report.severity) {
    ErrorSeverity.debug => consoleDebugColor,
    ErrorSeverity.info => consoleInfoColor,
    ErrorSeverity.warning => consoleWarningColor,
    ErrorSeverity.error => consoleErrorColor,
    ErrorSeverity.fatal => consoleFatalColor,
  };
  final buffer = StringBuffer(
    printer.heading(
      timestamp: report.timestamp,
      label: report.severity.name.toUpperCase(),
      message: '✗ ${report.message}',
      scope: report.instrumentationScope.name,
      scopeVersion: report.instrumentationScope.version,
      color: color,
    ),
  );
  printer.detail(buffer, 'id', report.id.value);
  printer.detail(buffer, 'exception', report.exception);
  printer.detail(buffer, 'handled', report.handled);
  printer.detail(buffer, 'fatal', report.fatal);
  printer.detail(buffer, 'mechanism', report.mechanism.name);
  printer.detail(buffer, 'reason', report.reason);
  if (options.includeTraceContext && report.spanContext != null) {
    printer.detail(
      buffer,
      'trace',
      '${printer.identifier(report.spanContext!.traceId)} / '
          '${printer.identifier(report.spanContext!.spanId)}',
    );
  }
  printer.attributes(buffer, report.attributes);
  if (report.tags.isNotEmpty) {
    printer.attributes(buffer, report.tags, label: 'tags');
  }
  if (report.contexts.isNotEmpty) {
    printer.block(
      buffer,
      'contexts',
      report.contexts.entries.map(
        (entry) => '${entry.key}: ${printer.compactMap(entry.value)}',
      ),
    );
  }
  if (report.breadcrumbs.isNotEmpty) {
    printer.block(
      buffer,
      'breadcrumbs',
      report.breadcrumbs.map((breadcrumb) {
        final offset = breadcrumb.timestamp.difference(report.timestamp);
        final data = breadcrumb.data.isEmpty
            ? ''
            : ' · ${printer.compactMap(breadcrumb.data)}';
        return '${_formatBreadcrumbOffset(offset)} '
            '${breadcrumb.level.name.toUpperCase().padRight(7)} '
            '[${breadcrumb.category}] ${breadcrumb.message ?? ''}$data';
      }),
    );
  }
  if (report.fingerprint.isNotEmpty) {
    printer.detail(buffer, 'fingerprint', report.fingerprint.join(', '));
  }
  if (report.attachments.isNotEmpty) {
    printer.block(
      buffer,
      'attachments',
      report.attachments.map(
        (attachment) =>
            '${attachment.filename} · ${attachment.contentType} · '
            '${attachment.bytes.length} bytes',
      ),
    );
  }
  if (report.user != null) {
    final user = report.user!;
    final values = <String, Object?>{
      if (user.id != null) 'id': user.id,
      if (user.email != null) 'email': user.email,
      if (user.username != null) 'username': user.username,
      if (user.ipAddress != null) 'ip': user.ipAddress,
      ...user.data,
    };
    printer.attributes(buffer, values, label: 'user');
  }
  if (options.includeStackTrace && report.stackTrace != null) {
    printer.block(
      buffer,
      'stack',
      report.stackTrace.toString().trim().split('\n'),
    );
  }
  printer.resource(buffer, report.resource.attributes);
  return buffer.toString();
}

String _formatBreadcrumbOffset(Duration offset) {
  final milliseconds = offset.inMicroseconds / 1000;
  final sign = milliseconds >= 0 ? '+' : '-';
  return '$sign${milliseconds.abs().toStringAsFixed(1).padLeft(7)} ms';
}
