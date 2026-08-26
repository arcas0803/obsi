import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:obsi/obsi.dart';
import 'package:obsi_exporter_otlp/obsi_exporter_otlp.dart';
import 'package:test/test.dart';

void main() {
  test('exports spans using the OTLP HTTP JSON shape', () async {
    String? requestBody;
    final client = MockClient((request) async {
      requestBody = request.body;
      expect(request.headers['content-type'], 'application/json');
      return http.Response('', 200);
    });
    final exporter = OtlpHttpSpanExporter(
      protocol: OtlpHttpProtocol.httpJson,
      endpoint: Uri.parse('http://collector.test/v1/traces'),
      client: client,
    );
    final provider = TracerProvider(
      processor: SimpleSpanProcessor(exporter),
      resource: Resource({'service.name': 'test-service'}),
    );

    await provider.tracer.trace('operation', () async {});
    await provider.shutdown();

    final payload = jsonDecode(requestBody!) as Map<String, Object?>;
    final resourceSpans = payload['resourceSpans'] as List;
    expect(resourceSpans, hasLength(1));
    expect(requestBody, contains('test-service'));
    expect(requestBody, contains('operation'));
  });

  test(
    'exports binary Protobuf by default with canonical OTLP fields',
    () async {
      late Uint8List body;
      final exporter = OtlpHttpSpanExporter(
        client: MockClient((request) async {
          expect(request.headers['content-type'], 'application/x-protobuf');
          expect(
            request.headers['user-agent'],
            contains('OTel-OTLP-Exporter-Dart/1.0.0'),
          );
          body = request.bodyBytes;
          return http.Response.bytes(const [], 200);
        }),
      );

      await exporter.export([_spanData()]);

      final resourceSpans = _protobufMessages(body, 1).single;
      final scopeSpans = _protobufMessages(resourceSpans, 2).single;
      final span = _protobufMessages(scopeSpans, 2).single;
      expect(_protobufBytes(span, 1).single, hasLength(16));
      expect(_protobufBytes(span, 2).single, hasLength(8));
      expect(utf8.decode(_protobufBytes(span, 5).single), 'manual');
    },
  );

  test(
    'exports Protobuf logs and metrics and decodes partial success',
    () async {
      final contentTypes = <String>[];
      final client = MockClient((request) async {
        contentTypes.add(request.headers['content-type']!);
        expect(request.bodyBytes, isNotEmpty);
        if (request.url.path.endsWith('/logs')) {
          return http.Response.bytes(
            _protobufPartialSuccess(2, 'invalid attributes'),
            200,
            headers: {'content-type': 'application/x-protobuf'},
          );
        }
        return http.Response.bytes(const [], 200);
      });
      final logs = OtlpHttpLogExporter(client: client);
      final metrics = OtlpHttpMetricExporter(client: client);

      await expectLater(
        logs.export([_logRecord('partial')]),
        throwsA(
          isA<OtlpPartialSuccessException>()
              .having((error) => error.rejectedItems, 'rejectedItems', 2)
              .having(
                (error) => error.message,
                'message',
                'invalid attributes',
              ),
        ),
      );
      await metrics.export([
        _metricData(
          InstrumentKind.counter,
          point: MetricPoint(
            attributes: const {},
            timestamp: DateTime.utc(2026),
            value: 1,
          ),
        ),
      ]);

      expect(contentTypes, everyElement('application/x-protobuf'));
    },
  );

  test('reports non-success HTTP responses', () async {
    final exportErrors = <Object>[];
    final client = MockClient((_) async => http.Response('unavailable', 503));
    final exporter = OtlpHttpSpanExporter(
      protocol: OtlpHttpProtocol.httpJson,
      client: client,
      maxRetries: 0,
    );
    final provider = TracerProvider(
      processor: SimpleSpanProcessor(
        exporter,
        onExportError: (error, _) => exportErrors.add(error),
      ),
    );

    await provider.tracer.trace('operation', () async {});

    await expectLater(provider.forceFlush(), completes);
    expect(exportErrors.single, isA<OtlpExportException>());
    await provider.shutdown();
  });

  test('exports logs and metrics to their signal endpoints', () async {
    final bodies = <String, String>{};
    final client = MockClient((request) async {
      bodies[request.url.path] = request.body;
      return http.Response('', 200);
    });
    final resource = Resource({'service.name': 'signals'});
    final scope = InstrumentationScope('test');
    final logExporter = OtlpHttpLogExporter(
      protocol: OtlpHttpProtocol.httpJson,
      client: client,
    );
    final metricExporter = OtlpHttpMetricExporter(
      protocol: OtlpHttpProtocol.httpJson,
      client: client,
    );

    await logExporter.export([
      LogRecord(
        timestamp: DateTime.utc(2026),
        observedTimestamp: DateTime.utc(2026),
        severity: LogSeverity.info,
        body: 'ready',
        resource: resource,
        instrumentationScope: scope,
        attributes: const {},
      ),
    ]);
    await metricExporter.export([
      MetricData(
        name: 'requests',
        kind: InstrumentKind.counter,
        description: null,
        unit: '{request}',
        resource: resource,
        instrumentationScope: scope,
        points: [
          MetricPoint(
            attributes: const {},
            timestamp: DateTime.utc(2026),
            value: 3,
          ),
        ],
      ),
    ]);

    expect(bodies['/v1/logs'], contains('resourceLogs'));
    expect(bodies['/v1/logs'], contains('ready'));
    expect(bodies['/v1/metrics'], contains('resourceMetrics'));
    expect(bodies['/v1/metrics'], contains('requests'));
  });

  test('compresses OTLP requests with gzip', () async {
    String? decodedBody;
    final client = MockClient((request) async {
      expect(request.headers['content-encoding'], 'gzip');
      decodedBody = utf8.decode(gzip.decode(request.bodyBytes));
      return http.Response('', 200);
    });
    final exporter = OtlpHttpLogExporter(
      protocol: OtlpHttpProtocol.httpJson,
      client: client,
      compression: OtlpCompression.gzip,
    );

    await exporter.export([_logRecord('compressed')]);

    expect(decodedBody, contains('compressed'));
  });

  test('retries transient failures and honors Retry-After', () async {
    var attempts = 0;
    final delays = <Duration>[];
    final client = MockClient((_) async {
      attempts++;
      if (attempts < 3) {
        return http.Response('', 503, headers: {'retry-after': '0'});
      }
      return http.Response('', 200);
    });
    final exporter = OtlpHttpLogExporter(
      protocol: OtlpHttpProtocol.httpJson,
      client: client,
      maxRetries: 2,
      sleep: (delay) async => delays.add(delay),
    );

    await exporter.export([_logRecord('retry')]);

    expect(attempts, 3);
    expect(delays, [Duration.zero, Duration.zero]);
  });

  test('rejects oversized requests before network I/O', () async {
    var requests = 0;
    final client = MockClient((_) async {
      requests++;
      return http.Response('', 200);
    });
    final exporter = OtlpHttpLogExporter(
      protocol: OtlpHttpProtocol.httpJson,
      client: client,
      maxRequestSize: 1,
    );

    await expectLater(
      exporter.export([_logRecord('too large')]),
      throwsA(isA<OtlpRequestTooLargeException>()),
    );
    expect(requests, 0);
  });

  test('encodes protobuf bytes as base64 and groups resource scopes', () async {
    late Map<String, Object?> payload;
    final client = MockClient((request) async {
      payload = jsonDecode(request.body) as Map<String, Object?>;
      return http.Response('{}', 200);
    });
    final exporter = OtlpHttpSpanExporter(
      protocol: OtlpHttpProtocol.httpJson,
      client: client,
    );
    await exporter.export([_spanData(), _spanData()]);

    final resources = payload['resourceSpans']! as List;
    expect(resources, hasLength(1));
    final scopes = (resources.single as Map)['scopeSpans'] as List;
    expect(scopes, hasLength(1));
    expect((scopes.single as Map)['spans'], hasLength(2));
    expect(
      (scopes.single as Map)['schemaUrl'],
      'https://opentelemetry.io/schemas/1.37.0',
    );
    final span = ((scopes.single as Map)['spans'] as List).first as Map;
    expect(span['traceId'], base64Encode(List<int>.filled(16, 0x11)));
    expect(span['spanId'], base64Encode(List<int>.filled(8, 0x22)));
  });

  test('reports partial success without retrying accepted data', () async {
    var attempts = 0;
    final client = MockClient((_) async {
      attempts++;
      return http.Response(
        jsonEncode({
          'partialSuccess': {
            'rejectedLogRecords': '2',
            'errorMessage': 'invalid attributes',
          },
        }),
        200,
      );
    });
    final exporter = OtlpHttpLogExporter(
      protocol: OtlpHttpProtocol.httpJson,
      client: client,
      maxRetries: 5,
    );

    await expectLater(
      exporter.export([_logRecord('partial')]),
      throwsA(
        isA<OtlpPartialSuccessException>()
            .having((error) => error.rejectedItems, 'rejectedItems', 2)
            .having((error) => error.message, 'message', 'invalid attributes'),
      ),
    );
    expect(attempts, 1);
    expect(exporter.retryCount, 0);
    expect(exporter.failureCount, 1);
  });

  test('rejects oversized responses and does not retry them', () async {
    var attempts = 0;
    final exporter = OtlpHttpLogExporter(
      protocol: OtlpHttpProtocol.httpJson,
      client: MockClient((_) async {
        attempts++;
        return http.Response('12345', 200);
      }),
      maxResponseSize: 4,
      maxRetries: 5,
    );

    await expectLater(
      exporter.export([_logRecord('response')]),
      throwsA(isA<OtlpResponseTooLargeException>()),
    );
    expect(attempts, 1);
  });

  test('environment configuration honors signal-specific overrides', () async {
    late http.Request captured;
    final exporter = OtlpHttpSpanExporter.fromEnvironment(
      environment: {
        'OTEL_EXPORTER_OTLP_ENDPOINT': 'https://collector.test/base/',
        'OTEL_EXPORTER_OTLP_HEADERS': 'authorization=Bearer%20common,x=1',
        'OTEL_EXPORTER_OTLP_TRACES_HEADERS': 'x=2,tenant=acme',
        'OTEL_EXPORTER_OTLP_TRACES_TIMEOUT': '2500',
        'OTEL_EXPORTER_OTLP_COMPRESSION': 'gzip',
      },
      client: MockClient((request) async {
        captured = request;
        return http.Response('', 200);
      }),
    );

    await exporter.export([_spanData()]);

    expect(captured.url.toString(), 'https://collector.test/base/v1/traces');
    expect(captured.headers['authorization'], 'Bearer common');
    expect(captured.headers['x'], '2');
    expect(captured.headers['tenant'], 'acme');
    expect(captured.headers['content-encoding'], 'gzip');
    expect(captured.headers['content-type'], 'application/x-protobuf');
    expect(exporter.timeout, const Duration(milliseconds: 2500));
    expect(exporter.protocol, OtlpHttpProtocol.httpProtobuf);
  });

  test('empty batches avoid network I/O and shutdown is terminal', () async {
    var requests = 0;
    final exporter = OtlpHttpLogExporter(
      protocol: OtlpHttpProtocol.httpJson,
      client: MockClient((_) async {
        requests++;
        return http.Response('', 200);
      }),
    );

    await exporter.export(const []);
    await Future.wait([exporter.shutdown(), exporter.shutdown()]);

    expect(requests, 0);
    await expectLater(
      exporter.export([_logRecord('late')]),
      throwsA(isA<StateError>()),
    );
  });

  test('serializes complete span, log, and metric data models', () async {
    final payloads = <String, Map<String, Object?>>{};
    final client = MockClient((request) async {
      payloads[request.url.path] =
          jsonDecode(request.body) as Map<String, Object?>;
      return http.Response('', 200);
    });
    final scope = InstrumentationScope('complete', version: '1');
    final resource = Resource({'service.name': 'complete'});
    final context = SpanContext(
      traceId: 'a' * 32,
      spanId: 'b' * 16,
      sampled: false,
      traceState: 'vendor=value',
    );
    final span = SpanData(
      name: 'complete',
      context: context,
      parentSpanId: 'c' * 16,
      kind: SpanKind.server,
      startTime: DateTime.utc(2026),
      endTime: DateTime.utc(2026, 1, 1, 0, 0, 1),
      status: SpanStatus.error,
      statusDescription: 'failed',
      resource: resource,
      instrumentationScope: scope,
      attributes: const {
        'string': 'value',
        'bool': true,
        'int': 7,
        'double': 1.5,
        'array': [1, 2],
      },
      events: [
        SpanEvent(
          name: 'event',
          timestamp: DateTime.utc(2026),
          attributes: const {'event.value': 1},
        ),
      ],
      links: [
        SpanLink(
          SpanContext(traceId: 'd' * 32, spanId: 'e' * 16, sampled: true),
          attributes: const {'link.value': true},
        ),
      ],
      droppedAttributes: 1,
      droppedEvents: 2,
      droppedLinks: 3,
    );
    final logRecords = <LogRecord>[
      for (final severity in LogSeverity.values)
        LogRecord(
          timestamp: DateTime.utc(2026),
          observedTimestamp: DateTime.utc(2026),
          severity: severity,
          body: switch (severity) {
            LogSeverity.trace => null,
            LogSeverity.debug => true,
            LogSeverity.info => 1,
            LogSeverity.warn => 1.5,
            LogSeverity.error => const [1, 2],
            LogSeverity.fatal => Uri.parse('scheme:value'),
          },
          resource: resource,
          instrumentationScope: scope,
          attributes: const {},
          spanContext: context,
          error: severity == LogSeverity.error ? StateError('log') : null,
          stackTrace: severity == LogSeverity.error ? StackTrace.current : null,
        ),
    ];
    final metrics = [
      _metricData(
        InstrumentKind.histogram,
        point: MetricPoint(
          attributes: const {'route': '/users'},
          timestamp: DateTime.utc(2026),
          count: 3,
          sum: 6,
          min: 1,
          max: 3,
          boundaries: const [1, 2],
          bucketCounts: const [1, 1, 1],
        ),
      ),
      _metricData(
        InstrumentKind.gauge,
        point: MetricPoint(
          attributes: const {},
          timestamp: DateTime.utc(2026),
          value: 1.5,
        ),
      ),
      _metricData(
        InstrumentKind.observableGauge,
        point: MetricPoint(
          attributes: const {},
          timestamp: DateTime.utc(2026),
          value: 2.5,
        ),
      ),
      _metricData(
        InstrumentKind.counter,
        point: MetricPoint(
          attributes: const {},
          timestamp: DateTime.utc(2026),
          value: 4,
        ),
      ),
      _metricData(
        InstrumentKind.observableCounter,
        point: MetricPoint(
          attributes: const {},
          timestamp: DateTime.utc(2026),
          value: 5,
        ),
      ),
      _metricData(
        InstrumentKind.upDownCounter,
        point: MetricPoint(
          attributes: const {},
          timestamp: DateTime.utc(2026),
          value: -1,
        ),
      ),
    ];

    await OtlpHttpSpanExporter(
      protocol: OtlpHttpProtocol.httpJson,
      client: client,
    ).export([span]);
    await OtlpHttpLogExporter(
      protocol: OtlpHttpProtocol.httpJson,
      client: client,
    ).export(logRecords);
    await OtlpHttpMetricExporter(
      protocol: OtlpHttpProtocol.httpJson,
      client: client,
    ).export(metrics);

    final encoded = jsonEncode(payloads);
    expect(encoded, contains('vendor=value'));
    expect(encoded, contains('parentSpanId'));
    expect(encoded, contains('event.value'));
    expect(encoded, contains('link.value'));
    expect(encoded, contains('exception.stacktrace'));
    expect(encoded, contains('histogram'));
    expect(encoded, contains('gauge'));
    expect(encoded, contains('isMonotonic'));
    expect(encoded, contains('asInt'));
    expect(encoded, contains('asDouble'));

    final protobufRequests = <http.Request>[];
    final protobufClient = MockClient((request) async {
      protobufRequests.add(request);
      return http.Response.bytes(const [], 200);
    });
    final spanExporter = OtlpHttpSpanExporter(client: protobufClient);
    final logExporter = OtlpHttpLogExporter(client: protobufClient);
    final metricExporter = OtlpHttpMetricExporter(client: protobufClient);
    await spanExporter.export([span]);
    await logExporter.export(logRecords);
    await metricExporter.export(metrics);
    await Future.wait([
      spanExporter.shutdown(),
      logExporter.shutdown(),
      metricExporter.shutdown(),
    ]);

    expect(protobufRequests, hasLength(3));
    expect(
      protobufRequests.every(
        (request) =>
            request.headers['content-type'] == 'application/x-protobuf' &&
            request.bodyBytes.isNotEmpty,
      ),
      isTrue,
    );
  });

  test('validates configuration and unsupported protocols eagerly', () {
    expect(
      () => OtlpHttpLogExporter(
        protocol: OtlpHttpProtocol.httpJson,
        endpoint: Uri.parse('ftp://collector.test'),
      ),
      throwsArgumentError,
    );
    expect(
      () => OtlpHttpLogExporter(
        protocol: OtlpHttpProtocol.httpJson,
        endpoint: Uri.parse('http:/missing-host'),
      ),
      throwsArgumentError,
    );
    expect(
      () => OtlpHttpLogExporter(
        protocol: OtlpHttpProtocol.httpJson,
        maxRequestSize: 0,
      ),
      throwsArgumentError,
    );
    expect(
      () => OtlpHttpLogExporter(
        protocol: OtlpHttpProtocol.httpJson,
        maxResponseSize: 0,
      ),
      throwsArgumentError,
    );
    expect(
      () => OtlpHttpLogExporter(
        protocol: OtlpHttpProtocol.httpJson,
        maxRetries: -1,
      ),
      throwsArgumentError,
    );
    expect(
      () => OtlpHttpLogExporter(
        protocol: OtlpHttpProtocol.httpJson,
        timeout: Duration.zero,
      ),
      throwsArgumentError,
    );
    expect(
      () => OtlpHttpEnvironmentConfiguration.fromEnvironment(
        OtlpSignal.logs,
        environment: const {'OTEL_EXPORTER_OTLP_TIMEOUT': 'bad'},
      ),
      throwsFormatException,
    );
    expect(
      () => OtlpHttpEnvironmentConfiguration.fromEnvironment(
        OtlpSignal.logs,
        environment: const {'OTEL_EXPORTER_OTLP_COMPRESSION': 'brotli'},
      ),
      throwsFormatException,
    );
    expect(
      () => OtlpHttpEnvironmentConfiguration.fromEnvironment(
        OtlpSignal.logs,
        environment: const {'OTEL_EXPORTER_OTLP_PROTOCOL': 'grpc'},
      ),
      throwsFormatException,
    );
  });

  test('shutdown waits for an accepted in-flight request', () async {
    final accepted = Completer<void>();
    final release = Completer<void>();
    final exporter = OtlpHttpLogExporter(
      client: MockClient((_) async {
        accepted.complete();
        await release.future;
        return http.Response.bytes(const [], 200);
      }),
    );

    final export = exporter.export([_logRecord('pending')]);
    await accepted.future;
    var shutdownCompleted = false;
    final shutdown = exporter.shutdown().then((_) => shutdownCompleted = true);
    await Future<void>.delayed(Duration.zero);
    expect(shutdownCompleted, isFalse);

    release.complete();
    await Future.wait([export, shutdown]);
    expect(shutdownCompleted, isTrue);
  });

  test(
    'retries client failures and stops after the configured limit',
    () async {
      var attempts = 0;
      final exporter = OtlpHttpLogExporter(
        protocol: OtlpHttpProtocol.httpJson,
        client: MockClient((request) async {
          attempts++;
          throw http.ClientException('offline', request.url);
        }),
        maxRetries: 1,
        sleep: (_) async {},
      );

      await expectLater(
        exporter.export([_logRecord('offline')]),
        throwsA(isA<http.ClientException>()),
      );
      expect(attempts, 2);
      expect(exporter.retryCount, 1);
      expect(exporter.failureCount, 1);
    },
  );

  test('exception diagnostics remain useful', () {
    expect(const OtlpExportException(500, 'bad').toString(), contains('500'));
    expect(const OtlpRequestTooLargeException(2, 1).toString(), contains('2'));
    expect(const OtlpResponseTooLargeException(2, 1).toString(), contains('1'));
    expect(
      const OtlpPartialSuccessException(
        rejectedItems: 0,
        message: '',
      ).toString(),
      contains('0'),
    );
  });
}

