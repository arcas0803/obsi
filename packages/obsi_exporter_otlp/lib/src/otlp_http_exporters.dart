import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:obsi/obsi.dart';

import 'otlp_protobuf.dart';

/// Represents otlp export exception.
final class OtlpExportException implements Exception {
  /// Creates a instance.
  const OtlpExportException(this.statusCode, this.body);

  /// The status code.
  final int statusCode;

  /// The body.
  final String body;

  /// Performs to string.
  @override
  String toString() => 'OTLP export failed with HTTP $statusCode: $body';
}

/// Represents otlp request too large exception.
final class OtlpRequestTooLargeException implements Exception {
  /// Creates a instance.
  const OtlpRequestTooLargeException(this.size, this.limit);

  /// The size.
  final int size;

  /// The limit.
  final int limit;

  /// Performs to string.
  @override
  String toString() => 'OTLP request size $size exceeds limit $limit';
}

/// Represents otlp response too large exception.
final class OtlpResponseTooLargeException implements Exception {
  /// Creates a instance.
  const OtlpResponseTooLargeException(this.size, this.limit);

  /// The size.
  final int size;

  /// The limit.
  final int limit;

  /// Performs to string.
  @override
  String toString() => 'OTLP response size $size exceeds limit $limit';
}

/// Represents otlp partial success exception.
final class OtlpPartialSuccessException implements Exception {
  /// Creates a instance.
  const OtlpPartialSuccessException({
    required this.rejectedItems,
    required this.message,
  });

  /// The rejected items.
  final int rejectedItems;

  /// The message.
  final String message;

  /// Performs to string.
  @override
  String toString() =>
      'OTLP partial success rejected $rejectedItems item(s)'
      '${message.isEmpty ? '' : ': $message'}';
}

/// Defines otlp compression values.
enum OtlpCompression {
  /// The none value.
  none,

  /// The gzip value.
  gzip,
}

/// Wire encoding used for OTLP over HTTP.
enum OtlpHttpProtocol {
  /// Binary Protocol Buffers, the standard OTLP/HTTP default.
  httpProtobuf,

  /// Protobuf JSON mapping for collectors that explicitly enable JSON.
  httpJson,
}

/// Defines otlp signal values.
enum OtlpSignal {
  /// The traces value.
  traces,

  /// The logs value.
  logs,

  /// The metrics value.
  metrics,
}

/// Standard OTLP/HTTP settings resolved from `OTEL_EXPORTER_OTLP_*` variables.
final class OtlpHttpEnvironmentConfiguration {
  OtlpHttpEnvironmentConfiguration._({
    required this.endpoint,
    required this.headers,
    required this.timeout,
    required this.compression,
    required this.protocol,
  });

  /// Creates a instance using the from environment constructor.
  factory OtlpHttpEnvironmentConfiguration.fromEnvironment(
    OtlpSignal signal, {
    Map<String, String>? environment,
  }) {
    final values = environment ?? Platform.environment;
    final signalName = signal.name.toUpperCase();

    /// Performs setting.
    String? setting(String name) =>
        values['OTEL_EXPORTER_OTLP_${signalName}_$name'] ??
        values['OTEL_EXPORTER_OTLP_$name'];

    final signalEndpoint = values['OTEL_EXPORTER_OTLP_${signalName}_ENDPOINT'];
    final baseEndpoint =
        values['OTEL_EXPORTER_OTLP_ENDPOINT'] ?? 'http://localhost:4318';
    final endpoint = signalEndpoint == null
        ? _appendSignalPath(Uri.parse(baseEndpoint), signal)
        : Uri.parse(signalEndpoint);
    final timeoutValue = setting('TIMEOUT');
    final timeoutMilliseconds = timeoutValue == null
        ? 10000
        : int.tryParse(timeoutValue);
    if (timeoutMilliseconds == null || timeoutMilliseconds <= 0) {
      throw FormatException('Invalid OTLP timeout: $timeoutValue');
    }
    final compressionValue = setting('COMPRESSION') ?? 'none';
    final compression = switch (compressionValue.toLowerCase()) {
      'none' => OtlpCompression.none,
      'gzip' => OtlpCompression.gzip,
      _ => throw FormatException(
        'Unsupported OTLP compression: $compressionValue',
      ),
    };
    final protocolValue = setting('PROTOCOL') ?? 'http/protobuf';
    final protocol = switch (protocolValue.toLowerCase()) {
      'http/protobuf' => OtlpHttpProtocol.httpProtobuf,
      'http/json' => OtlpHttpProtocol.httpJson,
      _ => throw FormatException('Unsupported OTLP protocol: $protocolValue'),
    };
    return OtlpHttpEnvironmentConfiguration._(
      endpoint: endpoint,
      headers: {
        ..._parseHeaders(values['OTEL_EXPORTER_OTLP_HEADERS']),
        ..._parseHeaders(values['OTEL_EXPORTER_OTLP_${signalName}_HEADERS']),
      },
      timeout: Duration(milliseconds: timeoutMilliseconds),
      compression: compression,
      protocol: protocol,
    );
  }

