import 'dart:async';

import 'package:obsi/obsi.dart';
import 'package:test/test.dart';

void main() {
  group('immutable data contracts', () {
    test('attribute collections are snapshotted deeply enough for export', () {
      final values = <Object?>['one', 'two'];
      final resource = Resource({'values': values});
      values[0] = 'changed';

      expect(resource.attributes['values'], ['one', 'two']);
      expect(
        () => (resource.attributes['values']! as List<Object?>).add('three'),
        throwsUnsupportedError,
      );
    });

    test('non-finite attributes are rejected', () {
      for (final value in [
        double.nan,
        double.infinity,
        double.negativeInfinity,
      ]) {
        expect(() => Resource({'value': value}), throwsArgumentError);
      }
      expect(() => Resource({'value': null}), throwsArgumentError);
      expect(
        () => Resource({
          'value': <Object?>[1, 2.0],
        }),
        throwsArgumentError,
      );
    });

    test('error contexts are recursively immutable snapshots', () {
      final nested = <String, Object?>{
        'request': <String, Object?>{
          'headers': <Object?>['one'],
        },
      };
      final report = _report(contexts: {'data': nested});
      (nested['request']! as Map<String, Object?>)['changed'] = true;

      final captured = report.contexts['data']!['request']! as Map;
      expect(captured.containsKey('changed'), isFalse);
      expect(() => captured['new'] = true, throwsUnsupportedError);
      expect(
        () => (captured['headers']! as List<Object?>).add('two'),
        throwsUnsupportedError,
      );
    });

    test('cyclic structured error data is rejected', () {
      final cyclic = <String, Object?>{};
      cyclic['self'] = cyclic;
      expect(() => ErrorUser(id: 'one', data: cyclic), throwsArgumentError);
    });

    test('unsupported structured error values are rejected', () {
      expect(
        () => ErrorUser(id: 'one', data: {'date': DateTime.utc(2026)}),
        throwsArgumentError,
      );
      expect(
        () => ErrorUser(id: 'one', data: {'value': double.nan}),
        throwsArgumentError,
      );
    });

    test('attachments validate filename, content type and bytes', () {
      expect(
        () => ErrorAttachment(filename: '', bytes: const []),
        throwsArgumentError,
      );
      expect(
        () => ErrorAttachment(filename: 'a', bytes: const [-1]),
        throwsArgumentError,
      );
      expect(
        () => ErrorAttachment(filename: 'a', bytes: const [], contentType: ''),
        throwsArgumentError,
      );
    });

    test('span contexts have value equality', () {
      const first = SpanContext(
        traceId: '11111111111111111111111111111111',
        spanId: '2222222222222222',
        sampled: true,
      );
      const second = SpanContext(
        traceId: '11111111111111111111111111111111',
        spanId: '2222222222222222',
        sampled: true,
      );
      expect(first, second);
      expect(first.hashCode, second.hashCode);
    });

    test('default resources identify the Obsi Dart SDK', () {
      expect(
        Resource.defaultResource.attributes,
        containsPair('service.name', 'unknown_service:dart'),
      );
      expect(
        Resource.defaultResource.attributes,
        containsPair('telemetry.sdk.name', 'obsi'),
      );
      expect(
        Resource.defaultResource.attributes,
        containsPair('telemetry.sdk.language', 'dart'),
      );
      expect(
        Resource.defaultResource.attributes,
        containsPair('telemetry.sdk.version', '1.0.0'),
      );
    });

    test('sensitive redaction is case-insensitive and immutable', () {
      final redacted = SensitiveAttributeRedactor()({
        'http.request.header.Authorization': 'Bearer secret',
        'user.email': 'person@example.com',
        'safe': 'visible',
      });

      expect(redacted['http.request.header.Authorization'], '[Filtered]');
      expect(redacted['user.email'], '[Filtered]');
      expect(redacted['safe'], 'visible');
      expect(() => redacted['safe'] = 'changed', throwsUnsupportedError);
    });
  });

  group('tracing contracts', () {
    test('composite propagation injects all and extracts the first match', () {
      final first = _TestPropagator('first');
      final second = _TestPropagator(
        'second',
        extracted: const SpanContext(
          traceId: '11111111111111111111111111111111',
          spanId: '2222222222222222',
          sampled: true,
        ),
      );
      final carrier = <String, String>{};
      final composite = CompositeTracePropagator([first, second]);

      composite.inject(second.extracted!, carrier);

      expect(carrier, {'first': 'injected', 'second': 'injected'});
      expect(composite.extract(carrier), second.extracted);
      expect(first.extractCalls, 1);
      expect(second.extractCalls, 1);
    });

    test('negative span limits fail during provider construction', () {
      expect(
        () => TracerProvider(
          processor: _MemorySpanProcessor(),
          spanLimits: const SpanLimits(eventCountLimit: -1),
        ),
        throwsArgumentError,
      );
    });

    test(
      'invalid custom IDs fall back to valid IDs and report diagnostics',
      () {
        final errors = <Object>[];
        final processor = _MemorySpanProcessor();
        final provider = TracerProvider(
          processor: processor,
          idGenerator: _InvalidIdGenerator(),
          onInternalError: (error, _) => errors.add(error),
        );

        final span = provider.tracer.startSpan('valid');
        span.end();

        expect(span.context.isValid, isTrue);
        expect(errors, hasLength(2));
      },
    );

    test('invalid explicit parent starts a new valid root', () {
      final processor = _MemorySpanProcessor();
      final provider = TracerProvider(processor: processor);
      const invalidParent = SpanContext(
        traceId: '0',
        spanId: '0',
        sampled: true,
      );

      provider.tracer.startSpan('root', parent: invalidParent).end();

      final span = processor.ended.single;
      expect(span.context.isValid, isTrue);
      expect(span.parentSpanId, isNull);
    });

    test(
      'sampler and processor failures do not break application callbacks',
      () {
        final errors = <Object>[];
        final provider = TracerProvider(
          processor: _ThrowingSpanProcessor(),
          sampler: _ThrowingSampler(),
          onInternalError: (error, _) => errors.add(error),
        );

        final result = provider.tracer.traceSync('operation', () => 42);

        expect(result, 42);
        expect(errors, hasLength(1));
      },
    );

    test('processor end failures are isolated', () {
      final errors = <Object>[];
      final provider = TracerProvider(
        processor: _ThrowOnEndProcessor(),
        onInternalError: (error, _) => errors.add(error),
      );

      expect(provider.tracer.traceSync('operation', () => 42), 42);
      expect(errors, hasLength(1));
    });

    test('sampling supports ratio validation and record-only spans', () {
      expect(() => TraceIdRatioBasedSampler(-0.1), throwsArgumentError);
      expect(() => TraceIdRatioBasedSampler(1.1), throwsArgumentError);
      final processor = _MemorySpanProcessor();
      final provider = TracerProvider(
        processor: processor,
        sampler: _RecordOnlySampler(),
      );

      final span = provider.tracer.startSpan(
        'recorded',
        kind: SpanKind.client,
        attributes: const {'request.type': 'test'},
      );
      span.end();

      expect(span.context.sampled, isFalse);
      expect(processor.ended.single.attributes['sampling.rule'], 'record-only');
      expect(processor.ended.single.context.traceState, 'obsi=record-only');
    });

    test('empty span and event names are rejected', () {
      final provider = TracerProvider(processor: _MemorySpanProcessor());
      expect(() => provider.tracer.startSpan(''), throwsArgumentError);
      final span = provider.tracer.startSpan('valid');
      expect(() => span.addEvent(''), throwsArgumentError);
      span.end();
    });

    test('invalid links are counted as dropped', () {
      final processor = _MemorySpanProcessor();
      final provider = TracerProvider(processor: processor);
      const invalid = SpanContext(traceId: '0', spanId: '0', sampled: true);
      final span = provider.tracer.startSpan(
        'operation',
        links: [SpanLink(invalid)],
      );
      span.addLink(invalid);
      span.end();

      expect(processor.ended.single.links, isEmpty);
      expect(processor.ended.single.droppedLinks, 2);
    });
  });

  group('metric contracts', () {
    test('cardinality is bounded and dropped measurements are observable', () {
      final provider = MeterProvider(cardinalityLimit: 2);
      final counter = provider.getMeter('test').createCounter<int>('requests');

      for (var index = 0; index < 10; index++) {
        counter.add(1, attributes: {'route': '$index'});
      }

      expect(provider.collect().single.points, hasLength(2));
      expect(provider.droppedMeasurements, 8);
    });

    test('histogram boundaries are sorted and duplicates are rejected', () {
      final provider = MeterProvider();
      final meter = provider.getMeter('test');
      final histogram = meter.createHistogram<int>(
        'latency',
        boundaries: const [100, 0, 10],
      );
      histogram.record(5);
      expect(provider.collect().single.points.single.boundaries, [0, 10, 100]);
      expect(
        () => meter.createHistogram<int>('invalid', boundaries: const [1, 1]),
        throwsArgumentError,
      );
    });

    test('compatible instruments are reused and conflicts fail fast', () {
      final provider = MeterProvider();
      final firstMeter = provider.getMeter(
        'test',
        attributes: const {'b': 2, 'a': 1},
      );
      final secondMeter = provider.getMeter(
        'test',
        attributes: const {'a': 1, 'b': 2},
      );
      final first = firstMeter.createCounter<int>('requests', unit: '1');
      final second = secondMeter.createCounter<int>('requests', unit: '1');

      expect(identical(first, second), isTrue);
      first.add(1);
      second.add(2);
      expect(provider.collect().single.points.single.value, 3);
      expect(
        () => firstMeter.createCounter<int>('requests', unit: 'items'),
        throwsStateError,
      );
      expect(
        () => firstMeter.createHistogram<int>(
          'duration',
          boundaries: const [1, 2],
        ),
        returnsNormally,
      );
      expect(
        () => firstMeter.createHistogram<int>(
          'duration',
          boundaries: const [1, 3],
        ),
        throwsStateError,
      );
    });

    test('non-finite measurements are rejected', () {
      final meter = MeterProvider().getMeter('test');
      expect(
        () => meter.createGauge<double>('gauge').record(double.nan),
        throwsArgumentError,
      );
      expect(
        () =>
            meter.createHistogram<double>('histogram').record(double.infinity),
        throwsArgumentError,
      );
    });

    test('observable callback failures are reported and isolated', () {
      final errors = <Object>[];
      final provider = MeterProvider(
        onInternalError: (error, _) => errors.add(error),
      );
      final meter = provider.getMeter('test');
      meter.createObservableGauge<int>('broken', () => throw StateError('bad'));
      meter.createGauge<int>('healthy').record(7);

      final metrics = provider.collect();

      expect(metrics.map((metric) => metric.name), ['healthy']);
      expect(errors.single, isA<StateError>());
    });

    test('instruments become no-ops after shutdown', () async {
      final provider = MeterProvider();
      final counter = provider.getMeter('test').createCounter<int>('requests');
      counter.add(1);
      await provider.shutdown();
      counter.add(10);

      expect(provider.collect().single.points.single.value, 1);
      expect(() => provider.getMeter('later'), throwsStateError);
    });

    test('metric views override histogram buckets and cardinality', () {
      final provider = MeterProvider(
        views: const [
          MetricView(
            instrumentName: 'latency',
            histogramBoundaries: [0.1, 0.5],
            cardinalityLimit: 1,
          ),
        ],
      );
      final histogram = provider
          .getMeter('test')
          .createHistogram<double>('latency');

      histogram
        ..record(0.2, attributes: const {'route': 'one'})
        ..record(0.7, attributes: const {'route': 'two'});

      final metric = provider.collect().single;
      expect(metric.points.single.boundaries, [0.1, 0.5]);
      expect(metric.temporality, AggregationTemporality.cumulative);
      expect(metric.points.single.startTime, provider.startTime);
      expect(provider.droppedMeasurements, 1);
    });
  });

  group('error manager contracts', () {
    test('beforeSend can transform and discard reports', () async {
      final exporter = _MemoryErrorExporter();
      final manager = ErrorManager(
        exporter: exporter,
        processors: [
          ErrorBeforeSendProcessor((report) {
            if (report.message.contains('drop')) return null;
            return report.copyWith(tags: {'processed': 'true'});
          }),
        ],
      );

      final accepted = await manager.captureException(StateError('keep'));
      final dropped = await manager.captureException(StateError('drop'));

      expect(accepted, isNotNull);
      expect(dropped, isNull);
      expect(exporter.reports.single.tags['processed'], 'true');
      expect(manager.acceptedReports, 1);
      expect(manager.droppedReports, 1);
    });

    test('beforeSend can explicitly clear sensitive optional fields', () {
      final original = _report().copyWith(
        reason: 'private',
        user: ErrorUser(id: 'user'),
        stackTrace: StackTrace.current,
        spanContext: const SpanContext(
          traceId: '11111111111111111111111111111111',
          spanId: '2222222222222222',
          sampled: true,
        ),
      );

      final cleared = original.copyWith(
        clearReason: true,
        clearUser: true,
        clearStackTrace: true,
        clearSpanContext: true,
      );

      expect(cleared.reason, isNull);
      expect(cleared.user, isNull);
      expect(cleared.stackTrace, isNull);
      expect(cleared.spanContext, isNull);
    });

    test(
      'fatal errors bypass sampling, deduplication, and rate limiting',
      () async {
        final exporter = _MemoryErrorExporter();
        final manager = ErrorManager(
          exporter: exporter,
          processors: [
            ErrorSamplingProcessor(0),
            ErrorDeduplicationProcessor(),
            ErrorRateLimitProcessor(maxReports: 1),
          ],
        );

        await manager.captureException(StateError('same'), fatal: true);
        await manager.captureException(StateError('same'), fatal: true);

        expect(exporter.reports, hasLength(2));
      },
    );

    test('attachment count and byte limits are enforced', () async {
      final exporter = _MemoryErrorExporter();
      final manager = ErrorManager(
        exporter: exporter,
        processors: const [],
        maxAttachmentCount: 2,
        maxAttachmentSize: 3,
        maxTotalAttachmentSize: 4,
      );
      final attachments = [
        ErrorAttachment(filename: 'one', bytes: const [1, 2]),
        ErrorAttachment(filename: 'large', bytes: const [1, 2, 3, 4]),
        ErrorAttachment(filename: 'two', bytes: const [3, 4]),
        ErrorAttachment(filename: 'extra', bytes: const [5]),
      ];

      await manager.captureException(
        StateError('bad'),
        attachments: attachments,
      );

      expect(exporter.reports.single.attachments.map((item) => item.filename), [
        'one',
        'two',
      ]);
      expect(manager.droppedAttachments, 2);
    });

    test('processor failures are isolated and counted', () async {
      final errors = <Object>[];
      final manager = ErrorManager(
        exporter: _MemoryErrorExporter(),
        processors: [_ThrowingErrorProcessor()],
        onInternalError: (error, _) => errors.add(error),
      );

      final id = await manager.captureException(StateError('app'));

      expect(id, isNull);
      expect(manager.processorFailures, 1);
      expect(manager.droppedReports, 1);
      expect(errors.single, isA<StateError>());
    });

    test('processor timeouts are isolated and counted', () async {
      final errors = <Object>[];
      final manager = ErrorManager(
        exporter: _MemoryErrorExporter(),
        processors: [_NeverErrorProcessor()],
        operationTimeout: const Duration(milliseconds: 5),
        onInternalError: (error, _) => errors.add(error),
      );

      final id = await manager.captureException(StateError('app'));

      expect(id, isNull);
      expect(manager.processorFailures, 1);
      expect(errors.single, isA<TimeoutException>());
    });

    test('deduplication storage is bounded by evicting oldest keys', () {
      final processor = ErrorDeduplicationProcessor(maxEntries: 2);
      final first = _report().copyWith(message: 'one');
      final second = _report().copyWith(message: 'two');
      final third = _report().copyWith(message: 'three');

      expect(processor.process(first), isNotNull);
      expect(processor.process(second), isNotNull);
      expect(processor.process(third), isNotNull);
      expect(processor.process(first), isNotNull);
      expect(processor.process(third), isNull);
    });

    test(
      'pending error reports are bounded under exporter backpressure',
      () async {
        final exporter = _BlockingErrorExporter();
        final manager = ErrorManager(
          exporter: exporter,
          processors: const [],
          maxPendingReports: 2,
        );

        final first = manager.captureException(StateError('one'), fatal: true);
        final second = manager.captureException(StateError('two'), fatal: true);
        final dropped = await manager.captureException(
          StateError('three'),
          fatal: true,
        );

        expect(manager.pendingReports, 2);
        expect(dropped, isNull);
        expect(manager.droppedReports, 1);
        exporter.release.complete();
        await Future.wait([first, second]);
        expect(manager.pendingReports, 0);
      },
    );

    test('captures after shutdown are dropped', () async {
      final manager = ErrorManager(
        exporter: _MemoryErrorExporter(),
        processors: const [],
      );
      await manager.shutdown();

      expect(await manager.captureException(StateError('late')), isNull);
      expect(manager.droppedReports, 1);
    });
  });
}

