import 'dart:async';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:obsi/obsi.dart';
import 'package:obsi_instrumentation_http/obsi_instrumentation_http.dart';
import 'package:test/test.dart';

void main() {
  test('creates a client span and injects trace context', () async {
    final exporter = _MemorySpanExporter();
    final provider = TracerProvider(processor: SimpleSpanProcessor(exporter));
    final metricExporter = _MemoryMetricExporter();
    final reader = ManualMetricReader(metricExporter);
    final meterProvider = MeterProvider(readers: [reader]);
    final inner = MockClient((request) async {
      expect(request.headers['traceparent'], isNotNull);
      expect(request.headers['baggage'], 'tenant=acme');
      return http.Response('ok', 200);
    });
    final client = ObsiHttpClient(
      inner,
      tracer: provider.tracer,
      meter: meterProvider.getMeter('http.client'),
    );

    final response = await Baggage.empty
        .set('tenant', 'acme')
        .run(() => client.get(Uri.parse('https://example.test/users')));
    await provider.forceFlush();
    await reader.collect();

    expect(response.body, 'ok');
    expect(exporter.spans.single.kind, SpanKind.client);
    expect(exporter.spans.single.attributes['http.response.status_code'], 200);
    expect(exporter.spans.single.status, SpanStatus.unset);
    expect(
      exporter.spans.single.attributes['url.full'],
      'https://example.test/users',
    );
    expect(
      metricExporter.metrics.single.name,
      SemanticMetrics.httpClientRequestDuration,
    );
    final point = metricExporter.metrics.single.points.single;
    expect(point.attributes[SemanticAttributes.serverAddress], 'example.test');
    expect(point.attributes[SemanticAttributes.serverPort], 443);
    expect(point.boundaries, SemanticMetrics.httpDurationBoundaries);
    await provider.shutdown();
    await meterProvider.shutdown();
  });

  test(
    'redacts URL credentials, query values, and fragments by default',
    () async {
      final exporter = _MemorySpanExporter();
      final provider = TracerProvider(processor: SimpleSpanProcessor(exporter));
      final client = ObsiHttpClient(
        MockClient((_) async => http.Response('', 200)),
        tracer: provider.tracer,
      );

      await client.get(
        Uri.parse('https://user:secret@example.test/search?q=secret#private'),
      );
      await provider.shutdown();

      final url = exporter.spans.single.attributes['url.full'] as String;
      expect(url, isNot(contains('secret')));
      expect(url, isNot(contains('user')));
      expect(url, isNot(contains('private')));
      expect(url, contains('redacted'));
    },
  );

  test(
    'marks client HTTP errors without a redundant status description',
    () async {
      final exporter = _MemorySpanExporter();
      final provider = TracerProvider(processor: SimpleSpanProcessor(exporter));
      final client = ObsiHttpClient(
        MockClient((_) async => http.Response('', 404)),
        tracer: provider.tracer,
      );

      await client.get(Uri.parse('https://example.test/missing'));
      await provider.shutdown();

      final span = exporter.spans.single;
      expect(span.status, SpanStatus.error);
      expect(span.statusDescription, isNull);
      expect(span.attributes[SemanticAttributes.errorType], '404');
    },
  );

  test('keeps the span open until a streamed body completes', () async {
    final exporter = _MemorySpanExporter();
    final provider = TracerProvider(processor: SimpleSpanProcessor(exporter));
    final inner = _ControlledClient();
    final client = ObsiHttpClient(inner, tracer: provider.tracer);

    final response = await client.send(
      http.Request('GET', Uri.parse('https://example.test/stream')),
    );
    await provider.forceFlush();
    expect(exporter.spans, isEmpty);

    final body = response.stream.toList();
    inner.controller
      ..add([1, 2, 3])
      ..close();
    expect(await body, [
      [1, 2, 3],
    ]);
    await provider.shutdown();

    expect(exporter.spans, hasLength(1));
  });

  test(
    'records response stream errors and preserves their stack trace',
    () async {
      final exporter = _MemorySpanExporter();
      final provider = TracerProvider(processor: SimpleSpanProcessor(exporter));
      final inner = _ControlledClient();
      final client = ObsiHttpClient(inner, tracer: provider.tracer);
      final response = await client.send(
        http.Request('GET', Uri.parse('https://example.test/stream')),
      );
      final stackTrace = StackTrace.current;
      final drained = response.stream.drain<void>();

      inner.controller
        ..addError(StateError('stream failed'), stackTrace)
        ..close();

      await expectLater(drained, throwsStateError);
      await provider.shutdown();
      final span = exporter.spans.single;
      expect(span.status, SpanStatus.error);
      expect(span.attributes[SemanticAttributes.errorType], 'StateError');
      expect(
        span.events.single.attributes['exception.stacktrace'],
        '$stackTrace',
      );
    },
  );

  test('records transport errors and rethrows the original error', () async {
    final exporter = _MemorySpanExporter();
    final provider = TracerProvider(processor: SimpleSpanProcessor(exporter));
    final metricExporter = _MemoryMetricExporter();
    final reader = ManualMetricReader(metricExporter);
    final meterProvider = MeterProvider(readers: [reader]);
    final client = ObsiHttpClient(
      MockClient((_) async => throw StateError('offline')),
      tracer: provider.tracer,
      meter: meterProvider.getMeter('http.client'),
    );

    await expectLater(
      client.get(Uri.parse('https://example.test')),
      throwsStateError,
    );
    await provider.shutdown();
    await reader.collect();

    expect(exporter.spans.single.status, SpanStatus.error);
    expect(
      exporter.spans.single.attributes[SemanticAttributes.errorType],
      'StateError',
    );
    final point = metricExporter.metrics.single.points.single;
    expect(point.attributes[SemanticAttributes.errorType], 'StateError');
    expect(point.attributes[SemanticAttributes.serverAddress], 'example.test');
    expect(point.attributes[SemanticAttributes.serverPort], 443);
    await meterProvider.shutdown();
  });

  test('normalizes unknown HTTP methods and preserves the original', () async {
    final exporter = _MemorySpanExporter();
    final provider = TracerProvider(processor: SimpleSpanProcessor(exporter));
    final client = ObsiHttpClient(
      MockClient((_) async => http.Response('', 200)),
      tracer: provider.tracer,
    );

    await client
        .send(
          http.Request('PROPFIND', Uri.parse('https://example.test/resource')),
        )
        .then((response) => response.stream.drain<void>());
    await provider.shutdown();

    final attributes = exporter.spans.single.attributes;
    expect(attributes[SemanticAttributes.httpRequestMethod], '_OTHER');
    expect(
      attributes[SemanticAttributes.httpRequestMethodOriginal],
      'PROPFIND',
    );
  });

  test('supports filtering and does not mutate skipped requests', () async {
    final exporter = _MemorySpanExporter();
    final provider = TracerProvider(processor: SimpleSpanProcessor(exporter));
    final client = ObsiHttpClient(
      MockClient((request) async {
        expect(request.headers['traceparent'], isNull);
        return http.Response('', 200);
      }),
      tracer: provider.tracer,
      options: const ObsiHttpClientOptions(shouldInstrument: _neverInstrument),
    );

    await client.get(Uri.parse('https://collector.test/v1/traces'));
    await provider.shutdown();

    expect(exporter.spans, isEmpty);
  });

  test('isolates callback failures and invalid custom attributes', () async {
    final diagnostics = <Object>[];
    final exporter = _MemorySpanExporter();
    final provider = TracerProvider(processor: SimpleSpanProcessor(exporter));
    final client = ObsiHttpClient(
      MockClient((_) async => http.Response('', 200)),
      tracer: provider.tracer,
      options: ObsiHttpClientOptions(
        spanNameBuilder: (_) => throw StateError('name'),
        requestAttributes: (_) => const {'invalid': double.nan},
        responseAttributes: (_, _) => throw StateError('response'),
        onInstrumentationError: (error, _) => diagnostics.add(error),
      ),
    );

    final response = await client.get(Uri.parse('https://example.test'));
    await provider.shutdown();

    expect(response.statusCode, 200);
    expect(exporter.spans.single.name, 'GET');
    expect(diagnostics, hasLength(3));
  });

  test('can leave ownership of the wrapped client with the caller', () {
    final inner = _ControlledClient();
    ObsiHttpClient(
      inner,
      options: const ObsiHttpClientOptions(closeInnerClient: false),
    ).close();
    expect(inner.closed, isFalse);

    ObsiHttpClient(inner).close();
    expect(inner.closed, isTrue);
  });

  test('propagator failures never break outbound traffic', () async {
    final diagnostics = <Object>[];
    final client = ObsiHttpClient(
      MockClient((_) async => http.Response('ok', 200)),
      propagator: _ThrowingTracePropagator(),
      baggagePropagator: _ThrowingBaggagePropagator(),
      options: ObsiHttpClientOptions(
        onInstrumentationError: (error, _) => diagnostics.add(error),
      ),
    );

    final response = await client.get(Uri.parse('https://example.test'));

    expect(response.body, 'ok');
    expect(diagnostics, hasLength(2));
  });
}

