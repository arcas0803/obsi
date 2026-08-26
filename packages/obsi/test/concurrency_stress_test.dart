import 'dart:async';

import 'package:obsi/obsi.dart';
import 'package:test/test.dart';

void main() {
  tearDown(() {
    Trace.disable();
    Errors.disable();
  });

  test('1000 concurrent child spans preserve exact parentage', () async {
    final exporter = _SpanExporter();
    final provider = TracerProvider(
      processor: SimpleSpanProcessor(exporter, maxPendingExports: 2048),
    );
    Trace.configure(provider);

    await Trace.tracer.trace('root', () async {
      await Future.wait([
        for (var index = 0; index < 1000; index++)
          Future<void>(() async {
            await Trace.tracer.trace('child-$index', () async {
              await Future<void>.delayed(Duration.zero);
            });
          }),
      ]);
    });
    await provider.shutdown();

    final root = exporter.spans.singleWhere((span) => span.name == 'root');
    final children = exporter.spans.where((span) => span.name != 'root');
    expect(children, hasLength(1000));
    expect(
      children.every(
        (span) =>
            span.context.traceId == root.context.traceId &&
            span.parentSpanId == root.context.spanId,
      ),
      isTrue,
    );
    expect(
      children.map((span) => span.context.spanId).toSet(),
      hasLength(1000),
    );
  });

  test('500 concurrent error scopes never leak tags or users', () async {
    final exporter = _ErrorExporter();
    final manager = ErrorManager(exporter: exporter, processors: const []);
    Errors.configure(manager);

    await Future.wait([
      for (var index = 0; index < 500; index++)
        Future<void>(() async {
          await Errors.withScope(
            () async {
              await Future<void>.delayed(Duration.zero);
              await Errors.captureException(StateError('error-$index'));
            },
            user: ErrorUser(id: 'user-$index'),
            tags: {'request': '$index'},
          );
        }),
    ]);
    await manager.shutdown();

    expect(exporter.reports, hasLength(500));
    for (final report in exporter.reports) {
      final index = report.message.substring('Bad state: error-'.length);
      expect(report.user?.id, 'user-$index');
      expect(report.tags['request'], index);
    }
  });

  test(
    'nested baggage remains isolated across 500 asynchronous branches',
    () async {
      final results = await Future.wait([
        for (var index = 0; index < 500; index++)
          Baggage.empty.set('branch', '$index').run(() async {
            await Future<void>.delayed(Duration.zero);
            return Baggage.current.value('branch');
          }),
      ]);

      expect(results, [for (var index = 0; index < 500; index++) '$index']);
      expect(Baggage.current.entries, isEmpty);
    },
  );

  test('100000 metric updates retain exact aggregate values', () {
    final provider = MeterProvider();
    final meter = provider.getMeter('stress');
    final counter = meter.createCounter<int>('count');
    final histogram = meter.createHistogram<int>(
      'distribution',
      boundaries: const [10, 100, 1000],
    );

    for (var index = 0; index < 100000; index++) {
      counter.add(1);
      histogram.record(index % 2000);
    }

    final metrics = provider.collect();
    expect(
      metrics
          .singleWhere((metric) => metric.name == 'count')
          .points
          .single
          .value,
      100000,
    );
    final point = metrics
        .singleWhere((metric) => metric.name == 'distribution')
        .points
        .single;
    expect(point.count, 100000);
    expect(point.bucketCounts.reduce((a, b) => a + b), 100000);
  });

  test('stream factory failures end exactly one error span', () async {
    final exporter = _SpanExporter();
    final provider = TracerProvider(processor: SimpleSpanProcessor(exporter));
    Trace.configure(provider);

    final stream = Trace.tracer.traceStream<int>(
      'stream',
      () => throw StateError('factory failed'),
    );
    await expectLater(stream.toList(), throwsStateError);
    await provider.shutdown();

    expect(exporter.spans, hasLength(1));
    expect(exporter.spans.single.status, SpanStatus.error);
    expect(exporter.spans.single.events, hasLength(1));
  });

  test('stream source errors preserve the supplied stack trace', () async {
    final exporter = _SpanExporter();
    final provider = TracerProvider(processor: SimpleSpanProcessor(exporter));
    Trace.configure(provider);
    final stackTrace = StackTrace.fromString('original-stack');
    final controller = StreamController<int>();
    final values = Trace.tracer.traceStream('stream', () => controller.stream);
    final completion = values.drain<void>();

    controller.addError(StateError('source failed'), stackTrace);
    await controller.close();
    await expectLater(completion, throwsStateError);
    await provider.shutdown();

    final event = exporter.spans.single.events.single;
    expect(
      event.attributes[SemanticAttributes.exceptionStacktrace],
      'original-stack',
    );
  });
}

final class _SpanExporter implements SpanExporter {
  final List<SpanData> spans = [];

  @override
  Future<void> export(List<SpanData> batch) async => spans.addAll(batch);

  @override
  Future<void> shutdown() async {}
}

final class _ErrorExporter implements ErrorExporter {
  final List<ErrorReport> reports = [];

  @override
  Future<void> export(ErrorReport report) async => reports.add(report);

  @override
  Future<void> forceFlush() async {}

  @override
  Future<void> shutdown() async {}
}