LogRecord _logRecord(String body) => LogRecord(
  timestamp: DateTime.utc(2026),
  observedTimestamp: DateTime.utc(2026),
  severity: LogSeverity.info,
  body: body,
  resource: Resource({'service.name': 'checkout'}),
  instrumentationScope: InstrumentationScope(
    'test.scope',
    version: '1.0.0',
    schemaUrl: 'https://opentelemetry.io/schemas/1.37.0',
  ),
  attributes: const {},
);

SpanData _spanData() => SpanData(
  name: 'manual',
  context: SpanContext(traceId: '1' * 32, spanId: '2' * 16, sampled: true),
  parentSpanId: null,
  kind: SpanKind.internal,
  startTime: DateTime.utc(2026),
  endTime: DateTime.utc(2026, 1, 1, 0, 0, 1),
  status: SpanStatus.unset,
  statusDescription: null,
  resource: Resource({'service.name': 'checkout'}),
  instrumentationScope: InstrumentationScope(
    'test.scope',
    version: '1.0.0',
    schemaUrl: 'https://opentelemetry.io/schemas/1.37.0',
  ),
  attributes: const {},
  events: const [],
  links: const [],
);

MetricData _metricData(InstrumentKind kind, {required MetricPoint point}) =>
    MetricData(
      name: kind.name,
      kind: kind,
      description: 'description',
      unit: '1',
      resource: Resource({'service.name': 'complete'}),
      instrumentationScope: InstrumentationScope('complete', version: '1'),
      points: [point],
    );

