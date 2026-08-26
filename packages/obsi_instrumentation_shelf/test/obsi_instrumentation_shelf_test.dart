import 'dart:async';

import 'package:obsi/obsi.dart';
import 'package:obsi_instrumentation_shelf/obsi_instrumentation_shelf.dart';
import 'package:shelf/shelf.dart';
import 'package:test/test.dart';

void main() {
  test('continues incoming W3C context in a server span', () async {
    final exporter = _MemorySpanExporter();
    final provider = TracerProvider(processor: SimpleSpanProcessor(exporter));
    final metricExporter = _MemoryMetricExporter();
    final reader = ManualMetricReader(metricExporter);
    final meterProvider = MeterProvider(readers: [reader]);
    String? tenant;
    final handler = const Pipeline()
        .addMiddleware(
          obsiMiddleware(
            tracer: provider.tracer,
            meter: meterProvider.getMeter('http.server'),
            routeResolver: (_) => '/users',
          ),
        )
        .addHandler((_) {
          tenant = Baggage.current.value('tenant');
          return Response.ok('ok');
        });

    final response = await handler(
      Request(
        'GET',
        Uri.parse('http://localhost/users'),
        headers: {
          'traceparent':
              '00-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-01',
          'baggage': 'tenant=acme',
        },
      ),
    );
    await response.read().drain<void>();
    await provider.forceFlush();
    await reader.collect();

    final span = exporter.spans.single;
    expect(response.statusCode, 200);
    expect(span.kind, SpanKind.server);
    expect(span.context.traceId, '0af7651916cd43dd8448eb211c80319c');
    expect(span.parentSpanId, 'b7ad6b7169203331');
    expect(span.name, 'GET /users');
    expect(tenant, 'acme');
    expect(
      metricExporter.metrics.single.name,
      SemanticMetrics.httpServerRequestDuration,
    );
    final point = metricExporter.metrics.single.points.single;
    expect(point.attributes[SemanticAttributes.httpRequestMethod], 'GET');
    expect(point.attributes[SemanticAttributes.urlScheme], 'http');
    expect(point.attributes[SemanticAttributes.httpRoute], '/users');
    expect(point.boundaries, SemanticMetrics.httpDurationBoundaries);
    await provider.shutdown();
    await meterProvider.shutdown();
  });

  test('keeps server spans open until the response body completes', () async {
    final exporter = _MemorySpanExporter();
    final provider = TracerProvider(processor: SimpleSpanProcessor(exporter));
    final body = StreamController<List<int>>();
    final handler = const Pipeline()
        .addMiddleware(obsiMiddleware(tracer: provider.tracer))
        .addHandler((_) => Response.ok(body.stream));

    final response = await handler(
      Request('GET', Uri.parse('http://localhost/stream')),
    );
    await provider.forceFlush();
    expect(exporter.spans, isEmpty);

    final drained = response.read().drain<void>();
    body.add([1, 2, 3]);
    await body.close();
    await drained;
    await provider.shutdown();

    expect(exporter.spans, hasLength(1));
  });

  test('uses HTTP server status semantics for 404 and 500', () async {
    final exporter = _MemorySpanExporter();
    final provider = TracerProvider(processor: SimpleSpanProcessor(exporter));
    final middleware = obsiMiddleware(tracer: provider.tracer);

    final notFound = await middleware((_) => Response.notFound('missing'))(
      Request('GET', Uri.parse('http://localhost/missing')),
    );
    await notFound.read().drain<void>();
    final failure = await middleware((_) => Response.internalServerError())(
      Request('GET', Uri.parse('http://localhost/failure')),
    );
    await failure.read().drain<void>();
    await provider.shutdown();

    expect(exporter.spans[0].status, SpanStatus.unset);
    expect(exporter.spans[0].attributes[SemanticAttributes.errorType], isNull);
    expect(exporter.spans[1].status, SpanStatus.error);
    expect(exporter.spans[1].attributes[SemanticAttributes.errorType], '500');
  });

  test('records handler exceptions and rethrows them unchanged', () async {
    final exporter = _MemorySpanExporter();
    final provider = TracerProvider(processor: SimpleSpanProcessor(exporter));
    final handler = obsiMiddleware(tracer: provider.tracer)(
      (_) => throw StateError('handler failed'),
    );

    await expectLater(
      handler(Request('GET', Uri.parse('http://localhost/failure'))),
      throwsStateError,
    );
    await provider.shutdown();

    final span = exporter.spans.single;
    expect(span.status, SpanStatus.error);
    expect(span.attributes[SemanticAttributes.errorType], 'StateError');
    expect(span.events, hasLength(1));
  });

  test('records response stream errors and closes exactly one span', () async {
    final exporter = _MemorySpanExporter();
    final provider = TracerProvider(processor: SimpleSpanProcessor(exporter));
    final body = StreamController<List<int>>();
    final handler = obsiMiddleware(tracer: provider.tracer)(
      (_) => Response.ok(body.stream),
    );
    final response = await handler(
      Request('GET', Uri.parse('http://localhost/stream')),
    );
    final drained = response.read().drain<void>();
    final stackTrace = StackTrace.current;

    body.addError(StateError('body failed'), stackTrace);
    await body.close();

    await expectLater(drained, throwsStateError);
    await provider.shutdown();
    final span = exporter.spans.single;
    expect(span.status, SpanStatus.error);
    expect(span.events, hasLength(1));
    expect(
      span.events.single.attributes['exception.stacktrace'],
      '$stackTrace',
    );
  });

  test('supports filtering without extracting or creating context', () async {
    final exporter = _MemorySpanExporter();
    final provider = TracerProvider(processor: SimpleSpanProcessor(exporter));
    final handler = obsiMiddleware(
      tracer: provider.tracer,
      options: const ObsiShelfOptions(shouldInstrument: _neverInstrument),
    )((_) => Response.ok('ok'));

    final response = await handler(
      Request('GET', Uri.parse('http://localhost/health')),
    );
    expect(await response.readAsString(), 'ok');
    await provider.shutdown();

    expect(exporter.spans, isEmpty);
  });

  test('isolates route and attribute callback failures', () async {
    final diagnostics = <Object>[];
    final exporter = _MemorySpanExporter();
    final provider = TracerProvider(processor: SimpleSpanProcessor(exporter));
    final handler = obsiMiddleware(
      tracer: provider.tracer,
      routeResolver: (_) => throw StateError('route'),
      options: ObsiShelfOptions(
        requestAttributes: (_) => const {'invalid': double.nan},
        responseAttributes: (_, _) => throw StateError('response'),
        onInstrumentationError: (error, _) => diagnostics.add(error),
      ),
    )((_) => Response.ok('ok'));

    final response = await handler(
      Request('GET', Uri.parse('http://localhost/users')),
    );
    await response.read().drain<void>();
    await provider.shutdown();

    expect(exporter.spans.single.name, 'GET');
    expect(diagnostics, hasLength(3));
  });

  test(
    'can end spans when the handler returns for non-streaming use',
    () async {
      final exporter = _MemorySpanExporter();
      final provider = TracerProvider(processor: SimpleSpanProcessor(exporter));
      final handler = obsiMiddleware(
        tracer: provider.tracer,
        options: const ObsiShelfOptions(traceResponseBody: false),
      )((_) => Response.ok('ok'));

      await handler(Request('GET', Uri.parse('http://localhost/fast')));
      await provider.shutdown();

      expect(exporter.spans, hasLength(1));
    },
  );

  test('propagator failures use root context and empty baggage', () async {
    final diagnostics = <Object>[];
    final exporter = _MemorySpanExporter();
    final provider = TracerProvider(processor: SimpleSpanProcessor(exporter));
    final handler =
        obsiMiddleware(
          tracer: provider.tracer,
          propagator: _ThrowingTracePropagator(),
          baggagePropagator: _ThrowingBaggagePropagator(),
          options: ObsiShelfOptions(
            onInstrumentationError: (error, _) => diagnostics.add(error),
          ),
        )((_) {
          expect(Baggage.current.entries, isEmpty);
          return Response.ok('ok');
        });

    final response = await handler(
      Request('GET', Uri.parse('http://localhost/users')),
    );
    await response.read().drain<void>();
    await provider.shutdown();

    expect(exporter.spans.single.parentSpanId, isNull);
    expect(diagnostics, hasLength(2));
  });
}

bool _neverInstrument(Request _) => false;

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

final class _ThrowingTracePropagator implements TracePropagator {
  @override
  SpanContext? extract(Map<String, String> carrier) {
    throw StateError('trace extraction failed');
  }

  @override
  void inject(SpanContext context, Map<String, String> carrier) {}
}

final class _ThrowingBaggagePropagator implements BaggagePropagator {
  @override
  Baggage extract(Map<String, String> carrier) {
    throw StateError('baggage extraction failed');
  }

  @override
  void inject(Baggage baggage, Map<String, String> carrier) {}
}
