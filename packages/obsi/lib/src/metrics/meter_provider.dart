import 'dart:convert';

import '../common/attributes.dart';
import '../common/diagnostics.dart';
import '../common/instrumentation_scope.dart';
import '../common/resource.dart';
import '../common/redaction.dart';
import 'metric_api.dart';

/// Represents meter provider.
final class MeterProvider implements MetricProducer {
  /// Creates a instance.
  MeterProvider({
    Resource? resource,
    Iterable<MetricReader> readers = const [],
    Iterable<MetricView> views = const [],
    this.cardinalityLimit = 2000,
    this.onInternalError,
    this.attributeRedactor,
  }) : resource = resource ?? Resource.defaultResource,
       readers = List.unmodifiable(readers),
       views = List.unmodifiable(views),
       startTime = DateTime.now() {
    if (cardinalityLimit <= 0) {
      throw ArgumentError.value(cardinalityLimit, 'cardinalityLimit');
    }
    for (final view in this.views) {
      if (view.instrumentName.isEmpty) {
        throw ArgumentError.value(view.instrumentName, 'instrumentName');
      }
      final viewLimit = view.cardinalityLimit;
      if (viewLimit != null && viewLimit <= 0) {
        throw ArgumentError.value(viewLimit, 'cardinalityLimit');
      }
      final viewBoundaries = view.histogramBoundaries;
      if (viewBoundaries != null) {
        _validateBoundaries([...viewBoundaries]..sort());
      }
    }
    for (final reader in this.readers) {
      reader.bind(this);
    }
  }

  /// The resource.
  final Resource resource;

  /// The readers.
  final List<MetricReader> readers;

  /// The views.
  final List<MetricView> views;

  /// The cardinality limit.
  final int cardinalityLimit;

  /// The on internal error.
  final TelemetryErrorHandler? onInternalError;

  /// The attribute redactor.
  final AttributeRedactor? attributeRedactor;

  /// The start time.
  final DateTime startTime;
  final Map<String, _Collector> _collectors = {};
  bool _shutdown = false;
  Future<void>? _shutdownFuture;
  int _droppedMeasurements = 0;

  /// The dropped measurements.
  int get droppedMeasurements => _droppedMeasurements;

  MetricView? _view(String instrumentName) {
    MetricView? result;
    for (final view in views) {
      if (view.instrumentName != instrumentName) continue;
      if (result != null) {
        throw StateError('Multiple metric views match $instrumentName');
      }
      result = view;
    }
    return result;
  }

  /// Performs get meter.
  Meter getMeter(
    String name, {
    String? version,
    String? schemaUrl,
    Map<String, Object?> attributes = const {},
  }) {
    if (_shutdown) throw StateError('MeterProvider is shut down');
    return _DefaultMeter(
      provider: this,
      scope: InstrumentationScope(
        name,
        version: version,
        schemaUrl: schemaUrl,
        attributes: attributes,
      ),
    );
  }

  T _register<T extends _Collector>(T collector) {
    if (_shutdown) throw StateError('MeterProvider is shut down');
    final key = collector.registryKey;
    final existing = _collectors[key];
    if (existing == null) {
      _collectors[key] = collector;
      return collector;
    }
    if (!existing.isCompatibleWith(collector)) {
      throw StateError(
        'Conflicting metric instrument registration for ${collector.name}',
      );
    }
    return existing as T;
  }

  /// Performs collect.
  @override
  List<MetricData> collect() {
    final result = <MetricData>[];
    for (final collector in _collectors.values) {
      final metric = collector.snapshot();
      if (metric.points.isNotEmpty) result.add(metric);
    }
    return result;
  }

  /// Performs force flush.
  Future<void> forceFlush() =>
      Future.wait([for (final reader in readers) reader.forceFlush()]);

  /// Performs shutdown.
  Future<void> shutdown() => _shutdownFuture ??= _doShutdown();

  Future<void> _doShutdown() async {
    _shutdown = true;
    await Future.wait([for (final reader in readers) reader.shutdown()]);
  }
}

final class _DefaultMeter implements Meter {
  _DefaultMeter({required this.provider, required this.scope});

  final MeterProvider provider;
  final InstrumentationScope scope;