  /// The endpoint.
  final Uri endpoint;

  /// The headers.
  final Map<String, String> headers;

  /// The timeout.
  final Duration timeout;

  /// The compression.
  final OtlpCompression compression;

  /// OTLP wire encoding selected for HTTP requests.
  final OtlpHttpProtocol protocol;
}

abstract base class _OtlpHttpExporter {
  _OtlpHttpExporter({
    required this.endpoint,
    Map<String, String> headers = const {},
    this.timeout = const Duration(seconds: 10),
    this.compression = OtlpCompression.none,
    this.protocol = OtlpHttpProtocol.httpProtobuf,
    this.maxRequestSize = 64 * 1024 * 1024,
    this.maxResponseSize = 4 * 1024 * 1024,
    this.maxRetries = 5,
    this.initialBackoff = const Duration(seconds: 1),
    this.maxBackoff = const Duration(seconds: 30),
    http.Client? client,
    Future<void> Function(Duration)? sleep,
    Random? random,
  }) : headers = Map.unmodifiable(headers),
       _client = client ?? http.Client(),
       _ownsClient = client == null,
       _sleep = sleep ?? Future<void>.delayed,
       _random = random ?? Random() {
    if (endpoint.scheme != 'http' && endpoint.scheme != 'https') {
      throw ArgumentError.value(endpoint, 'endpoint', 'Must use HTTP or HTTPS');
    }
    if (!endpoint.hasAuthority || endpoint.host.isEmpty) {
      throw ArgumentError.value(endpoint, 'endpoint', 'Must include a host');
    }
    if (maxRequestSize <= 0) {
      throw ArgumentError.value(maxRequestSize, 'maxRequestSize');
    }
    if (maxResponseSize <= 0) {
      throw ArgumentError.value(maxResponseSize, 'maxResponseSize');
    }
    if (maxRetries < 0) throw ArgumentError.value(maxRetries, 'maxRetries');
    if (timeout <= Duration.zero ||
        initialBackoff <= Duration.zero ||
        maxBackoff <= Duration.zero) {
      throw ArgumentError('Timeout and backoff durations must be positive');
    }
  }

  final Uri endpoint;
  final Map<String, String> headers;
  final Duration timeout;
  final OtlpCompression compression;
  final OtlpHttpProtocol protocol;
  final int maxRequestSize;
  final int maxResponseSize;
  final int maxRetries;
  final Duration initialBackoff;
  final Duration maxBackoff;
  final http.Client _client;
  final bool _ownsClient;
  final Future<void> Function(Duration) _sleep;
  final Random _random;
  bool _shutdown = false;
  Future<void>? _shutdownFuture;
  final Set<Future<void>> _pending = {};
  int _requestCount = 0;
  int _retryCount = 0;
  int _failureCount = 0;

  int get requestCount => _requestCount;
  int get retryCount => _retryCount;
  int get failureCount => _failureCount;

  Future<void> send({
    required Map<String, Object?> Function() jsonPayload,
    required Uint8List Function() protobufPayload,
  }) {
    if (_shutdown) return Future.error(StateError('Exporter is shut down'));
    late final Future<void> operation;
    operation = _send(
      jsonPayload: jsonPayload,
      protobufPayload: protobufPayload,
    ).whenComplete(() => _pending.remove(operation));
    _pending.add(operation);
    return operation;
  }

  Future<void> ensureActive() => _shutdown
      ? Future.error(StateError('Exporter is shut down'))
      : Future.value();

  Future<void> _send({
    required Map<String, Object?> Function() jsonPayload,
    required Uint8List Function() protobufPayload,
  }) async {
    final uncompressed = switch (protocol) {
      OtlpHttpProtocol.httpJson => utf8.encode(jsonEncode(jsonPayload())),
      OtlpHttpProtocol.httpProtobuf => protobufPayload(),
    };
    if (uncompressed.length > maxRequestSize) {
      throw OtlpRequestTooLargeException(uncompressed.length, maxRequestSize);
    }
    final body = compression == OtlpCompression.gzip
        ? gzip.encode(uncompressed)
        : uncompressed;
    var attempt = 0;
    while (true) {
      try {
        _requestCount++;
        final response = await _client
            .post(
              endpoint,
              headers: {
                ...headers,
                'content-type': switch (protocol) {
                  OtlpHttpProtocol.httpJson => 'application/json',
                  OtlpHttpProtocol.httpProtobuf => 'application/x-protobuf',
                },
                'accept-encoding': 'gzip',
                'user-agent': 'OTel-OTLP-Exporter-Dart/1.0.0 Obsi/1.0.0',
                if (compression == OtlpCompression.gzip)
                  'content-encoding': 'gzip',
              },
              body: body,
            )
            .timeout(timeout);
        if (response.bodyBytes.length > maxResponseSize) {
          _failureCount++;
          throw OtlpResponseTooLargeException(
            response.bodyBytes.length,
            maxResponseSize,
          );
        }
        if (response.statusCode >= 200 && response.statusCode < 300) {
          _checkPartialSuccess(response);
          return;
        }
        if (!_isRetryable(response.statusCode) || attempt >= maxRetries) {
          _failureCount++;
          throw OtlpExportException(response.statusCode, response.body);
        }
        _retryCount++;
        await _sleep(_retryDelay(attempt++, response.headers['retry-after']));
      } on OtlpExportException {
        rethrow;
      } on OtlpResponseTooLargeException {
        rethrow;
      } on OtlpPartialSuccessException {
        rethrow;
      } on http.ClientException {
        if (attempt >= maxRetries) {
          _failureCount++;
          rethrow;
        }
        _retryCount++;
        await _sleep(_retryDelay(attempt++, null));
      } on TimeoutException {
        if (attempt >= maxRetries) {
          _failureCount++;
          rethrow;
        }
        _retryCount++;
        await _sleep(_retryDelay(attempt++, null));
      }
    }
  }

  void _checkPartialSuccess(http.Response response) {
    if (response.bodyBytes.isEmpty) return;
    if (protocol == OtlpHttpProtocol.httpProtobuf) {
      final partial = decodePartialSuccess(response.bodyBytes);
      if (partial == null) return;
      _failureCount++;
      throw OtlpPartialSuccessException(
        rejectedItems: partial.rejectedItems,
        message: partial.message,
      );
    }
    Object? decoded;
    try {
      decoded = jsonDecode(response.body);
    } on FormatException {
      return;
    }
    if (decoded is! Map<String, Object?>) return;
    final partial = decoded.values
        .whereType<Map<String, Object?>>()
        .where((value) => value.keys.any((key) => key.startsWith('rejected')))
        .firstOrNull;
    if (partial == null) return;
    final rejected = partial.entries
        .where((entry) => entry.key.startsWith('rejected'))
        .map((entry) => int.tryParse('${entry.value}') ?? 0)
        .fold(0, (total, value) => total + value);
    final message = partial['errorMessage']?.toString() ?? '';
    _failureCount++;
    throw OtlpPartialSuccessException(
      rejectedItems: rejected,
      message: message,
    );
  }

  bool _isRetryable(int statusCode) =>
      statusCode == 429 ||
      statusCode == 502 ||
      statusCode == 503 ||
      statusCode == 504;

  Duration _retryDelay(int attempt, String? retryAfter) {
    if (retryAfter != null) {
      final seconds = int.tryParse(retryAfter);
      if (seconds != null && seconds >= 0) return Duration(seconds: seconds);
      try {
        final delay = HttpDate.parse(
          retryAfter,
        ).difference(DateTime.now().toUtc());
        if (!delay.isNegative) return delay;
      } on FormatException {
        // Fall back to exponential backoff.
      }
    }
    final multiplier = pow(2, attempt).toDouble();
    final uncappedMicros = initialBackoff.inMicroseconds * multiplier;
    final cappedMicros = min(
      uncappedMicros,
      maxBackoff.inMicroseconds.toDouble(),
    );
    final jitter = 0.8 + (_random.nextDouble() * 0.4);
    return Duration(microseconds: (cappedMicros * jitter).round());
  }

  Future<void> close() => _shutdownFuture ??= _close();

  Future<void> _close() async {
    _shutdown = true;
    try {
      while (_pending.isNotEmpty) {
        await Future.wait(_pending.toList(growable: false));
      }
    } finally {
      if (_ownsClient) _client.close();
    }
  }
}

