import 'dart:async';
import 'dart:math';

import 'package:obsi/obsi.dart';
import 'package:test/test.dart';

void main() {
  late _MemoryExporter exporter;
  late TracerProvider provider;

  setUp(() {
    exporter = _MemoryExporter();
    provider = TracerProvider(processor: SimpleSpanProcessor(exporter));
    Trace.configure(provider);
  });

  tearDown(() async {
    await provider.shutdown();
    Trace.disable();
  });

  test('creates a valid root span', () async {
    await Trace.tracer.trace('root', () async {});
    await provider.forceFlush();

    final span = exporter.single('root');
    expect(span.context.isValid, isTrue);
    expect(span.parentSpanId, isNull);
    expect(span.status, SpanStatus.ok);
  });

  test('preserves parentage across concurrent futures', () async {
    await Trace.tracer.trace('root', () async {
      await Future.wait([
        Trace.tracer.trace('first', () async {
          await Future<void>.delayed(const Duration(milliseconds: 2));
        }),
        Trace.tracer.trace('second', () async {
          await Future<void>.delayed(const Duration(milliseconds: 1));
        }),
        Trace.tracer.trace('third', () async {}),
      ]);
    });
    await provider.forceFlush();

    final root = exporter.single('root');
    for (final name in ['first', 'second', 'third']) {
      final child = exporter.single(name);
      expect(child.context.traceId, root.context.traceId);
      expect(child.parentSpanId, root.context.spanId);
    }
  });

  test('records exceptions and rethrows them', () async {
    await expectLater(
      Trace.tracer.trace<void>('failure', () => throw StateError('broken')),
      throwsStateError,
    );
    await provider.forceFlush();

    final span = exporter.single('failure');
    expect(span.status, SpanStatus.error);
    expect(span.statusDescription, contains('broken'));
    expect(span.events.single.name, 'exception');
  });

  test(
    'automatic success does not overwrite an explicit error status',
    () async {
      await Trace.tracer.trace('manual-error', () async {
        Trace.tracer.currentSpan!.setStatus(
          SpanStatus.error,
          description: 'validation failed',
        );
      });
      await provider.forceFlush();

      final span = exporter.single('manual-error');
      expect(span.status, SpanStatus.error);
      expect(span.statusDescription, 'validation failed');
    },
  );

  test('stream is lazy and ends when its subscription completes', () async {
    var factoryCalls = 0;
    final stream = Trace.tracer.traceStream('numbers', () {
      factoryCalls++;
      return Stream.fromIterable([1, 2, 3]);
    });

    expect(factoryCalls, 0);
    expect(exporter.spans, isEmpty);
    expect(await stream.toList(), [1, 2, 3]);
    await provider.forceFlush();

    expect(factoryCalls, 1);
    expect(exporter.single('numbers').status, SpanStatus.ok);
  });

  test('each stream subscription owns a separate span', () async {
    final stream = Trace.tracer.traceStream(
      'subscription',
      () => Stream.value(1),
      isBroadcast: true,
    );

    await Future.wait([stream.toList(), stream.toList()]);
    await provider.forceFlush();

    final spans = exporter.named('subscription');
    expect(spans, hasLength(2));
    expect(spans[0].context.spanId, isNot(spans[1].context.spanId));
  });

  test('stream span ends on cancellation', () async {
    final source = StreamController<int>();
    final stream = Trace.tracer.traceStream('cancelled', () => source.stream);
    final subscription = stream.listen((_) {});

    await subscription.cancel();
    await provider.forceFlush();

    expect(exporter.single('cancelled').status, SpanStatus.ok);
    await source.close();
  });

  test('sampling off propagates context without exporting', () async {
    await provider.shutdown();
    exporter = _MemoryExporter();
    provider = TracerProvider(
      processor: SimpleSpanProcessor(exporter),
      sampler: const AlwaysOffSampler(),
    );
    Trace.configure(provider);

    await Trace.tracer.trace('not-recorded', () async {
      expect(Trace.tracer.currentSpan, isNotNull);
      expect(Trace.tracer.currentSpan!.context.sampled, isFalse);
    });
    await provider.forceFlush();

    expect(exporter.spans, isEmpty);
  });

  test('global no-op tracer executes callbacks while disabled', () async {
    Trace.disable();
    expect(Trace.tracer.traceSync('sync', () => 7), 7);
    expect(await Trace.tracer.trace('async', () async => 8), 8);
    expect(
      await Trace.tracer
          .traceStream('stream', () => Stream.fromIterable([9, 10]))
          .toList(),
      [9, 10],
    );
  });

  test('injects and extracts W3C trace context', () {
    const propagator = W3CTraceContextPropagator();
    const original = SpanContext(
      traceId: '0af7651916cd43dd8448eb211c80319c',
      spanId: 'b7ad6b7169203331',
      sampled: true,
      traceState: 'vendor=value',
    );
    final carrier = <String, String>{};

    propagator.inject(original, carrier);
    final extracted = propagator.extract(carrier);

    expect(
      carrier['traceparent'],
      '00-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-01',
    );
    expect(extracted?.traceId, original.traceId);
    expect(extracted?.spanId, original.spanId);
    expect(extracted?.sampled, isTrue);
    expect(extracted?.traceState, 'vendor=value');
    expect(extracted?.isRemote, isTrue);
  });

  test('continues a remote W3C trace', () async {
    const remote = SpanContext(
      traceId: '0af7651916cd43dd8448eb211c80319c',
      spanId: 'b7ad6b7169203331',
      sampled: true,
      isRemote: true,
    );

    final span = Trace.tracer.startSpan('server', parent: remote);
    span.end();
    await provider.forceFlush();

    final data = exporter.single('server');
    expect(data.context.traceId, remote.traceId);
    expect(data.parentSpanId, remote.spanId);
  });

  test('rejects malformed W3C trace context', () {
    const propagator = W3CTraceContextPropagator();

    expect(
      propagator.extract({
        'TraceParent':
            '00-00000000000000000000000000000000-b7ad6b7169203331-01',
      }),
      isNull,
    );
    expect(propagator.extract({'traceparent': 'not-valid'}), isNull);
    expect(
      propagator.extract({
        'traceparent':
            '00-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-01-extra',
      }),
      isNull,
    );
  });

  test('correlates structured logs with the active span', () async {
    final logExporter = _MemoryLogExporter();
    final logProvider = LoggerProvider(
      processor: SimpleLogProcessor(logExporter),
      resource: Resource({'service.name': 'test'}),
    );
    final logger = logProvider.getLogger('test.logger');

    await Trace.tracer.trace('request', () async {
      logger.info('processing', attributes: {'item.count': 2});
    });
    await logProvider.shutdown();

    final record = logExporter.records.single;
    final span = exporter.single('request');
    expect(record.spanContext?.traceId, span.context.traceId);
    expect(record.spanContext?.spanId, span.context.spanId);
    expect(record.attributes['item.count'], 2);
  });

  test('collects counters, gauges, and histograms', () async {
    final metricExporter = _MemoryMetricExporter();
    final reader = ManualMetricReader(metricExporter);
    final meterProvider = MeterProvider(readers: [reader]);
    final meter = meterProvider.getMeter('test.metrics');
    final counter = meter.createCounter<int>('requests');
    final gauge = meter.createGauge<double>('temperature');
    final histogram = meter.createHistogram<double>(
      'duration',
      boundaries: [10, 100],
    );

    counter
      ..add(2, attributes: {'route': '/users'})
      ..add(3, attributes: {'route': '/users'});
    gauge.record(21.5);
    histogram
      ..record(5)
      ..record(50)
      ..record(500);
    await reader.collect();

    final counterData = metricExporter.single('requests');
    final histogramData = metricExporter.single('duration');
    expect(counterData.points.single.value, 5);
    expect(histogramData.points.single.count, 3);
    expect(histogramData.points.single.bucketCounts, [1, 1, 1]);
    await meterProvider.shutdown();
  });

  test('attaches resource and instrumentation scope to spans', () async {
    await provider.shutdown();
    exporter = _MemoryExporter();
    provider = TracerProvider(
      processor: SimpleSpanProcessor(exporter),
      resource: Resource({'service.name': 'checkout'}),
    );
    final scopedTracer = provider.getTracer(
      'package:checkout',
      version: '1.2.0',
    );

    await scopedTracer.trace('operation', () async {});
    await provider.forceFlush();

    final span = exporter.single('operation');
    expect(span.resource.attributes['service.name'], 'checkout');
    expect(span.instrumentationScope.name, 'package:checkout');
    expect(span.instrumentationScope.version, '1.2.0');
  });

  test('enforces span limits and reports dropped data', () async {
    await provider.shutdown();
    exporter = _MemoryExporter();
    provider = TracerProvider(
      processor: SimpleSpanProcessor(exporter),
      spanLimits: const SpanLimits(
        attributeCountLimit: 1,
        eventCountLimit: 1,
        linkCountLimit: 1,
      ),
    );
    Trace.configure(provider);

    await Trace.tracer.trace(
      'limited',
      attributes: {'first': 1, 'second': 2},
      () async {
        final span = Trace.tracer.currentSpan!;
        span
          ..addEvent('first')
          ..addEvent('second');
      },
    );
    await provider.forceFlush();

    final span = exporter.single('limited');
    expect(span.attributes, hasLength(1));
    expect(span.droppedAttributes, 1);
    expect(span.droppedEvents, 1);
  });

  test('keeps immutable baggage across asynchronous Zone work', () async {
    final baggage = Baggage.empty
        .set('tenant.id', 'acme')
        .set('region', 'eu', metadata: 'source=edge');

    await baggage.run(() async {
      await Future<void>.delayed(Duration.zero);
      expect(Baggage.current.value('tenant.id'), 'acme');
      expect(Baggage.current['region']?.metadata, 'source=edge');
    });

    expect(Baggage.current.entries, isEmpty);
    expect(baggage.remove('tenant.id').value('tenant.id'), isNull);
    expect(baggage.value('tenant.id'), 'acme');
  });

  test('round-trips W3C baggage and ignores malformed members', () {
    const propagator = W3CBaggagePropagator();
    final original = Baggage.empty
        .set('tenant', 'A B')
        .set('region', 'eu', metadata: 'source=edge');
    final carrier = <String, String>{};

    propagator.inject(original, carrier);
    final extracted = propagator.extract({
      'Baggage': '${carrier['baggage']},broken,bad key=value,tenant=ignored',
    });

    expect(extracted.value('tenant'), 'A B');
    expect(extracted.value('region'), 'eu');
    expect(extracted['region']?.metadata, 'source=edge');
    expect(extracted.entries, hasLength(2));
  });

  test('observable metrics run once per collection cycle', () async {
    final metricExporter = _MemoryMetricExporter();
    final reader = ManualMetricReader(metricExporter);
    final meterProvider = MeterProvider(readers: [reader]);
    final meter = meterProvider.getMeter('observable.metrics');
    var callbackCount = 0;
    var currentValue = 10;
    meter.createObservableGauge<int>('queue.depth', () {
      callbackCount++;
      return [
        Observation(currentValue, attributes: const {'queue': 'main'}),
      ];
    });

    await reader.collect();
    currentValue = 4;
    await reader.collect();

    final values = metricExporter.metrics
        .where((metric) => metric.name == 'queue.depth')
        .map((metric) => metric.points.single.value)
        .toList();
    expect(callbackCount, 2);
    expect(values, [10, 4]);
    await meterProvider.shutdown();
  });

  test('W3C propagators never throw for arbitrary input', () {
    final random = Random(42);
    const trace = W3CTraceContextPropagator();
    const baggage = W3CBaggagePropagator();

    for (var sample = 0; sample < 1000; sample++) {
      final value = String.fromCharCodes(
        List.generate(random.nextInt(160), (_) => random.nextInt(128)),
      );
      expect(() => trace.extract({'traceparent': value}), returnsNormally);
      expect(() => baggage.extract({'baggage': value}), returnsNormally);
    }
  });
}

final class _MemoryExporter implements SpanExporter {
  final List<SpanData> spans = [];

  @override
  Future<void> export(List<SpanData> batch) async => spans.addAll(batch);

  @override
  Future<void> shutdown() async {}

  SpanData single(String name) => named(name).single;

  List<SpanData> named(String name) =>
      spans.where((span) => span.name == name).toList();
}

final class _MemoryLogExporter implements LogExporter {
  final List<LogRecord> records = [];

  @override
  Future<void> export(List<LogRecord> batch) async => records.addAll(batch);
  @override
  Future<void> shutdown() async {}
}

final class _MemoryMetricExporter implements MetricExporter {
  final List<MetricData> metrics = [];

  @override
  Future<void> export(List<MetricData> batch) async => metrics.addAll(batch);
  @override
  Future<void> shutdown() async {}

  MetricData single(String name) =>
      metrics.where((metric) => metric.name == name).single;
}