  @override
  Counter<T> createCounter<T extends num>(
    String name, {
    String? description,
    String? unit,
  }) {
    final view = provider._view(name);
    final instrument = _SumInstrument<T>(
      provider: provider,
      scope: scope,
      name: name,
      kind: InstrumentKind.counter,
      description: description,
      unit: unit,
      monotonic: true,
      cardinalityLimit: view?.cardinalityLimit ?? provider.cardinalityLimit,
    );
    return provider._register<_SumInstrument<T>>(instrument);
  }

  @override
  UpDownCounter<T> createUpDownCounter<T extends num>(
    String name, {
    String? description,
    String? unit,
  }) {
    final view = provider._view(name);
    final instrument = _SumInstrument<T>(
      provider: provider,
      scope: scope,
      name: name,
      kind: InstrumentKind.upDownCounter,
      description: description,
      unit: unit,
      monotonic: false,
      cardinalityLimit: view?.cardinalityLimit ?? provider.cardinalityLimit,
    );
    return provider._register<_SumInstrument<T>>(instrument);
  }

  @override
  Histogram<T> createHistogram<T extends num>(
    String name, {
    String? description,
    String? unit,
    List<double> boundaries = const [0, 5, 10, 25, 50, 100, 250, 500, 1000],
  }) {
    final view = provider._view(name);
    final sortedBoundaries = [...(view?.histogramBoundaries ?? boundaries)]
      ..sort();
    _validateBoundaries(sortedBoundaries);
    final instrument = _HistogramInstrument<T>(
      provider: provider,
      scope: scope,
      name: name,
      description: description,
      unit: unit,
      boundaries: sortedBoundaries,
      cardinalityLimit: view?.cardinalityLimit ?? provider.cardinalityLimit,
    );
    return provider._register<_HistogramInstrument<T>>(instrument);
  }

  @override
  Gauge<T> createGauge<T extends num>(
    String name, {
    String? description,
    String? unit,
  }) {
    final view = provider._view(name);
    final instrument = _GaugeInstrument<T>(
      provider: provider,
      scope: scope,
      name: name,
      description: description,
      unit: unit,
      cardinalityLimit: view?.cardinalityLimit ?? provider.cardinalityLimit,
    );
    return provider._register<_GaugeInstrument<T>>(instrument);
  }

  @override
  ObservableCounter<T> createObservableCounter<T extends num>(
    String name,
    Iterable<Observation<T>> Function() callback, {
    String? description,
    String? unit,
  }) {
    final view = provider._view(name);
    final instrument = _ObservableInstrument<T>(
      provider: provider,
      scope: scope,
      name: name,
      kind: InstrumentKind.observableCounter,
      description: description,
      unit: unit,
      callback: callback,
      monotonic: true,
      cardinalityLimit: view?.cardinalityLimit ?? provider.cardinalityLimit,
    );
    return provider._register<_ObservableInstrument<T>>(instrument);
  }

  @override
  ObservableUpDownCounter<T> createObservableUpDownCounter<T extends num>(
    String name,
    Iterable<Observation<T>> Function() callback, {
    String? description,
    String? unit,
  }) {
    final view = provider._view(name);
    final instrument = _ObservableInstrument<T>(
      provider: provider,
      scope: scope,
      name: name,
      kind: InstrumentKind.observableUpDownCounter,
      description: description,
      unit: unit,
      callback: callback,
      monotonic: false,
      cardinalityLimit: view?.cardinalityLimit ?? provider.cardinalityLimit,
    );
    return provider._register<_ObservableInstrument<T>>(instrument);
  }

  @override
  ObservableGauge<T> createObservableGauge<T extends num>(
    String name,
    Iterable<Observation<T>> Function() callback, {
    String? description,
    String? unit,
  }) {
    final view = provider._view(name);
    final instrument = _ObservableInstrument<T>(
      provider: provider,
      scope: scope,
      name: name,
      kind: InstrumentKind.observableGauge,
      description: description,
      unit: unit,
      callback: callback,
      monotonic: false,
      cardinalityLimit: view?.cardinalityLimit ?? provider.cardinalityLimit,
    );
    return provider._register<_ObservableInstrument<T>>(instrument);
  }
}

