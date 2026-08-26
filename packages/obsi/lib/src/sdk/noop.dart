import 'dart:async';

import '../api/span.dart';
import '../api/span_context.dart';
import '../api/tracer.dart';
import '../context/zone_trace_context.dart';

/// Represents noop span.
final class NoopSpan implements Span {
  /// Creates a instance.
  const NoopSpan([this.context = _invalidContext]);

  static const _invalidContext = SpanContext(
    traceId: '00000000000000000000000000000000',
    spanId: '0000000000000000',
    sampled: false,
  );

  /// The context.
  @override
  final SpanContext context;

  /// The name.
  @override
  String get name => '';

  /// The is recording.
  @override
  bool get isRecording => false;

  /// The has ended.
  @override
  bool get hasEnded => true;

  /// Performs add event.
  @override
  void addEvent(String name, {Map<String, Object?> attributes = const {}}) {}

  /// Performs add link.
  @override
  void addLink(
    SpanContext context, {
    Map<String, Object?> attributes = const {},
  }) {}

  /// Performs end.
  @override
  void end() {}

  /// Performs record exception.
  @override
  void recordException(Object exception, {StackTrace? stackTrace}) {}

  /// Performs run.
  @override
  R run<R>(R Function() callback) => ZoneTraceContext.run(this, callback);

  /// Performs set attribute.
  @override
  void setAttribute(String key, Object? value) {}

  /// Performs set status.
  @override
  void setStatus(SpanStatus status, {String? description}) {}

  /// Performs update name.
  @override
  void updateName(String name) {}
}

/// Represents noop tracer.
final class NoopTracer implements Tracer {
  /// Creates a instance.
  const NoopTracer();

  /// The current span.
  @override
  Span? get currentSpan => null;

  /// Performs start span.
  @override
  Span startSpan(
    String name, {
    SpanKind kind = SpanKind.internal,
    Map<String, Object?> attributes = const {},
    List<SpanLink> links = const [],
    SpanContext? parent,
  }) => const NoopSpan();

  /// Performs trace.
  @override
  Future<T> trace<T>(
    String name,
    FutureOr<T> Function() callback, {
    SpanKind kind = SpanKind.internal,
    Map<String, Object?> attributes = const {},
  }) async => callback();

  /// Performs trace sync.
  @override
  T traceSync<T>(
    String name,
    T Function() callback, {
    SpanKind kind = SpanKind.internal,
    Map<String, Object?> attributes = const {},
  }) => callback();

  /// Performs trace stream.
  @override
  Stream<T> traceStream<T>(
    String name,
    Stream<T> Function() factory, {
    SpanKind kind = SpanKind.internal,
    Map<String, Object?> attributes = const {},
    bool isBroadcast = false,
  }) => Stream.multi((controller) {
    final subscription = factory().listen(
      controller.add,
      onError: controller.addError,
      onDone: controller.close,
    );
    controller
      ..onPause = subscription.pause
      ..onResume = subscription.resume
      ..onCancel = subscription.cancel;
  }, isBroadcast: isBroadcast);
}
