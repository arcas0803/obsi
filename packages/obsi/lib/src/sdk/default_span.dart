import '../api/span.dart';
import '../api/span_context.dart';
import '../common/attributes.dart';
import '../common/instrumentation_scope.dart';
import '../common/diagnostics.dart';
import '../common/resource.dart';
import '../common/redaction.dart';
import '../context/zone_trace_context.dart';
import '../processing/span_processor.dart';
import '../semconv/semantic_conventions.dart';
import 'span_limits.dart';

/// Represents default span.
final class DefaultSpan implements Span {
  /// Creates a instance.
  DefaultSpan({
    required this.name,
    required this.context,
    required this.parentSpanId,
    required this.kind,
    required this.processor,
    required this.resource,
    required this.instrumentationScope,
    required this.limits,
    required Map<String, Object?> attributes,
    List<SpanLink> links = const [],
    DateTime? startTime,
    this.onInternalError,
    this.attributeRedactor,
  }) : _attributes = Map.of(
         validatedAttributes(
           attributeRedactor?.call(attributes) ?? attributes,
           limit: limits.attributeCountLimit,
         ),
       ),
       _links = List.of(
         links
             .where((link) => link.context.isValid)
             .take(limits.linkCountLimit)
             .map(
               (link) => SpanLink(
                 link.context,
                 attributes: validatedAttributes(
                   attributeRedactor?.call(link.attributes) ?? link.attributes,
                   limit: limits.attributePerLinkCountLimit,
                 ),
               ),
             ),
       ),
       _droppedAttributes = attributes.length > limits.attributeCountLimit
           ? attributes.length - limits.attributeCountLimit
           : 0,
       _droppedLinks =
           links.where((link) => !link.context.isValid).length +
           (links.where((link) => link.context.isValid).length >
                   limits.linkCountLimit
               ? links.where((link) => link.context.isValid).length -
                     limits.linkCountLimit
               : 0),
       _startTime = startTime ?? DateTime.now();

  /// The name.
  @override
  String name;

  /// The context.
  @override
  final SpanContext context;

  /// The parent span id.
  final String? parentSpanId;

  /// The kind.
  final SpanKind kind;

  /// The processor.
  final SpanProcessor processor;

  /// The resource.
  final Resource resource;

  /// The instrumentation scope.
  final InstrumentationScope instrumentationScope;

  /// The limits.
  final SpanLimits limits;

  /// The on internal error.
  final TelemetryErrorHandler? onInternalError;

  /// The attribute redactor.
  final AttributeRedactor? attributeRedactor;
  final DateTime _startTime;
  final Map<String, Object?> _attributes;
  final List<SpanEvent> _events = [];
  final List<SpanLink> _links;
  int _droppedAttributes;
  int _droppedEvents = 0;
  int _droppedLinks;
  SpanStatus _status = SpanStatus.unset;
  String? _statusDescription;
  bool _hasEnded = false;

  /// The is recording.
  @override
  bool get isRecording => !_hasEnded;

  /// The has ended.
  @override
  bool get hasEnded => _hasEnded;

  /// Performs set attribute.
  @override
  void setAttribute(String key, Object? value) {
    if (!isRecording) return;
    final validated = validatedAttributes(
      attributeRedactor?.call({key: value}) ?? {key: value},
    );
    if (!_attributes.containsKey(key) &&
        _attributes.length >= limits.attributeCountLimit) {
      _droppedAttributes++;
      return;
    }
    _attributes[key] = validated[key];
  }

  /// Performs update name.
  @override
  void updateName(String name) {
    if (isRecording && name.isNotEmpty) this.name = name;
  }

  /// Performs add event.
  @override
  void addEvent(String name, {Map<String, Object?> attributes = const {}}) {
    if (!isRecording) return;
    if (name.isEmpty) throw ArgumentError.value(name, 'name');
    if (_events.length >= limits.eventCountLimit) {
      _droppedEvents++;
      return;
    }
    _events.add(
      SpanEvent(
        name: name,
        timestamp: DateTime.now(),
        attributes: validatedAttributes(
          attributeRedactor?.call(attributes) ?? attributes,
          limit: limits.attributePerEventCountLimit,
        ),
      ),
    );
  }

  /// Performs add link.
  @override
  void addLink(
    SpanContext context, {
    Map<String, Object?> attributes = const {},
  }) {
    if (!isRecording) return;
    if (!context.isValid) {
      _droppedLinks++;
      return;
    }
    if (_links.length >= limits.linkCountLimit) {
      _droppedLinks++;
      return;
    }
    _links.add(
      SpanLink(
        context,
        attributes: validatedAttributes(
          attributeRedactor?.call(attributes) ?? attributes,
          limit: limits.attributePerLinkCountLimit,
        ),
      ),
    );
  }

  /// Performs record exception.
  @override
  void recordException(Object exception, {StackTrace? stackTrace}) {
    addEvent(
      SemanticEvents.exception,
      attributes: {
        SemanticAttributes.exceptionType: exception.runtimeType.toString(),
        SemanticAttributes.exceptionMessage: exception.toString(),
        if (stackTrace != null)
          SemanticAttributes.exceptionStacktrace: stackTrace.toString(),
      },
    );
  }

  /// Performs set status.
  @override
  void setStatus(SpanStatus status, {String? description}) {
    if (!isRecording) return;
    _status = status;
    _statusDescription = description;
  }

  /// Performs set ok if unset.
  void setOkIfUnset() {
    if (isRecording && _status == SpanStatus.unset) {
      _status = SpanStatus.ok;
    }
  }

  /// Performs run.
  @override
  R run<R>(R Function() callback) => ZoneTraceContext.run(this, callback);

  /// Performs end.
  @override
  void end() {
    if (_hasEnded) return;
    _hasEnded = true;
    final data = SpanData(
      name: name,
      context: context,
      parentSpanId: parentSpanId,
      kind: kind,
      startTime: _startTime,
      endTime: DateTime.now(),
      status: _status,
      statusDescription: _statusDescription,
      resource: resource,
      instrumentationScope: instrumentationScope,
      attributes: _attributes,
      events: _events,
      links: _links,
      droppedAttributes: _droppedAttributes,
      droppedEvents: _droppedEvents,
      droppedLinks: _droppedLinks,
    );
    try {
      processor.onEnd(data);
    } catch (error, stackTrace) {
      reportTelemetryError(onInternalError, error, stackTrace);
    }
  }
}
