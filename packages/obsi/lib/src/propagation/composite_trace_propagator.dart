import '../api/span_context.dart';
import 'trace_propagator.dart';

/// Runs multiple trace propagators in order.
final class CompositeTracePropagator implements TracePropagator {
  /// Creates a instance.
  CompositeTracePropagator(Iterable<TracePropagator> propagators)
    : propagators = List.unmodifiable(propagators);

  /// The propagators.
  final List<TracePropagator> propagators;

  /// Performs extract.
  @override
  SpanContext? extract(Map<String, String> carrier) {
    for (final propagator in propagators) {
      final context = propagator.extract(carrier);
      if (context != null) return context;
    }
    return null;
  }

  /// Performs inject.
  @override
  void inject(SpanContext context, Map<String, String> carrier) {
    for (final propagator in propagators) {
      propagator.inject(context, carrier);
    }
  }
}
