import 'baggage.dart';

/// Represents baggage propagator.
abstract interface class BaggagePropagator {
  /// Performs inject.
  void inject(Baggage baggage, Map<String, String> carrier);

  /// Performs extract.
  Baggage extract(Map<String, String> carrier);
}
