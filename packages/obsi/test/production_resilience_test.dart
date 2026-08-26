import 'dart:async';

import 'package:obsi/obsi.dart';
import 'package:test/test.dart';

void main() {
  group('span processor resilience', () {
    test('batch queue remains bounded while exports are blocked', () async {
      final exporter = _BlockingSpanExporter();
      final processor = BatchSpanProcessor(
        exporter,
        maxQueueSize: 4,
        maxExportBatchSize: 2,
        scheduledDelay: const Duration(days: 1),
      );

      for (var index = 0; index < 10; index++) {
        processor.onEnd(_span('span-$index'));
      }

      expect(processor.queueSize, 4);
      expect(processor.droppedSpans, 6);
      exporter.release();
      await processor.shutdown();
      expect(exporter.exported, hasLength(4));
    });

    test('a failed batch does not poison later exports', () async {
      final errors = <Object>[];
      final exporter = _FailOnceSpanExporter();
      final processor = BatchSpanProcessor(
        exporter,
        maxQueueSize: 4,
        maxExportBatchSize: 2,
        scheduledDelay: const Duration(days: 1),
        onExportError: (error, _) => errors.add(error),
      );

      for (var index = 0; index < 4; index++) {
        processor.onEnd(_span('span-$index'));
      }
      await processor.forceFlush();

      expect(exporter.calls, 2);
      expect(exporter.exported.map((span) => span.name), ['span-2', 'span-3']);
      expect(processor.exportFailures, 1);
      expect(errors, hasLength(1));
      await processor.shutdown();
    });

    test('simple processor bounds concurrent exports', () async {
      final exporter = _BlockingSpanExporter();
      final processor = SimpleSpanProcessor(exporter, maxPendingExports: 2);

      for (var index = 0; index < 8; index++) {
        processor.onEnd(_span('span-$index'));
      }

      expect(processor.pendingExports, 2);
      expect(processor.droppedSpans, 6);
      exporter.release();
      await processor.shutdown();
    });

    test('concurrent shutdown callers await the same operation', () async {
      final exporter = _BlockingShutdownSpanExporter();
      final processor = SimpleSpanProcessor(exporter);

      final first = processor.shutdown();
      final second = processor.shutdown();
      expect(identical(first, second), isTrue);
      await Future<void>.delayed(Duration.zero);
      expect(exporter.shutdownCalls, 1);

      exporter.release();
      await Future.wait([first, second]);
      expect(exporter.shutdownCalls, 1);
    });

    test('a throwing diagnostic handler cannot escape', () async {
      final processor = SimpleSpanProcessor(
        _AlwaysFailSpanExporter(),
        onExportError: (_, _) => throw StateError('diagnostic failed'),
      );

      processor.onEnd(_span('safe'));
      await expectLater(processor.forceFlush(), completes);
      await expectLater(processor.shutdown(), completes);
    });

    test('a hung exporter cannot block flush forever', () async {
      final errors = <Object>[];
      final processor = SimpleSpanProcessor(
        _NeverSpanExporter(),
        exportTimeout: const Duration(milliseconds: 5),
        onExportError: (error, _) => errors.add(error),
      );

      processor.onEnd(_span('timeout'));
      await processor.forceFlush().timeout(const Duration(seconds: 1));

      expect(errors.single, isA<TimeoutException>());
      expect(processor.exportFailures, 1);
      await processor.shutdown();
    });
  });

  group('log processor resilience', () {
    test(
      'batch logs remain bounded and recover after export failure',
      () async {
        final exporter = _FailOnceLogExporter();
        final processor = BatchLogProcessor(
          exporter,
          maxQueueSize: 4,
          maxExportBatchSize: 2,
          scheduledDelay: const Duration(days: 1),
        );

        for (var index = 0; index < 6; index++) {
          processor.emit(_log('log-$index'));
        }
        await processor.forceFlush();

        expect(processor.droppedRecords, 2);
        expect(processor.exportFailures, 1);
        expect(exporter.exported.map((log) => log.body), ['log-2', 'log-3']);
        await processor.shutdown();
      },
    );

    test('simple logs bound concurrent operations', () async {
      final exporter = _BlockingLogExporter();
      final processor = SimpleLogProcessor(exporter, maxPendingExports: 1);

      processor
        ..emit(_log('accepted'))
        ..emit(_log('dropped'));

      expect(processor.pendingExports, 1);
      expect(processor.droppedRecords, 1);
      exporter.release();
      await processor.shutdown();
    });
  });

  group('metric reader resilience', () {
    test('manual collections are serialized', () async {
      final exporter = _SerialMetricExporter();
      final reader = ManualMetricReader(exporter)..bind(_MetricProducer());

      final first = reader.collect();
      final second = reader.collect();
      await Future<void>.delayed(Duration.zero);
      expect(exporter.maxConcurrent, 1);
      exporter.releaseNext();
      await Future<void>.delayed(Duration.zero);
      exporter.releaseNext();
      await Future.wait([first, second]);
      expect(exporter.maxConcurrent, 1);
      final shutdown = reader.shutdown();
      await Future<void>.delayed(Duration.zero);
      exporter.releaseNext();
      await shutdown;
    });

    test(
      'failed metric export is reported and later collection runs',
      () async {
        final errors = <Object>[];
        final exporter = _FailOnceMetricExporter();
        final reader = ManualMetricReader(
          exporter,
          onExportError: (error, _) => errors.add(error),
        )..bind(_MetricProducer());

        await reader.collect();
        await reader.collect();

        expect(exporter.calls, 2);
        expect(errors, hasLength(1));
        await reader.shutdown();
      },
    );

    test('a reader cannot be bound to two producers', () {
      final reader = ManualMetricReader(_MemoryMetricExporter());
      reader.bind(_MetricProducer());
      expect(() => reader.bind(_MetricProducer()), throwsStateError);
    });
  });
}

