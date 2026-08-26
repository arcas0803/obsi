import 'dart:async';

import '../api/span.dart';

/// Represents zone trace context.
final class ZoneTraceContext {
  ZoneTraceContext._();

  static final Object _spanKey = Object();
  static final Object _suppressionKey = Object();

  /// The current span.
  static Span? get currentSpan => Zone.current[_spanKey] as Span?;

  /// The suppressed.
  static bool get suppressed => Zone.current[_suppressionKey] == true;

  /// Performs run.
  static R run<R>(Span span, R Function() callback) =>
      runZoned(callback, zoneValues: {_spanKey: span});

  /// Performs suppress.
  static R suppress<R>(R Function() callback) =>
      runZoned(callback, zoneValues: {_suppressionKey: true});
}
