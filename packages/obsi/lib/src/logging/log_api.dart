import '../api/span_context.dart';
import '../common/attributes.dart';
import '../common/instrumentation_scope.dart';
import '../common/resource.dart';

/// Defines log severity values.
enum LogSeverity {
  /// The trace value.
  trace,

  /// The debug value.
  debug,

  /// The info value.
  info,

  /// The warn value.
  warn,

  /// The error value.
  error,

  /// The fatal value.
  fatal,
}

/// Represents log record.
final class LogRecord {
  /// Creates a instance.
  LogRecord({
    required this.timestamp,
    required this.observedTimestamp,
    required this.severity,
    required this.body,
    required this.resource,
    required this.instrumentationScope,
    required Map<String, Object?> attributes,
    this.spanContext,
    this.error,
    this.stackTrace,
  }) : attributes = validatedAttributes(attributes);

  /// The timestamp.
  final DateTime timestamp;

  /// The observed timestamp.
  final DateTime observedTimestamp;

  /// The severity.
  final LogSeverity severity;

  /// The body.
  final Object? body;

  /// The attributes.
  final Map<String, Object?> attributes;

  /// The span context.
  final SpanContext? spanContext;

  /// The error.
  final Object? error;

  /// The stack trace.
  final StackTrace? stackTrace;

  /// The resource.
  final Resource resource;

  /// The instrumentation scope.
  final InstrumentationScope instrumentationScope;
}

/// Represents logger.
abstract interface class Logger {
  /// Performs is enabled.
  bool isEnabled(LogSeverity severity);

  /// Performs log.
  void log(
    LogSeverity severity,
    Object? body, {
    Map<String, Object?> attributes = const {},
    Object? error,
    StackTrace? stackTrace,
    DateTime? timestamp,
  });

  /// Performs trace.
  void trace(Object? body, {Map<String, Object?> attributes = const {}});

  /// Performs debug.
  void debug(Object? body, {Map<String, Object?> attributes = const {}});

  /// Performs info.
  void info(Object? body, {Map<String, Object?> attributes = const {}});

  /// Performs warn.
  void warn(Object? body, {Map<String, Object?> attributes = const {}});

  /// Performs error.
  void error(
    Object? body, {
    Map<String, Object?> attributes = const {},
    Object? error,
    StackTrace? stackTrace,
  });

  /// Performs fatal.
  void fatal(
    Object? body, {
    Map<String, Object?> attributes = const {},
    Object? error,
    StackTrace? stackTrace,
  });
}