/// Represents otlp http span exporter.
final class OtlpHttpSpanExporter extends _OtlpHttpExporter
    implements SpanExporter {
  /// Creates a instance.
  OtlpHttpSpanExporter({
    Uri? endpoint,
    super.headers,
    super.timeout,
    super.compression,
    super.protocol,
    super.maxRequestSize,
    super.maxResponseSize,
    super.maxRetries,
    super.initialBackoff,
    super.maxBackoff,
    super.client,
    super.sleep,
    super.random,
  }) : super(
         endpoint: endpoint ?? Uri.parse('http://localhost:4318/v1/traces'),
       );

  /// Creates a instance using the from environment constructor.
  factory OtlpHttpSpanExporter.fromEnvironment({
    Map<String, String>? environment,
    http.Client? client,
    Future<void> Function(Duration)? sleep,
    Random? random,
  }) {
    final config = OtlpHttpEnvironmentConfiguration.fromEnvironment(
      OtlpSignal.traces,
      environment: environment,
    );
    return OtlpHttpSpanExporter(
      endpoint: config.endpoint,
      headers: config.headers,
      timeout: config.timeout,
      compression: config.compression,
      protocol: config.protocol,
      client: client,
      sleep: sleep,
      random: random,
    );
  }

  /// Performs export.
  @override
  Future<void> export(List<SpanData> spans) => spans.isEmpty
      ? ensureActive()
      : send(
          jsonPayload: () => {'resourceSpans': _groupSpans(spans)},
          protobufPayload: () => encodeSpanExportRequest(spans),
        );

  /// Performs shutdown.
  @override
  Future<void> shutdown() => close();
}