SpanData _span(String name) => SpanData(
  name: name,
  context: const SpanContext(
    traceId: '11111111111111111111111111111111',
    spanId: '2222222222222222',
    sampled: true,
  ),
  parentSpanId: null,
  kind: SpanKind.internal,
  startTime: DateTime.utc(2026),
  endTime: DateTime.utc(2026).add(const Duration(milliseconds: 1)),
  status: SpanStatus.ok,
  statusDescription: null,
  resource: Resource.empty,
  instrumentationScope: InstrumentationScope('test'),
  attributes: const {},
  events: const [],
  links: const [],
);

LogRecord _log(String body) => LogRecord(
  timestamp: DateTime.utc(2026),
  observedTimestamp: DateTime.utc(2026),
  severity: LogSeverity.info,
  body: body,
  resource: Resource.empty,
  instrumentationScope: InstrumentationScope('test'),
  attributes: const {},
);

MetricData _metric() => MetricData(
  name: 'requests',
  kind: InstrumentKind.counter,
  description: null,
  unit: null,
  resource: Resource.empty,
  instrumentationScope: InstrumentationScope('test'),
  points: [
    MetricPoint(attributes: const {}, timestamp: DateTime.utc(2026), value: 1),
  ],
);

final class _BlockingSpanExporter implements SpanExporter {
  final Completer<void> _gate = Completer<void>();
  final List<SpanData> exported = [];

  @override
  Future<void> export(List<SpanData> batch) async {
    await _gate.future;
    exported.addAll(batch);
  }

  void release() => _gate.complete();

  @override
  Future<void> shutdown() async {}
}

final class _FailOnceSpanExporter implements SpanExporter {
  int calls = 0;
  final List<SpanData> exported = [];

  @override
  Future<void> export(List<SpanData> batch) async {
    calls++;
    if (calls == 1) throw StateError('first failed');
    exported.addAll(batch);
  }

  @override
  Future<void> shutdown() async {}
}

final class _AlwaysFailSpanExporter implements SpanExporter {
  @override
  Future<void> export(List<SpanData> batch) =>
      Future.error(StateError('export failed'));

  @override
  Future<void> shutdown() => Future.error(StateError('shutdown failed'));
}

final class _NeverSpanExporter implements SpanExporter {
  @override
  Future<void> export(List<SpanData> batch) => Completer<void>().future;

  @override
  Future<void> shutdown() async {}
}

final class _BlockingShutdownSpanExporter implements SpanExporter {
  final Completer<void> _gate = Completer<void>();
  int shutdownCalls = 0;

  @override
  Future<void> export(List<SpanData> batch) async {}

  @override
  Future<void> shutdown() {
    shutdownCalls++;
    return _gate.future;
  }

  void release() => _gate.complete();
}

final class _FailOnceLogExporter implements LogExporter {
  int calls = 0;
  final List<LogRecord> exported = [];

  @override
  Future<void> export(List<LogRecord> batch) async {
    calls++;
    if (calls == 1) throw StateError('first failed');
    exported.addAll(batch);
  }

  @override
  Future<void> shutdown() async {}
}

final class _BlockingLogExporter implements LogExporter {
  final Completer<void> _gate = Completer<void>();

  @override
  Future<void> export(List<LogRecord> batch) => _gate.future;

  void release() => _gate.complete();

  @override
  Future<void> shutdown() async {}
}

final class _MetricProducer implements MetricProducer {
  @override
  List<MetricData> collect() => [_metric()];
}

final class _SerialMetricExporter implements MetricExporter {
  final List<Completer<void>> _gates = [];
  int concurrent = 0;
  int maxConcurrent = 0;

  @override
  Future<void> export(List<MetricData> metrics) async {
    concurrent++;
    if (concurrent > maxConcurrent) maxConcurrent = concurrent;
    final gate = Completer<void>();
    _gates.add(gate);
    await gate.future;
    concurrent--;
  }

  void releaseNext() => _gates.removeAt(0).complete();

  @override
  Future<void> shutdown() async {}
}

final class _FailOnceMetricExporter implements MetricExporter {
  int calls = 0;

  @override
  Future<void> export(List<MetricData> metrics) async {
    calls++;
    if (calls == 1) throw StateError('first failed');
  }

  @override
  Future<void> shutdown() async {}
}

final class _MemoryMetricExporter implements MetricExporter {
  @override
  Future<void> export(List<MetricData> metrics) async {}

  @override
  Future<void> shutdown() async {}
}
