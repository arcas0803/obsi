import '../api/span_context.dart';

/// Represents trace propagator.
abstract interface class TracePropagator {
  /// Performs inject.
  void inject(SpanContext context, Map<String, String> carrier);

  /// Performs extract.
  SpanContext? extract(Map<String, String> carrier);
}
