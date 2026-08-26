import '../common/instrumentation_scope.dart';
import '../common/attributes.dart';
import '../common/resource.dart';
import 'span_context.dart';

/// Defines span kind values.
enum SpanKind {
  /// The internal value.
  internal,

  /// The server value.
  server,

  /// The client value.
  client,

  /// The producer value.
  producer,

  /// The consumer value.
  consumer,
}

/// Defines span status values.
enum SpanStatus {
  /// The unset value.
  unset,

  /// The ok value.
  ok,

  /// The error value.
  error,
}

/// Represents span event.
final class SpanEvent {
  /// Creates a instance.
  SpanEvent({
    required this.name,
    required this.timestamp,
    Map<String, Object?> attributes = const {},
  }) : attributes = validatedAttributes(attributes) {
    if (name.isEmpty) throw ArgumentError.value(name, 'name');
  }

  /// The name.
  final String name;

  /// The timestamp.
  final DateTime timestamp;

  /// The attributes.
  final Map<String, Object?> attributes;
}

/// Represents span link.
final class SpanLink {
  /// Creates a instance.
  SpanLink(this.context, {Map<String, Object?> attributes = const {}})
    : attributes = validatedAttributes(attributes);

  /// The context.
  final SpanContext context;

  /// The attributes.
  final Map<String, Object?> attributes;
}

/// Immutable representation delivered to processors and exporters.
final class SpanData {
  /// Creates a instance.
  SpanData({
    required this.name,
    required this.context,
    required this.parentSpanId,
    required this.kind,
    required this.startTime,
    required this.endTime,
    required this.status,
    required this.statusDescription,
    required this.resource,
    required this.instrumentationScope,
    required Map<String, Object?> attributes,
    required List<SpanEvent> events,
    required List<SpanLink> links,
    this.droppedAttributes = 0,
    this.droppedEvents = 0,
    this.droppedLinks = 0,
  }) : attributes = validatedAttributes(attributes),
       events = List.unmodifiable(events),
       links = List.unmodifiable(links);

  /// The name.
  final String name;

  /// The context.
  final SpanContext context;

  /// The parent span id.
  final String? parentSpanId;

  /// The kind.
  final SpanKind kind;

  /// The start time.
  final DateTime startTime;

  /// The end time.
  final DateTime endTime;

  /// The status.
  final SpanStatus status;

  /// The status description.
  final String? statusDescription;

  /// The resource.
  final Resource resource;

  /// The instrumentation scope.
  final InstrumentationScope instrumentationScope;

  /// The attributes.
  final Map<String, Object?> attributes;

  /// The events.
  final List<SpanEvent> events;

  /// The links.
  final List<SpanLink> links;

  /// The dropped attributes.
  final int droppedAttributes;

  /// The dropped events.
  final int droppedEvents;

  /// The dropped links.
  final int droppedLinks;

  /// The duration.
  Duration get duration => endTime.difference(startTime);
}

/// Represents span.
abstract interface class Span {
  /// The name.
  String get name;

  /// The context.
  SpanContext get context;

  /// The is recording.
  bool get isRecording;

  /// The has ended.
  bool get hasEnded;

  /// Performs set attribute.
  void setAttribute(String key, Object? value);

  /// Performs update name.
  void updateName(String name);

  /// Performs add event.
  void addEvent(String name, {Map<String, Object?> attributes = const {}});

  /// Performs add link.
  void addLink(
    SpanContext context, {
    Map<String, Object?> attributes = const {},
  });

  /// Performs record exception.
  void recordException(Object exception, {StackTrace? stackTrace});

  /// Performs set status.
  void setStatus(SpanStatus status, {String? description});

  /// Performs run.
  R run<R>(R Function() callback);

  /// Performs end.
  void end();
}
