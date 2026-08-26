import '../api/span_context.dart';
import '../common/attributes.dart';
import '../common/instrumentation_scope.dart';
import '../common/resource.dart';
import '../common/structured_data.dart';

/// Defines error severity values.
enum ErrorSeverity {
  /// The debug value.
  debug,

  /// The info value.
  info,

  /// The warning value.
  warning,

  /// The error value.
  error,

  /// The fatal value.
  fatal,
}

/// Defines error mechanism values.
enum ErrorMechanism {
  /// The manual value.
  manual,

  /// The zone value.
  zone,

  /// The isolate value.
  isolate,

  /// The flutter framework value.
  flutterFramework,

  /// The platform dispatcher value.
  platformDispatcher,
}

/// Represents error id.
final class ErrorId {
  /// Creates a instance.
  const ErrorId(this.value);

  /// The value.
  final String value;

  /// Performs to string.
  @override
  String toString() => value;

  /// Performs ==.
  @override
  bool operator ==(Object other) =>
      identical(this, other) || other is ErrorId && value == other.value;

  /// The hash code.
  @override
  int get hashCode => value.hashCode;
}

/// Represents error user.
final class ErrorUser {
  /// Creates a instance.
  ErrorUser({
    this.id,
    this.email,
    this.username,
    this.ipAddress,
    Map<String, Object?> data = const {},
  }) : data = immutableStructuredMap(data);

  /// The id.
  final String? id;

  /// The email.
  final String? email;

  /// The username.
  final String? username;

  /// The ip address.
  final String? ipAddress;

  /// The data.
  final Map<String, Object?> data;
}

/// Represents error breadcrumb.
final class ErrorBreadcrumb {
  /// Creates a instance.
  ErrorBreadcrumb({
    required this.timestamp,
    required this.category,
    this.message,
    this.level = ErrorSeverity.info,
    Map<String, Object?> data = const {},
  }) : data = immutableStructuredMap(data) {
    if (category.isEmpty) throw ArgumentError.value(category, 'category');
  }

  /// The timestamp.
  final DateTime timestamp;

  /// The category.
  final String category;

  /// The message.
  final String? message;

  /// The level.
  final ErrorSeverity level;

  /// The data.
  final Map<String, Object?> data;
}

/// Represents error attachment.
final class ErrorAttachment {
  /// Creates a instance.
  ErrorAttachment({
    required this.filename,
    required List<int> bytes,
    this.contentType = 'application/octet-stream',
  }) : bytes = List.unmodifiable(bytes) {
    if (filename.isEmpty) throw ArgumentError.value(filename, 'filename');
    if (contentType.isEmpty) {
      throw ArgumentError.value(contentType, 'contentType');
    }
    if (bytes.any((byte) => byte < 0 || byte > 255)) {
      throw ArgumentError.value(
        bytes,
        'bytes',
        'Values must be between 0 and 255',
      );
    }
  }

  /// The filename.
  final String filename;

  /// The bytes.
  final List<int> bytes;

  /// The content type.
  final String contentType;
}

/// Represents error report.
final class ErrorReport {
  /// Creates a instance.
  ErrorReport({
    required this.id,
    required this.timestamp,
    required this.exception,
    required this.message,
    required this.stackTrace,
    required this.severity,
    required this.fatal,
    required this.handled,
    required this.mechanism,
    required this.resource,
    required this.instrumentationScope,
    required Map<String, Object?> attributes,
    required Map<String, String> tags,
    required Map<String, Map<String, Object?>> contexts,
    required List<String> fingerprint,
    required List<ErrorBreadcrumb> breadcrumbs,
    required List<ErrorAttachment> attachments,
    this.user,
    SpanContext? spanContext,
    this.reason,
  }) : attributes = validatedAttributes(attributes),
       tags = Map.unmodifiable(tags),
       contexts = Map.unmodifiable({
         for (final entry in contexts.entries)
           entry.key: immutableStructuredMap(entry.value),
       }),
       fingerprint = List.unmodifiable(fingerprint),
       breadcrumbs = List.unmodifiable(breadcrumbs),
       attachments = List.unmodifiable(attachments),
       spanContext = _validatedSpanContext(spanContext);

  /// The id.
  final ErrorId id;

  /// The timestamp.
  final DateTime timestamp;

  /// The exception.
  final Object exception;

  /// The message.
  final String message;

  /// The stack trace.
  final StackTrace? stackTrace;

  /// The severity.
  final ErrorSeverity severity;

  /// The fatal.
  final bool fatal;

  /// The handled.
  final bool handled;

  /// The mechanism.
  final ErrorMechanism mechanism;

  /// The reason.
  final String? reason;

  /// The attributes.
  final Map<String, Object?> attributes;

  /// The tags.
  final Map<String, String> tags;

  /// The contexts.
  final Map<String, Map<String, Object?>> contexts;

  /// The fingerprint.
  final List<String> fingerprint;

  /// The breadcrumbs.
  final List<ErrorBreadcrumb> breadcrumbs;

  /// The attachments.
  final List<ErrorAttachment> attachments;

  /// The user.
  final ErrorUser? user;

  /// The span context.
  final SpanContext? spanContext;

  /// The resource.
  final Resource resource;

  /// The instrumentation scope.
  final InstrumentationScope instrumentationScope;

  /// Performs copy with.
  ErrorReport copyWith({
    Object? exception,
    String? message,
    StackTrace? stackTrace,
    bool clearStackTrace = false,
    ErrorSeverity? severity,
    bool? fatal,
    bool? handled,
    ErrorMechanism? mechanism,
    String? reason,
    bool clearReason = false,
    Map<String, Object?>? attributes,
    Map<String, String>? tags,
    Map<String, Map<String, Object?>>? contexts,
    List<String>? fingerprint,
    List<ErrorBreadcrumb>? breadcrumbs,
    List<ErrorAttachment>? attachments,
    ErrorUser? user,
    bool clearUser = false,
    SpanContext? spanContext,
    bool clearSpanContext = false,
  }) => ErrorReport(
    id: id,
    timestamp: timestamp,
    exception: exception ?? this.exception,
    message: message ?? this.message,
    stackTrace: clearStackTrace ? null : stackTrace ?? this.stackTrace,
    severity: severity ?? this.severity,
    fatal: fatal ?? this.fatal,
    handled: handled ?? this.handled,
    mechanism: mechanism ?? this.mechanism,
    reason: clearReason ? null : reason ?? this.reason,
    attributes: attributes ?? this.attributes,
    tags: tags ?? this.tags,
    contexts: contexts ?? this.contexts,
    fingerprint: fingerprint ?? this.fingerprint,
    breadcrumbs: breadcrumbs ?? this.breadcrumbs,
    attachments: attachments ?? this.attachments,
    user: clearUser ? null : user ?? this.user,
    spanContext: clearSpanContext ? null : spanContext ?? this.spanContext,
    resource: resource,
    instrumentationScope: instrumentationScope,
  );
}

SpanContext? _validatedSpanContext(SpanContext? context) {
  if (context != null && !context.isValid) {
    throw ArgumentError.value(context, 'spanContext');
  }
  return context;
}