abstract base class _Collector {
  _Collector({
    required this.provider,
    required this.scope,
    required this.name,
    required this.kind,
    required this.description,
    required this.unit,
    required this.cardinalityLimit,
  }) {
    if (name.isEmpty) throw ArgumentError.value(name, 'name');
  }

  final MeterProvider provider;
  final InstrumentationScope scope;
  final String name;
  final InstrumentKind kind;
  final String? description;
  final String? unit;
  final int cardinalityLimit;

  String get registryKey {
    final sortedScopeAttributes = Map.fromEntries(
      scope.attributes.entries.toList()..sort((a, b) => a.key.compareTo(b.key)),
    );
    return jsonEncode([
      scope.name,
      scope.version,
      scope.schemaUrl,
      sortedScopeAttributes,
      name,
    ]);
  }

  bool isCompatibleWith(_Collector other) =>
      runtimeType == other.runtimeType &&
      kind == other.kind &&
      description == other.description &&
      unit == other.unit &&
      cardinalityLimit == other.cardinalityLimit;

  MetricData snapshot();

  String key(Map<String, Object?> attributes) {
    final redacted = provider.attributeRedactor?.call(attributes) ?? attributes;
    final sorted = Map.fromEntries(
      validatedAttributes(redacted).entries.toList()
        ..sort((a, b) => a.key.compareTo(b.key)),
    );
    return jsonEncode(sorted);
  }

  Map<String, Object?> decodeKey(String key) =>
      Map<String, Object?>.from(jsonDecode(key) as Map);

  bool canAdd(String key, Map<String, Object?> values) {
    if (provider._shutdown) return false;
    if (values.containsKey(key) || values.length < cardinalityLimit) {
      return true;
    }
    provider._droppedMeasurements++;
    return false;
  }

  MetricData data(List<MetricPoint> points) => MetricData(
    name: name,
    kind: kind,
    description: description,
    unit: unit,
    resource: provider.resource,
    instrumentationScope: scope,
    points: points,
    temporality: switch (kind) {
      InstrumentKind.counter ||
      InstrumentKind.upDownCounter ||
      InstrumentKind.observableCounter ||
      InstrumentKind.observableUpDownCounter ||
      InstrumentKind.histogram => AggregationTemporality.cumulative,
      _ => null,
    },
    isMonotonic: switch (kind) {
      InstrumentKind.counter || InstrumentKind.observableCounter => true,
      InstrumentKind.upDownCounter ||
      InstrumentKind.observableUpDownCounter => false,
      _ => null,
    },
  );
}

final class _SumInstrument<T extends num> extends _Collector
    implements Counter<T>, UpDownCounter<T> {
  _SumInstrument({
    required super.provider,
    required super.scope,
    required super.name,
    required super.kind,
    required super.description,
    required super.unit,
    required super.cardinalityLimit,
    required this.monotonic,
  });

  final bool monotonic;
  final Map<String, num> _values = {};

  @override
  void add(T value, {Map<String, Object?> attributes = const {}}) {
    if (provider._shutdown) return;
    _validateMeasurement(value);
    if (monotonic && value < 0) {
      throw ArgumentError.value(
        value,
        'value',
        'Counter values must be positive',
      );
    }
    final attributeKey = key(attributes);
    if (!canAdd(attributeKey, _values)) return;
    _values[attributeKey] = (_values[attributeKey] ?? 0) + value;
  }

  @override
  MetricData snapshot() => data([
    for (final entry in _values.entries)
      MetricPoint(
        attributes: decodeKey(entry.key),
        startTime: provider.startTime,
        timestamp: DateTime.now(),
        value: entry.value,
      ),
  ]);
}

final class _GaugeInstrument<T extends num> extends _Collector
    implements Gauge<T> {
  _GaugeInstrument({
    required super.provider,
    required super.scope,
    required super.name,
    required super.description,
    required super.unit,
    required super.cardinalityLimit,
  }) : super(kind: InstrumentKind.gauge);

  final Map<String, num> _values = {};

  @override
  void record(T value, {Map<String, Object?> attributes = const {}}) {
    if (provider._shutdown) return;
    _validateMeasurement(value);
    final attributeKey = key(attributes);
    if (!canAdd(attributeKey, _values)) return;
    _values[attributeKey] = value;
  }

  @override
  MetricData snapshot() => data([
    for (final entry in _values.entries)
      MetricPoint(
        attributes: decodeKey(entry.key),
        timestamp: DateTime.now(),
        value: entry.value,
      ),
  ]);
}

