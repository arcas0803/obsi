import 'dart:async';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:obsi/obsi.dart';
import 'package:obsi_instrumentation_dio/obsi_instrumentation_dio.dart';
import 'package:test/test.dart';

void main() {
  test(
    'traces, propagates context, redacts URLs, and records metrics',
    () async {
      final spans = _MemorySpanExporter();
      final traces = TracerProvider(processor: SimpleSpanProcessor(spans));
      final metrics = _MemoryMetricExporter();
      final reader = ManualMetricReader(metrics);
      final meters = MeterProvider(readers: [reader]);
      final dio = _dio((options, _, _) async {
        expect(options.headers['traceparent'], isNotNull);
        expect(options.headers['baggage'], 'tenant=acme');
        return ResponseBody.fromString('ok', 200);
      });
      dio.interceptors.add(
        ObsiDioInterceptor(
          tracer: traces.tracer,
          meter: meters.getMeter('dio'),
        ),
      );

      final response = await Baggage.empty
          .set('tenant', 'acme')
          .run(
            () => dio.get<String>(
              'https://user:secret@example.test/search?q=private#fragment',
            ),
          );
      await traces.forceFlush();
      await reader.collect();

      expect(response.data, 'ok');
      final span = spans.spans.single;
      expect(span.kind, SpanKind.client);
      expect(span.attributes[SemanticAttributes.httpRequestMethod], 'GET');
      expect(span.attributes[SemanticAttributes.httpResponseStatusCode], 200);
      expect(span.attributes[SemanticAttributes.urlFull], contains('redacted'));
      expect(
        span.attributes[SemanticAttributes.urlFull],
        isNot(contains('secret')),
      );
      expect(
        metrics.metrics.single.name,
        SemanticMetrics.httpClientRequestDuration,
      );
      expect(
        metrics.metrics.single.points.single.attributes['http.request.method'],
        'GET',
      );
      expect(
        metrics.metrics.single.points.single.attributes['server.address'],
        'example.test',
      );
      expect(
        metrics.metrics.single.points.single.attributes['server.port'],
        443,
      );
      expect(
        metrics.metrics.single.points.single.boundaries,
        SemanticMetrics.httpDurationBoundaries,
      );
      await traces.shutdown();
      await meters.shutdown();
    },
  );

  test(
    'marks HTTP and transport failures while preserving Dio errors',
    () async {
      final spans = _MemorySpanExporter();
      final traces = TracerProvider(processor: SimpleSpanProcessor(spans));
      var calls = 0;
      final dio = _dio((options, _, _) async {
        calls++;
        if (calls == 1) return ResponseBody.fromString('missing', 404);
        throw StateError('offline');
      });
      dio.interceptors.add(ObsiDioInterceptor(tracer: traces.tracer));

      await expectLater(
        dio.get<void>('https://example.test/missing'),
        throwsA(isA<DioException>()),
      );
      await expectLater(
        dio.get<void>('https://example.test/offline'),
        throwsA(isA<DioException>()),
      );
      await traces.shutdown();

      expect(spans.spans, hasLength(2));
      expect(spans.spans.first.status, SpanStatus.error);
      expect(spans.spans.first.attributes[SemanticAttributes.errorType], '404');
      expect(spans.spans.last.status, SpanStatus.error);
      expect(
        spans.spans.last.attributes[SemanticAttributes.errorType],
        'StateError',
      );
      expect(
        spans.spans.last.attributes[ObsiDioAttributes.errorType],
        'unknown',
      );
    },
  );

  test('intentional cancellation ends the span without error status', () async {
    final spans = _MemorySpanExporter();
    final traces = TracerProvider(processor: SimpleSpanProcessor(spans));
    final token = CancelToken();
    final started = Completer<void>();
    final dio = _dio((_, _, cancelFuture) async {
      started.complete();
      await cancelFuture;
      return ResponseBody.fromString('', 200);
    });
    dio.interceptors.add(ObsiDioInterceptor(tracer: traces.tracer));

    final request = dio.get<void>('https://example.test', cancelToken: token);
    await started.future;
    token.cancel('user left');
    await expectLater(
      request,
      throwsA(
        isA<DioException>().having(
          (e) => e.type,
          'type',
          DioExceptionType.cancel,
        ),
      ),
    );
    await traces.shutdown();

    expect(spans.spans.single.status, SpanStatus.unset);
    expect(spans.spans.single.events, isEmpty);
  });

  test(
    'keeps streaming spans open until completion and records body errors',
    () async {
      final spans = _MemorySpanExporter();
      final traces = TracerProvider(processor: SimpleSpanProcessor(spans));
      final controller = StreamController<Uint8List>();
      final dio = _dio((_, _, _) async => ResponseBody(controller.stream, 200));
      dio.interceptors.add(ObsiDioInterceptor(tracer: traces.tracer));

      final response = await dio.get<ResponseBody>(
        'https://example.test/stream',
        options: Options(responseType: ResponseType.stream),
      );
      await traces.forceFlush();
      expect(spans.spans, isEmpty);
      final drained = response.data!.stream.drain<void>();
      final stack = StackTrace.current;
      controller
        ..add(Uint8List.fromList([1, 2]))
        ..addError(StateError('stream failed'), stack)
        ..close();
      await expectLater(drained, throwsStateError);
      await traces.shutdown();

      final span = spans.spans.single;
      expect(span.status, SpanStatus.error);
      expect(
        span.events.single.attributes[SemanticAttributes.exceptionStacktrace],
        '$stack',
      );
    },
  );

  test('finishes a streaming span when the consumer cancels', () async {
    final spans = _MemorySpanExporter();
    final traces = TracerProvider(processor: SimpleSpanProcessor(spans));
    final controller = StreamController<Uint8List>();
    final dio = _dio((_, _, _) async => ResponseBody(controller.stream, 200));
    dio.interceptors.add(ObsiDioInterceptor(tracer: traces.tracer));

    final response = await dio.get<ResponseBody>(
      'https://example.test/stream',
      options: Options(responseType: ResponseType.stream),
    );
    final subscription = response.data!.stream.listen((_) {});
    await subscription.cancel();
    await traces.shutdown();

    expect(spans.spans, hasLength(1));
    expect(spans.spans.single.status, SpanStatus.unset);
    await controller.close();
  });

  test('finishes a successful stream on body completion', () async {
    final spans = _MemorySpanExporter();
    final traces = TracerProvider(processor: SimpleSpanProcessor(spans));
    final dio = _dio(
      (_, _, _) async =>
          ResponseBody(Stream.value(Uint8List.fromList([1, 2, 3])), 200),
    );
    dio.interceptors.add(ObsiDioInterceptor(tracer: traces.tracer));

    final response = await dio.get<ResponseBody>(
      'https://example.test/stream',
      options: Options(responseType: ResponseType.stream),
    );
    expect(await response.data!.stream.expand((bytes) => bytes).toList(), [
      1,
      2,
      3,
    ]);
    await traces.shutdown();

    expect(spans.spans.single.status, SpanStatus.unset);
  });

  test('can end streaming spans when response headers arrive', () async {
    final spans = _MemorySpanExporter();
    final traces = TracerProvider(processor: SimpleSpanProcessor(spans));
    final controller = StreamController<Uint8List>();
    final dio = _dio((_, _, _) async => ResponseBody(controller.stream, 200));
    dio.interceptors.add(
      ObsiDioInterceptor(
        tracer: traces.tracer,
        options: const ObsiDioOptions(traceResponseBody: false),
      ),
    );

    await dio.get<ResponseBody>(
      'https://example.test/stream',
      options: Options(responseType: ResponseType.stream),
    );
    await traces.shutdown();

    expect(spans.spans, hasLength(1));
    await controller.close();
  });

  test(
    'filtering skips propagation and duplicate interceptors emit once',
    () async {
      final spans = _MemorySpanExporter();
      final traces = TracerProvider(processor: SimpleSpanProcessor(spans));
      var call = 0;
      final dio = _dio((options, _, _) async {
        call++;
        if (call == 1) expect(options.headers['traceparent'], isNull);
        return ResponseBody.fromString('', 200);
      });
      dio.interceptors.add(
        ObsiDioInterceptor(
          tracer: traces.tracer,
          options: ObsiDioOptions(shouldInstrument: (_) => call != 0),
        ),
      );

      await dio.get<void>('https://collector.test/v1/traces');
      dio.interceptors.add(ObsiDioInterceptor(tracer: traces.tracer));
      await dio.get<void>('https://example.test');
      await traces.shutdown();

      expect(spans.spans, hasLength(1));
    },
  );

  test('a reused RequestOptions creates a new span per attempt', () async {
    final spans = _MemorySpanExporter();
    final traces = TracerProvider(processor: SimpleSpanProcessor(spans));
    final dio = _dio((_, _, _) async => ResponseBody.fromString('', 200));
    dio.interceptors.add(ObsiDioInterceptor(tracer: traces.tracer));
    final request = RequestOptions(path: 'https://example.test', method: 'GET');

    await dio.fetch<void>(request);
    await dio.fetch<void>(request);
    await traces.shutdown();

    expect(spans.spans, hasLength(2));
    expect(
      spans.spans.map((span) => span.context.spanId).toSet(),
      hasLength(2),
    );
  });

  test('preserves concurrency and creates independent request spans', () async {
    final spans = _MemorySpanExporter();
    final traces = TracerProvider(processor: SimpleSpanProcessor(spans));
    final dio = _dio((options, _, _) async {
      await Future<void>.delayed(Duration(milliseconds: options.uri.port % 3));
      return ResponseBody.fromString('', 200);
    });
    dio.interceptors.add(ObsiDioInterceptor(tracer: traces.tracer));

    await Future.wait([
      for (var index = 8000; index < 8050; index++)
        dio.get<void>('https://example.test:$index/resource'),
    ]);
    await traces.shutdown();

    expect(spans.spans, hasLength(50));
    expect(
      spans.spans.map((span) => span.context.spanId).toSet(),
      hasLength(50),
    );
  });

  test('callback and propagator failures are isolated from traffic', () async {
    final diagnostics = <Object>[];
    final spans = _MemorySpanExporter();
    final traces = TracerProvider(processor: SimpleSpanProcessor(spans));
    final dio = _dio((_, _, _) async => ResponseBody.fromString('ok', 200));
    dio.interceptors.add(
      ObsiDioInterceptor(
        tracer: traces.tracer,
        propagator: _ThrowingTracePropagator(),
        baggagePropagator: _ThrowingBaggagePropagator(),
        options: ObsiDioOptions(
          spanNameBuilder: (_) => throw StateError('name'),
          requestAttributes: (_) => const {'invalid': double.nan},
          responseAttributes: (_) => throw StateError('response'),
          urlSanitizer: (_) => throw StateError('url'),
          onInstrumentationError: (error, _) => diagnostics.add(error),
        ),
      ),
    );

    final response = await dio.get<String>('https://example.test?q=secret');
    await traces.shutdown();

    expect(response.data, 'ok');
    expect(spans.spans.single.name, 'GET');
    expect(diagnostics, hasLength(6));
  });
}

Dio _dio(
  Future<ResponseBody> Function(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  )
  fetch,
) {
  final dio = Dio();
  dio.httpClientAdapter = _CallbackAdapter(fetch);
  return dio;
}

final class _CallbackAdapter implements HttpClientAdapter {
  _CallbackAdapter(this.callback);

  final Future<ResponseBody> Function(
    RequestOptions,
    Stream<Uint8List>?,
    Future<void>?,
  )
  callback;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) => callback(options, requestStream, cancelFuture);

  @override
  void close({bool force = false}) {}
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