/// Represents otlp http log exporter.
final class OtlpHttpLogExporter extends _OtlpHttpExporter
    implements LogExporter {
  /// Creates a instance.
  OtlpHttpLogExporter({
    Uri? endpoint,
    super.headers,
    super.timeout,
    super.compression,
    super.protocol,
    super.maxRequestSize,
    super.maxResponseSize,
    super.maxRetries,
    super.initialBackoff,
    super.maxBackoff,
    super.client,
    super.sleep,
    super.random,
  }) : super(endpoint: endpoint ?? Uri.parse('http://localhost:4318/v1/logs'));

  /// Creates a instance using the from environment constructor.
  factory OtlpHttpLogExporter.fromEnvironment({
    Map<String, String>? environment,
    http.Client? client,
    Future<void> Function(Duration)? sleep,
    Random? random,
  }) {
    final config = OtlpHttpEnvironmentConfiguration.fromEnvironment(
      OtlpSignal.logs,
      environment: environment,
    );
    return OtlpHttpLogExporter(
      endpoint: config.endpoint,
      headers: config.headers,
      timeout: config.timeout,
      compression: config.compression,
      protocol: config.protocol,
      client: client,
      sleep: sleep,
      random: random,
    );
  }

  /// Performs export.
  @override
  Future<void> export(List<LogRecord> records) => records.isEmpty
      ? ensureActive()
      : send(
          jsonPayload: () => {'resourceLogs': _groupLogs(records)},
          protobufPayload: () => encodeLogExportRequest(records),
        );

  /// Performs shutdown.
  @override
  Future<void> shutdown() => close();
}