ErrorReport _report({Map<String, Map<String, Object?>> contexts = const {}}) =>
    ErrorReport(
      id: const ErrorId('one'),
      timestamp: DateTime.utc(2026),
      exception: StateError('bad'),
      message: 'bad',
      stackTrace: null,
      severity: ErrorSeverity.error,
      fatal: false,
      handled: true,
      mechanism: ErrorMechanism.manual,
      resource: Resource.empty,
      instrumentationScope: InstrumentationScope('test'),
      attributes: const {},
      tags: const {},
      contexts: contexts,
      fingerprint: const [],
      breadcrumbs: const [],
      attachments: const [],
    );

final class _MemorySpanProcessor implements SpanProcessor {
  final List<SpanData> ended = [];

  @override
  void onEnd(SpanData span) => ended.add(span);
  @override
  void onStart(Span span) {}
  @override
  Future<void> forceFlush() async {}
  @override
  Future<void> shutdown() async {}
}

final class _InvalidIdGenerator implements IdGenerator {
  @override
  String generateSpanId() => 'invalid';
  @override
  String generateTraceId() => 'invalid';
}

final class _TestPropagator implements TracePropagator {
  _TestPropagator(this.name, {this.extracted});

  final String name;
  final SpanContext? extracted;
  int extractCalls = 0;

