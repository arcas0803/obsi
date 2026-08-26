import '../common/attributes.dart';
import '../common/instrumentation_scope.dart';
import '../common/diagnostics.dart';
import '../common/resource.dart';
import '../common/redaction.dart';
import '../errors/error_api.dart';
import '../errors/errors.dart';
import '../trace.dart';
import 'log_api.dart';
import 'log_processor.dart';

/// Represents logger provider.
final class LoggerProvider {
  /// Creates a instance.
  LoggerProvider({
    required this.processor,
    Resource? resource,
    this.minimumSeverity = LogSeverity.trace,
    this.onInternalError,
    this.attributeRedactor,
  }) : resource = resource ?? Resource.defaultResource;

  /// The processor.
  final LogProcessor processor;

  /// The resource.
  final Resource resource;

  /// The minimum severity.
  final LogSeverity minimumSeverity;

  /// The on internal error.
  final TelemetryErrorHandler? onInternalError;

  /// The attribute redactor.
  final AttributeRedactor? attributeRedactor;
  Future<void>? _shutdownFuture;

  /// Performs get logger.
  Logger getLogger(
    String name, {
    String? version,
    String? schemaUrl,
    Map<String, Object?> attributes = const {},
  }) => _DefaultLogger(
    processor: processor,
    resource: resource,
    scope: InstrumentationScope(
      name,
      version: version,
      schemaUrl: schemaUrl,
      attributes: attributes,
    ),
    minimumSeverity: minimumSeverity,
    onInternalError: onInternalError,
    attributeRedactor: attributeRedactor,
  );

  /// Performs force flush.
  Future<void> forceFlush() => _shutdownFuture ?? processor.forceFlush();

  /// Performs shutdown.
  Future<void> shutdown() => _shutdownFuture ??= processor.shutdown();
}

final class _DefaultLogger implements Logger {
  _DefaultLogger({
    required this.processor,
    required this.resource,
    required this.scope,
    required this.minimumSeverity,
    required this.onInternalError,
    required this.attributeRedactor,
  });

  final LogProcessor processor;
  final Resource resource;
  final InstrumentationScope scope;
  final LogSeverity minimumSeverity;
  final TelemetryErrorHandler? onInternalError;
  final AttributeRedactor? attributeRedactor;

  @override
  bool isEnabled(LogSeverity severity) =>
      severity.index >= minimumSeverity.index;

  @override
  void log(
    LogSeverity severity,
    Object? body, {
    Map<String, Object?> attributes = const {},
    Object? error,
    StackTrace? stackTrace,
    DateTime? timestamp,
  }) {
    if (!isEnabled(severity)) return;
    final observed = DateTime.now();
    final record = LogRecord(
      timestamp: timestamp ?? observed,
      observedTimestamp: observed,
      severity: severity,
      body: body,
      attributes: validatedAttributes(
        attributeRedactor?.call(attributes) ?? attributes,
      ),
      spanContext: Trace.tracer.currentSpan?.context,
      error: error,
      stackTrace: stackTrace,
      resource: resource,
      instrumentationScope: scope,
    );
    try {
      processor.emit(record);
    } catch (error, stackTrace) {
      reportTelemetryError(onInternalError, error, stackTrace);
    }
    Errors.addBreadcrumb(
      ErrorBreadcrumb(
        timestamp: record.timestamp,
        category: 'log',
        message: body?.toString(),
        level: switch (severity) {
          LogSeverity.trace || LogSeverity.debug => ErrorSeverity.debug,
          LogSeverity.info => ErrorSeverity.info,
          LogSeverity.warn => ErrorSeverity.warning,
          LogSeverity.error => ErrorSeverity.error,
          LogSeverity.fatal => ErrorSeverity.fatal,
        },
        data: record.attributes,
      ),
    );
  }

  @override
  void trace(Object? body, {Map<String, Object?> attributes = const {}}) =>
      log(LogSeverity.trace, body, attributes: attributes);
  @override
  void debug(Object? body, {Map<String, Object?> attributes = const {}}) =>
      log(LogSeverity.debug, body, attributes: attributes);
  @override
  void info(Object? body, {Map<String, Object?> attributes = const {}}) =>
      log(LogSeverity.info, body, attributes: attributes);
  @override
  void warn(Object? body, {Map<String, Object?> attributes = const {}}) =>
      log(LogSeverity.warn, body, attributes: attributes);
  @override
  void error(
    Object? body, {
    Map<String, Object?> attributes = const {},
    Object? error,
    StackTrace? stackTrace,
  }) => log(
    LogSeverity.error,
    body,
    attributes: attributes,
    error: error,
    stackTrace: stackTrace,
  );
  @override
  void fatal(
    Object? body, {
    Map<String, Object?> attributes = const {},
    Object? error,
    StackTrace? stackTrace,
  }) => log(
    LogSeverity.fatal,
    body,
    attributes: attributes,
    error: error,
    stackTrace: stackTrace,
  );
}