/// Represents otlp http metric exporter.
final class OtlpHttpMetricExporter extends _OtlpHttpExporter
    implements MetricExporter {
  /// Creates a instance.
  OtlpHttpMetricExporter({
    Uri? endpoint,
    super.headers,
    super.timeout,
    super.compression,
    super.protocol,
    super.maxRequestSize,
    super.maxResponseSize,
    super.maxRetries,
    super.initialBackoff,
    super.maxBackoff,
    super.client,
    super.sleep,
    super.random,
  }) : super(
         endpoint: endpoint ?? Uri.parse('http://localhost:4318/v1/metrics'),
       );

  /// Creates a instance using the from environment constructor.
  factory OtlpHttpMetricExporter.fromEnvironment({
    Map<String, String>? environment,
    http.Client? client,
    Future<void> Function(Duration)? sleep,
    Random? random,
  }) {
    final config = OtlpHttpEnvironmentConfiguration.fromEnvironment(
      OtlpSignal.metrics,
      environment: environment,
    );
    return OtlpHttpMetricExporter(
      endpoint: config.endpoint,
      headers: config.headers,
      timeout: config.timeout,
      compression: config.compression,
      protocol: config.protocol,
      client: client,
      sleep: sleep,
      random: random,
    );
  }

  /// Performs export.
  @override
  Future<void> export(List<MetricData> metrics) => metrics.isEmpty
      ? ensureActive()
      : send(
          jsonPayload: () => {'resourceMetrics': _groupMetrics(metrics)},
          protobufPayload: () => encodeMetricExportRequest(metrics),
        );

  /// Performs shutdown.
  @override
  Future<void> shutdown() => close();
}

Map<String, Object?> _resource(Resource resource) => {
  'attributes': _attributes(resource.attributes),
};

Map<String, Object?> _scope(InstrumentationScope scope) => {
  'name': scope.name,
  if (scope.version != null) 'version': scope.version,
  'attributes': _attributes(scope.attributes),
};

List<Map<String, Object?>> _groupSpans(List<SpanData> spans) =>
    _groupByTelemetryContext<SpanData>(
      spans,
      resourceOf: (span) => span.resource,
      scopeOf: (span) => span.instrumentationScope,
      scopeCollectionName: 'scopeSpans',
      itemCollectionName: 'spans',
      encode: _span,
    );

List<Map<String, Object?>> _groupLogs(List<LogRecord> records) =>
    _groupByTelemetryContext<LogRecord>(
      records,
      resourceOf: (record) => record.resource,
      scopeOf: (record) => record.instrumentationScope,
      scopeCollectionName: 'scopeLogs',
      itemCollectionName: 'logRecords',
      encode: _log,
    );

List<Map<String, Object?>> _groupMetrics(List<MetricData> metrics) =>
    _groupByTelemetryContext<MetricData>(
      metrics,
      resourceOf: (metric) => metric.resource,
      scopeOf: (metric) => metric.instrumentationScope,
      scopeCollectionName: 'scopeMetrics',
      itemCollectionName: 'metrics',
      encode: _metric,
    );