List<Uint8List> _protobufMessages(Uint8List bytes, int wantedField) =>
    _protobufBytes(bytes, wantedField);

List<Uint8List> _protobufBytes(Uint8List bytes, int wantedField) {
  final values = <Uint8List>[];
  var offset = 0;
  while (offset < bytes.length) {
    final tag = _readVarint(bytes, offset);
    offset = tag.next;
    final field = tag.value >> 3;
    final wire = tag.value & 7;
    switch (wire) {
      case 0:
        offset = _readVarint(bytes, offset).next;
        continue;
      case 1:
        offset += 8;
        continue;
      case 2:
        final length = _readVarint(bytes, offset);
        offset = length.next;
        final end = offset + length.value;
        if (field == wantedField) {
          values.add(Uint8List.sublistView(bytes, offset, end));
        }
        offset = end;
        continue;
      case 5:
        offset += 4;
        continue;
      default:
        throw FormatException('Unsupported wire type $wire');
    }
  }
  return values;
}

({int value, int next}) _readVarint(Uint8List bytes, int start) {
  var value = 0;
  var shift = 0;
  var offset = start;
  while (offset < bytes.length) {
    final byte = bytes[offset++];
    value |= (byte & 0x7f) << shift;
    if (byte & 0x80 == 0) return (value: value, next: offset);
    shift += 7;
  }
  throw const FormatException('Truncated varint');
}

Uint8List _protobufPartialSuccess(int rejected, String message) {
  final encodedMessage = utf8.encode(message);
  final nested = <int>[
    0x08,
    rejected,
    0x12,
    encodedMessage.length,
    ...encodedMessage,
  ];
  return Uint8List.fromList([0x0a, nested.length, ...nested]);
}