final class _HistogramInstrument<T extends num> extends _Collector
    implements Histogram<T> {
  _HistogramInstrument({
    required super.provider,
    required super.scope,
    required super.name,
    required super.description,
    required super.unit,
    required super.cardinalityLimit,
    required this.boundaries,
  }) : super(kind: InstrumentKind.histogram);

  final List<double> boundaries;
  final Map<String, _HistogramState> _values = {};

  @override
  bool isCompatibleWith(_Collector other) =>
      super.isCompatibleWith(other) &&
      other is _HistogramInstrument<T> &&
      _listEquals(boundaries, other.boundaries);

  @override
  void record(T value, {Map<String, Object?> attributes = const {}}) {
    if (provider._shutdown) return;
    _validateMeasurement(value);
    final attributeKey = key(attributes);
    if (!canAdd(attributeKey, _values)) return;
    final state = _values.putIfAbsent(
      attributeKey,
      () => _HistogramState(boundaries.length + 1),
    );
    state.record(value, boundaries);
  }

  @override
  MetricData snapshot() => data([
    for (final entry in _values.entries)
      MetricPoint(
        attributes: decodeKey(entry.key),
        startTime: provider.startTime,
        timestamp: DateTime.now(),
        count: entry.value.count,
        sum: entry.value.sum,
        min: entry.value.min,
        max: entry.value.max,
        boundaries: boundaries,
        bucketCounts: entry.value.bucketCounts,
      ),
  ]);
}

final class _HistogramState {
  _HistogramState(int bucketCount) : bucketCounts = List.filled(bucketCount, 0);

  int count = 0;
  num sum = 0;
  num? min;
  num? max;
  final List<int> bucketCounts;

  void record(num value, List<double> boundaries) {
    count++;
    sum += value;
    min = min == null || value < min! ? value : min;
    max = max == null || value > max! ? value : max;
    var index = 0;
    while (index < boundaries.length && value > boundaries[index]) {
      index++;
    }
    bucketCounts[index]++;
  }
}

final class _ObservableInstrument<T extends num> extends _Collector
    implements
        ObservableCounter<T>,
        ObservableUpDownCounter<T>,
        ObservableGauge<T> {
  _ObservableInstrument({
    required super.provider,
    required super.scope,
    required super.name,
    required super.kind,
    required super.description,
    required super.unit,
    required super.cardinalityLimit,
    required this.callback,
    required this.monotonic,
  });

  final Iterable<Observation<T>> Function() callback;
  final bool monotonic;

  @override
  MetricData snapshot() {
    final points = <MetricPoint>[];
    final observedKeys = <String>{};
    try {
      for (final observation in callback()) {
        _validateMeasurement(observation.value);
        if (points.length >= cardinalityLimit) {
          provider._droppedMeasurements++;
          break;
        }
        if (monotonic && observation.value < 0) continue;
        final attributeKey = key(observation.attributes);
        if (!observedKeys.add(attributeKey)) continue;
        points.add(
          MetricPoint(
            attributes: decodeKey(attributeKey),
            startTime: kind == InstrumentKind.observableGauge
                ? null
                : provider.startTime,
            timestamp: DateTime.now(),
            value: observation.value,
          ),
        );
      }
    } catch (error, stackTrace) {
      reportTelemetryError(provider.onInternalError, error, stackTrace);
      return data(const []);
    }
    return data(points);
  }
}

void _validateMeasurement(num value) {
  if (value is double && !value.isFinite) {
    throw ArgumentError.value(value, 'value', 'Must be finite');
  }
}

void _validateBoundaries(List<double> boundaries) {
  for (var index = 0; index < boundaries.length; index++) {
    final boundary = boundaries[index];
    if (!boundary.isFinite) {
      throw ArgumentError.value(boundary, 'boundaries', 'Must be finite');
    }
    if (index > 0 && boundary <= boundaries[index - 1]) {
      throw ArgumentError.value(
        boundaries,
        'boundaries',
        'Must not contain duplicate values',
      );
    }
  }
}

bool _listEquals(List<Object?> first, List<Object?> second) {
  if (first.length != second.length) return false;
  for (var index = 0; index < first.length; index++) {
    if (first[index] != second[index]) return false;
  }
  return true;
}