List<Map<String, Object?>> _groupByTelemetryContext<T>(
  List<T> items, {
  required Resource Function(T item) resourceOf,
  required InstrumentationScope Function(T item) scopeOf,
  required String scopeCollectionName,
  required String itemCollectionName,
  required Map<String, Object?> Function(T item) encode,
}) {
  final resources = <String, _ResourceGroup<T>>{};
  for (final item in items) {
    final resource = resourceOf(item);
    final scope = scopeOf(item);
    final resourceKey = _attributeKey(resource.attributes);
    final group = resources.putIfAbsent(
      resourceKey,
      () => _ResourceGroup<T>(resource),
    );
    final scopeKey = [
      scope.name,
      scope.version ?? '',
      scope.schemaUrl ?? '',
      _attributeKey(scope.attributes),
    ].join('\u0000');
    group.scopes
        .putIfAbsent(scopeKey, () => _ScopeGroup<T>(scope))
        .items
        .add(item);
  }
  return [
    for (final resourceGroup in resources.values)
      {
        'resource': _resource(resourceGroup.resource),
        scopeCollectionName: [
          for (final scopeGroup in resourceGroup.scopes.values)
            {
              'scope': _scope(scopeGroup.scope),
              if (scopeGroup.scope.schemaUrl != null)
                'schemaUrl': scopeGroup.scope.schemaUrl,
              itemCollectionName: [
                for (final item in scopeGroup.items) encode(item),
              ],
            },
        ],
      },
  ];
}

String _attributeKey(Map<String, Object?> attributes) {
  final keys = attributes.keys.toList()..sort();
  return jsonEncode({for (final key in keys) key: attributes[key]});
}

final class _ResourceGroup<T> {
  _ResourceGroup(this.resource);

  final Resource resource;
  final Map<String, _ScopeGroup<T>> scopes = {};
}

final class _ScopeGroup<T> {
  _ScopeGroup(this.scope);

  final InstrumentationScope scope;
  final List<T> items = [];
}

Map<String, Object?> _span(SpanData span) => {
  'traceId': _hexBytes(span.context.traceId),
  'spanId': _hexBytes(span.context.spanId),
  if (span.parentSpanId != null) 'parentSpanId': _hexBytes(span.parentSpanId!),
  if (span.context.traceState != null) 'traceState': span.context.traceState,
  'flags': span.context.sampled ? 1 : 0,
  'name': span.name,
  'kind': span.kind.index + 1,
  'startTimeUnixNano': _nanos(span.startTime),
  'endTimeUnixNano': _nanos(span.endTime),
  'attributes': _attributes(span.attributes),
  'droppedAttributesCount': span.droppedAttributes,
  'events': [
    for (final event in span.events)
      {
        'timeUnixNano': _nanos(event.timestamp),
        'name': event.name,
        'attributes': _attributes(event.attributes),
      },
  ],
  'droppedEventsCount': span.droppedEvents,
  'links': [
    for (final link in span.links)
      {
        'traceId': _hexBytes(link.context.traceId),
        'spanId': _hexBytes(link.context.spanId),
        'traceState': link.context.traceState ?? '',
        'flags': link.context.sampled ? 1 : 0,
        'attributes': _attributes(link.attributes),
      },
  ],
  'droppedLinksCount': span.droppedLinks,
  'status': {
    'code': switch (span.status) {
      SpanStatus.unset => 0,
      SpanStatus.ok => 1,
      SpanStatus.error => 2,
    },
    if (span.statusDescription != null) 'message': span.statusDescription,
  },
};

Map<String, Object?> _log(LogRecord record) => {
  'timeUnixNano': _nanos(record.timestamp),
  'observedTimeUnixNano': _nanos(record.observedTimestamp),
  'severityNumber': switch (record.severity) {
    LogSeverity.trace => 1,
    LogSeverity.debug => 5,
    LogSeverity.info => 9,
    LogSeverity.warn => 13,
    LogSeverity.error => 17,
    LogSeverity.fatal => 21,
  },
  'severityText': record.severity.name.toUpperCase(),
  'body': _any(record.body),
  'attributes': _attributes({
    ...record.attributes,
    if (record.error != null) 'exception.message': record.error.toString(),
    if (record.stackTrace != null)
      'exception.stacktrace': record.stackTrace.toString(),
  }),
  if (record.spanContext != null) ...{
    'traceId': _hexBytes(record.spanContext!.traceId),
    'spanId': _hexBytes(record.spanContext!.spanId),
    'flags': record.spanContext!.sampled ? 1 : 0,
  },
};