  @override
  SpanContext? extract(Map<String, String> carrier) {
    extractCalls++;
    return extracted;
  }

  @override
  void inject(SpanContext context, Map<String, String> carrier) {
    carrier[name] = 'injected';
  }
}

final class _ThrowingSampler implements Sampler {
  @override
  SamplingResult sample(SamplingParameters parameters) =>
      throw StateError('sampler failed');
}

final class _RecordOnlySampler implements Sampler {
  @override
  SamplingResult sample(SamplingParameters parameters) => SamplingResult(
    SamplingDecision.recordOnly,
    attributes: const {'sampling.rule': 'record-only'},
    traceState: 'obsi=record-only',
  );
}

final class _ThrowingSpanProcessor implements SpanProcessor {
  @override
  void onEnd(SpanData span) => throw StateError('end failed');
  @override
  void onStart(Span span) => throw StateError('start failed');
  @override
  Future<void> forceFlush() async {}
  @override
  Future<void> shutdown() async {}
}

final class _ThrowOnEndProcessor extends _MemorySpanProcessor {
  @override
  void onEnd(SpanData span) => throw StateError('end failed');
}

final class _MemoryErrorExporter implements ErrorExporter {
  final List<ErrorReport> reports = [];
  @override
  Future<void> export(ErrorReport report) async => reports.add(report);
  @override
  Future<void> forceFlush() async {}
  @override
  Future<void> shutdown() async {}
}

final class _BlockingErrorExporter implements ErrorExporter {
  final Completer<void> release = Completer<void>();

  @override
  Future<void> export(ErrorReport report) => release.future;
  @override
  Future<void> forceFlush() async {}
  @override
  Future<void> shutdown() async {}
}

final class _ThrowingErrorProcessor implements ErrorProcessor {
  @override
  ErrorReport? process(ErrorReport report) =>
      throw StateError('processor failed');
}

final class _NeverErrorProcessor implements ErrorProcessor {
  @override
  Future<ErrorReport?> process(ErrorReport report) =>
      Completer<ErrorReport?>().future;
}
