import '../common/instrumentation_scope.dart';
import '../common/attributes.dart';
import '../common/resource.dart';

/// Defines instrument kind values.
enum InstrumentKind {
  /// The counter value.
  counter,

  /// The up down counter value.
  upDownCounter,

  /// The histogram value.
  histogram,

  /// The gauge value.
  gauge,

  /// The observable counter value.
  observableCounter,

  /// The observable up down counter value.
  observableUpDownCounter,

  /// The observable gauge value.
  observableGauge,
}

/// Defines aggregation temporality values.
enum AggregationTemporality {
  /// The delta value.
  delta,

  /// The cumulative value.
  cumulative,
}

/// Per-instrument aggregation limits configured on the meter provider.
final class MetricView {
  /// Creates a instance.
  const MetricView({
    required this.instrumentName,
    this.histogramBoundaries,
    this.cardinalityLimit,
  });

  /// The instrument name.
  final String instrumentName;

  /// The histogram boundaries.
  final List<double>? histogramBoundaries;

  /// The cardinality limit.
  final int? cardinalityLimit;
}

/// Represents observation.
final class Observation<T extends num> {
  /// Creates a instance.
  const Observation(this.value, {this.attributes = const {}});

  /// The value.
  final T value;

  /// The attributes.
  final Map<String, Object?> attributes;
}

/// Represents metric point.
final class MetricPoint {
  /// Creates a instance.
  MetricPoint({
    required Map<String, Object?> attributes,
    required this.timestamp,
    this.startTime,
    this.value,
    this.count,
    this.sum,
    this.min,
    this.max,
    List<double> boundaries = const [],
    List<int> bucketCounts = const [],
  }) : attributes = validatedAttributes(attributes),
       boundaries = List.unmodifiable(boundaries),
       bucketCounts = List.unmodifiable(bucketCounts);

  /// The attributes.
  final Map<String, Object?> attributes;

  /// The timestamp.
  final DateTime timestamp;

  /// The start time.
  final DateTime? startTime;

  /// The value.
  final num? value;

  /// The count.
  final int? count;

  /// The sum.
  final num? sum;

  /// The min.
  final num? min;

  /// The max.
  final num? max;

  /// The boundaries.
  final List<double> boundaries;

  /// The bucket counts.
  final List<int> bucketCounts;
}

/// Represents metric data.
final class MetricData {
  /// Creates a instance.
  MetricData({
    required this.name,
    required this.kind,
    required this.description,
    required this.unit,
    required this.resource,
    required this.instrumentationScope,
    required List<MetricPoint> points,
    this.temporality,
    this.isMonotonic,
  }) : points = List.unmodifiable(points);

  /// The name.
  final String name;

  /// The kind.
  final InstrumentKind kind;

  /// The description.
  final String? description;

  /// The unit.
  final String? unit;

  /// The resource.
  final Resource resource;

  /// The instrumentation scope.
  final InstrumentationScope instrumentationScope;

  /// The points.
  final List<MetricPoint> points;

  /// The temporality.
  final AggregationTemporality? temporality;

  /// The is monotonic.
  final bool? isMonotonic;
}

/// Represents metric exporter.
abstract interface class MetricExporter {
  /// Performs export.
  Future<void> export(List<MetricData> metrics);

  /// Performs shutdown.
  Future<void> shutdown();
}

/// Represents metric producer.
abstract interface class MetricProducer {
  /// Performs collect.
  List<MetricData> collect();
}

/// Represents metric reader.
abstract interface class MetricReader {
  /// Performs bind.
  void bind(MetricProducer producer);

  /// Performs force flush.
  Future<void> forceFlush();

  /// Performs shutdown.
  Future<void> shutdown();
}

/// Represents counter.
abstract interface class Counter<T extends num> {
  /// Performs add.
  void add(T value, {Map<String, Object?> attributes = const {}});
}

/// Represents up down counter.
abstract interface class UpDownCounter<T extends num> {
  /// Performs add.
  void add(T value, {Map<String, Object?> attributes = const {}});
}

/// Represents histogram.
abstract interface class Histogram<T extends num> {
  /// Performs record.
  void record(T value, {Map<String, Object?> attributes = const {}});
}

/// Represents gauge.
abstract interface class Gauge<T extends num> {
  /// Performs record.
  void record(T value, {Map<String, Object?> attributes = const {}});
}

/// Represents observable counter.
abstract interface class ObservableCounter<T extends num> {}

/// Represents observable up down counter.
abstract interface class ObservableUpDownCounter<T extends num> {}

/// Represents observable gauge.
abstract interface class ObservableGauge<T extends num> {}

/// Represents meter.
abstract interface class Meter {
  /// Performs create counter.
  Counter<T> createCounter<T extends num>(
    String name, {
    String? description,
    String? unit,
  });

  /// Performs create up down counter.
  UpDownCounter<T> createUpDownCounter<T extends num>(
    String name, {
    String? description,
    String? unit,
  });

  /// Performs create histogram.
  Histogram<T> createHistogram<T extends num>(
    String name, {
    String? description,
    String? unit,
    List<double> boundaries,
  });

  /// Performs create gauge.
  Gauge<T> createGauge<T extends num>(
    String name, {
    String? description,
    String? unit,
  });

  /// Performs create observable counter.
  ObservableCounter<T> createObservableCounter<T extends num>(
    String name,
    Iterable<Observation<T>> Function() callback, {
    String? description,
    String? unit,
  });

  /// Performs create observable up down counter.
  ObservableUpDownCounter<T> createObservableUpDownCounter<T extends num>(
    String name,
    Iterable<Observation<T>> Function() callback, {
    String? description,
    String? unit,
  });

  /// Performs create observable gauge.
  ObservableGauge<T> createObservableGauge<T extends num>(
    String name,
    Iterable<Observation<T>> Function() callback, {
    String? description,
    String? unit,
  });
}