Map<String, Object?> _metric(MetricData metric) {
  final base = <String, Object?>{
    'name': metric.name,
    if (metric.description != null) 'description': metric.description,
    if (metric.unit != null) 'unit': metric.unit,
  };
  if (metric.kind == InstrumentKind.histogram) {
    base['histogram'] = {
      'aggregationTemporality': _temporality(metric.temporality),
      'dataPoints': [
        for (final point in metric.points)
          {
            'attributes': _attributes(point.attributes),
            'timeUnixNano': _nanos(point.timestamp),
            if (point.startTime != null)
              'startTimeUnixNano': _nanos(point.startTime!),
            'count': '${point.count ?? 0}',
            if (point.sum != null) 'sum': point.sum,
            if (point.min != null) 'min': point.min,
            if (point.max != null) 'max': point.max,
            'explicitBounds': point.boundaries,
            'bucketCounts': [for (final count in point.bucketCounts) '$count'],
          },
      ],
    };
  } else {
    final points = [for (final point in metric.points) _numberPoint(point)];
    if (metric.kind == InstrumentKind.gauge ||
        metric.kind == InstrumentKind.observableGauge) {
      base['gauge'] = {'dataPoints': points};
    } else {
      base['sum'] = {
        'aggregationTemporality': _temporality(metric.temporality),
        'isMonotonic': metric.isMonotonic ?? false,
        'dataPoints': points,
      };
    }
  }
  return base;
}

Map<String, Object?> _numberPoint(MetricPoint point) => {
  'attributes': _attributes(point.attributes),
  'timeUnixNano': _nanos(point.timestamp),
  if (point.startTime != null) 'startTimeUnixNano': _nanos(point.startTime!),
  if (point.value is int)
    'asInt': '${point.value}'
  else
    'asDouble': point.value?.toDouble() ?? 0.0,
};

int _temporality(AggregationTemporality? temporality) => switch (temporality) {
  AggregationTemporality.delta => 1,
  AggregationTemporality.cumulative || null => 2,
};

List<Map<String, Object?>> _attributes(Map<String, Object?> attributes) => [
  for (final entry in attributes.entries)
    {'key': entry.key, 'value': _any(entry.value)},
];

Map<String, Object?> _any(Object? value) {
  if (value == null) return {'stringValue': ''};
  if (value is String) return {'stringValue': value};
  if (value is bool) return {'boolValue': value};
  if (value is int) return {'intValue': '$value'};
  if (value is double) return {'doubleValue': value};
  if (value is List) {
    return {
      'arrayValue': {
        'values': [for (final item in value) _any(item)],
      },
    };
  }
  return {'stringValue': value.toString()};
}

String _nanos(DateTime time) => '${time.toUtc().microsecondsSinceEpoch * 1000}';

String _hexBytes(String value) {
  final bytes = <int>[];
  for (var index = 0; index < value.length; index += 2) {
    bytes.add(int.parse(value.substring(index, index + 2), radix: 16));
  }
  return base64Encode(bytes);
}

Uri _appendSignalPath(Uri endpoint, OtlpSignal signal) {
  final basePath = endpoint.path.endsWith('/')
      ? endpoint.path.substring(0, endpoint.path.length - 1)
      : endpoint.path;
  return endpoint.replace(path: '$basePath/v1/${signal.name}');
}

Map<String, String> _parseHeaders(String? value) {
  if (value == null || value.trim().isEmpty) return const {};
  final result = <String, String>{};
  for (final member in value.split(',')) {
    final separator = member.indexOf('=');
    if (separator <= 0) continue;
    final key = member.substring(0, separator).trim();
    final encodedValue = member.substring(separator + 1).trim();
    if (key.isEmpty) continue;
    try {
      result[key] = Uri.decodeComponent(encodedValue);
    } on FormatException {
      continue;
    }
  }
  return Map.unmodifiable(result);
}