bool _neverInstrument(http.BaseRequest _) => false;

final class _ControlledClient extends http.BaseClient {
  final StreamController<List<int>> controller = StreamController();
  bool closed = false;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async =>
      http.StreamedResponse(controller.stream, 200, request: request);

  @override
  void close() {
    closed = true;
  }
}

final class _ThrowingTracePropagator implements TracePropagator {
  @override
  SpanContext? extract(Map<String, String> carrier) => null;

  @override
  void inject(SpanContext context, Map<String, String> carrier) {
    throw StateError('trace propagation failed');
  }
}

final class _ThrowingBaggagePropagator implements BaggagePropagator {
  @override
  Baggage extract(Map<String, String> carrier) => Baggage.empty;

  @override
  void inject(Baggage baggage, Map<String, String> carrier) {
    throw StateError('baggage propagation failed');
  }
}

final class _MemoryMetricExporter implements MetricExporter {
  final List<MetricData> metrics = [];

  @override
  Future<void> export(List<MetricData> batch) async => metrics.addAll(batch);
  @override
  Future<void> shutdown() async {}
}

final class _MemorySpanExporter implements SpanExporter {
  final List<SpanData> spans = [];

  @override
  Future<void> export(List<SpanData> batch) async => spans.addAll(batch);
  @override
  Future<void> shutdown() async {}
}
