import 'dart:async';

import 'span.dart';
import 'span_context.dart';

/// Represents tracer.
abstract interface class Tracer {
  /// The current span.
  Span? get currentSpan;

  /// Performs start span.
  Span startSpan(
    String name, {
    SpanKind kind = SpanKind.internal,
    Map<String, Object?> attributes = const {},
    List<SpanLink> links = const [],
    SpanContext? parent,
  });

  /// Performs trace sync.
  T traceSync<T>(
    String name,
    T Function() callback, {
    SpanKind kind = SpanKind.internal,
    Map<String, Object?> attributes = const {},
  });

  /// Performs trace.
  Future<T> trace<T>(
    String name,
    FutureOr<T> Function() callback, {
    SpanKind kind = SpanKind.internal,
    Map<String, Object?> attributes = const {},
  });

  /// Performs trace stream.
  Stream<T> traceStream<T>(
    String name,
    Stream<T> Function() factory, {
    SpanKind kind = SpanKind.internal,
    Map<String, Object?> attributes = const {},
    bool isBroadcast = false,
  });
}
