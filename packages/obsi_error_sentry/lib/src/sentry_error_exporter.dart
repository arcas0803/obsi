import 'package:obsi/obsi.dart';
import 'package:sentry/sentry.dart';

/// Defines the sentry capture type.
typedef SentryCapture =
    Future<SentryId> Function(
      Object exception, {
      dynamic stackTrace,
      SentryMessage? message,
      ScopeCallback? withScope,
    });

/// Represents sentry delivery rejected exception.
final class SentryDeliveryRejectedException implements Exception {
  /// Creates a instance.
  const SentryDeliveryRejectedException();

  /// Performs to string.
  @override
  String toString() => 'Sentry did not accept the error event';
}

/// Exports Obsi error reports through the Sentry Dart SDK.
final class SentryErrorExporter implements ErrorExporter {
  /// Creates a instance.
  SentryErrorExporter({
    SentryCapture? capture,
    Future<void> Function()? close,
    this.closeOnShutdown = false,
    this.requireEventId = true,
  }) : _capture = capture ?? Sentry.captureException,
       _close = close ?? Sentry.close;

  final SentryCapture _capture;
  final Future<void> Function() _close;

  /// The close on shutdown.
  final bool closeOnShutdown;

  /// The require event id.
  final bool requireEventId;
  final Set<Future<void>> _pending = {};
  bool _shutdown = false;
  Future<void>? _shutdownFuture;
  int _exportedReports = 0;
  int _rejectedReports = 0;

  /// The exported reports.
  int get exportedReports => _exportedReports;

  /// The rejected reports.
  int get rejectedReports => _rejectedReports;

  /// Performs export.
  @override
  Future<void> export(ErrorReport report) {
    if (_shutdown) return Future.error(StateError('Exporter is shut down'));
    late final Future<void> operation;
    operation = _exportOne(
      report,
    ).whenComplete(() => _pending.remove(operation));
    _pending.add(operation);
    return operation;
  }

  Future<void> _exportOne(ErrorReport report) async {
    final eventId = await _capture(
      report.exception,
      stackTrace: report.stackTrace,
      message: SentryMessage(report.message),
      withScope: (scope) => applyErrorReportToSentryScope(report, scope),
    );
    if (requireEventId && eventId == const SentryId.empty()) {
      _rejectedReports++;
      throw const SentryDeliveryRejectedException();
    }
    _exportedReports++;
  }

  /// Performs force flush.
  @override
  Future<void> forceFlush() async {
    while (_pending.isNotEmpty) {
      await Future.wait(_pending.toList(growable: false));
    }
  }

  /// Performs shutdown.
  @override
  Future<void> shutdown() => _shutdownFuture ??= _doShutdown();

  Future<void> _doShutdown() async {
    _shutdown = true;
    await forceFlush();
    if (closeOnShutdown) await _close();
  }
}

/// Applies the vendor-neutral report fields to an isolated Sentry scope.
Future<void> applyErrorReportToSentryScope(
  ErrorReport report,
  Scope scope,
) async {
  scope.level = _level(report.severity);
  scope.fingerprint = report.fingerprint;

  final user = report.user;
  if (user != null &&
      [
        user.id,
        user.email,
        user.username,
        user.ipAddress,
      ].any((value) => value != null)) {
    await scope.setUser(
      SentryUser(
        id: user.id,
        email: user.email,
        username: user.username,
        ipAddress: user.ipAddress,
        data: user.data,
      ),
    );
  }

  final tags = <String, String>{
    ...report.tags,
    'obsi.error_id': report.id.value,
    'obsi.mechanism': report.mechanism.name,
    'obsi.handled': report.handled.toString(),
    'obsi.fatal': report.fatal.toString(),
    'obsi.severity': report.severity.name,
    'obsi.integration': 'obsi_error_sentry',
    if (report.spanContext case final span?) ...{
      'obsi.trace_id': span.traceId,
      'obsi.span_id': span.spanId,
    },
  };
  for (final entry in tags.entries) {
    await scope.setTag(entry.key, entry.value);
  }

  await scope.setContexts('obsi.error', {
    'id': report.id.value,
    'mechanism': report.mechanism.name,
    'handled': report.handled,
    'fatal': report.fatal,
    if (report.reason != null) 'reason': report.reason,
    'attributes': report.attributes,
  });
  await scope.setContexts('obsi.resource', report.resource.attributes);
  await scope.setContexts('obsi.instrumentation', {
    'name': report.instrumentationScope.name,
    if (report.instrumentationScope.version != null)
      'version': report.instrumentationScope.version,
  });
  for (final entry in report.contexts.entries) {
    await scope.setContexts(entry.key, entry.value);
  }

  for (final breadcrumb in report.breadcrumbs) {
    await scope.addBreadcrumb(
      Breadcrumb(
        timestamp: breadcrumb.timestamp,
        category: breadcrumb.category,
        message: breadcrumb.message,
        level: _level(breadcrumb.level),
        data: breadcrumb.data,
      ),
    );
  }
  for (final attachment in report.attachments) {
    scope.addAttachment(
      SentryAttachment.fromIntList(
        attachment.bytes,
        attachment.filename,
        contentType: attachment.contentType,
      ),
    );
  }
}

SentryLevel _level(ErrorSeverity severity) => switch (severity) {
  ErrorSeverity.debug => SentryLevel.debug,
  ErrorSeverity.info => SentryLevel.info,
  ErrorSeverity.warning => SentryLevel.warning,
  ErrorSeverity.error => SentryLevel.error,
  ErrorSeverity.fatal => SentryLevel.fatal,
};
