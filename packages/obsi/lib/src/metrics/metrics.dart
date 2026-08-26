import 'metric_api.dart';
import 'meter_provider.dart';

/// Represents metrics.
final class Metrics {
  Metrics._();

  static MeterProvider? _provider;

  /// The provider.
  static MeterProvider? get provider => _provider;

  /// Performs configure.
  static void configure(MeterProvider provider) => _provider = provider;

  /// Performs disable.
  static void disable() => _provider = null;

  /// Performs get meter.
  static Meter? getMeter(String name, {String? version}) =>
      _provider?.getMeter(name, version: version);
}
