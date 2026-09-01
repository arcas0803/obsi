import 'dart:async';
import 'dart:convert';

import 'package:obsi/obsi.dart';
import 'package:test/test.dart';

void main() {
  tearDown(Obsi.disable);

  test(
    'Obsi configures, flushes, shuts down, and disables every signal',
    () async {
      final spans = _SpanExporter();
      final logs = _LogExporter();
      final metrics = _MetricExporter();
      final errors = _ErrorExporter();
      final metricReader = ManualMetricReader(metrics);
      final provider = ObsiProvider(
        traces: TracerProvider(processor: SimpleSpanProcessor(spans)),
        logs: LoggerProvider(processor: SimpleLogProcessor(logs)),
        metrics: MeterProvider(readers: [metricReader]),
        errors: ErrorManager(exporter: errors, processors: const []),
      );

      Obsi.configure(provider);
      await Obsi.tracer.trace('span', () async {});
      Obsi.logger('test').info('log');
      Obsi.meter('test')!.createGauge<int>('gauge').record(1);
      await Errors.captureException(StateError('error'));
      await provider.forceFlush();

      expect(spans.values, hasLength(1));
      expect(logs.values, hasLength(1));
      expect(metrics.values, isNotEmpty);
      expect(errors.values, hasLength(1));
      await provider.shutdown();
      Obsi.disable();
      expect(Obsi.provider, isNull);
      expect(Trace.provider, isNull);
      expect(Logs.provider, isNull);
      expect(Metrics.provider, isNull);
      expect(Errors.manager, isNull);
    },
  );

  test(
    'global replacement drains the old provider before installing the new one',
    () async {
      final oldExporter = _SpanExporter();
      final oldProvider = ObsiProvider(
        traces: TracerProvider(processor: SimpleSpanProcessor(oldExporter)),
      );
      final newExporter = _SpanExporter();
      final newProvider = ObsiProvider(
        traces: TracerProvider(processor: SimpleSpanProcessor(newExporter)),
      );
      Obsi.configure(oldProvider);
      await Obsi.tracer.trace('old', () async {});

      await Obsi.replace(newProvider);
      await Obsi.tracer.trace('new', () async {});
      await Obsi.shutdown();

      expect(oldExporter.values.single.name, 'old');
      expect(newExporter.values.single.name, 'new');
      expect(Obsi.provider, isNull);
    },
  );

  test(
    'global lifecycle transitions are serialized and detached eagerly',
    () async {
      final blocker = Completer<void>();
      final oldProcessor = _LifecycleSpanProcessor(
        shutdownBlocker: blocker.future,
      );
      final oldProvider = ObsiProvider(
        traces: TracerProvider(processor: oldProcessor),
      );
      final newProcessor = _LifecycleSpanProcessor();
      final newProvider = ObsiProvider(
        traces: TracerProvider(processor: newProcessor),
      );
      Obsi.configure(oldProvider);

      final replacement = Obsi.replace(newProvider);
      await Future<void>.delayed(Duration.zero);

      expect(Obsi.provider, isNull);
      expect(() => Obsi.configure(newProvider), throwsStateError);
      expect(Obsi.disable, throwsStateError);
      final terminalShutdown = Obsi.shutdown();
      blocker.complete();
      await Future.wait([replacement, terminalShutdown]);

      expect(oldProcessor.shutdowns, 1);
      expect(newProcessor.shutdowns, 1);
      expect(Obsi.provider, isNull);
    },
  );

  test(
    'provider shutdown is concurrent-safe and shuts children down once',
    () async {
      final processor = _LifecycleSpanProcessor();
      final provider = ObsiProvider(
        traces: TracerProvider(processor: processor),
      );

      await Future.wait([
        provider.shutdown(),
        provider.shutdown(),
        provider.forceFlush(),
      ]);

      expect(processor.shutdowns, 1);
      expect(processor.flushes, 0);
    },
  );

  test('disabled global APIs are complete no-ops', () async {
    Obsi.disable();
    final logger = Obsi.logger('disabled');

    expect(logger.isEnabled(LogSeverity.fatal), isFalse);
    logger
      ..trace('trace')
      ..debug('debug')
      ..info('info')
      ..warn('warn')
      ..error('error', error: StateError('error'))
      ..fatal('fatal', error: StateError('fatal'))
      ..log(LogSeverity.info, 'log');
    expect(Obsi.meter('disabled'), isNull);
    expect(await Errors.captureException(StateError('ignored')), isNull);
  });

  test('HTTP semantic helpers normalize methods, ports, and boundaries', () {
    expect(SemanticHttp.normalizedMethod('GET'), 'GET');
    expect(SemanticHttp.normalizedMethod('PROPFIND'), '_OTHER');
    expect(SemanticHttp.serverPort(Uri.parse('https://example.test')), 443);
    expect(SemanticHttp.serverPort(Uri.parse('http://example.test')), 80);
    expect(
      SemanticHttp.serverPort(Uri.parse('https://example.test:8443')),
      8443,
    );
    expect(SemanticMetrics.httpDurationBoundaries.first, 0.005);
    expect(SemanticMetrics.httpDurationBoundaries.last, 10);
  });

  test('noop span exposes safe operations and zone context', () {
    Trace.disable();
    final span = Trace.tracer.startSpan('noop');
    expect(span.context.isValid, isFalse);
    expect(span.name, isEmpty);
    expect(span.isRecording, isFalse);
    expect(span.hasEnded, isTrue);
    expect(
      span.run(() {
        span
          ..setAttribute('key', 'value')
          ..updateName('name')
          ..addEvent('event')
          ..addLink(span.context)
          ..recordException(StateError('error'))
          ..setStatus(SpanStatus.error)
          ..end();
        return 42;
      }),
      42,
    );
  });

  test('trace suppression propagates an unsampled valid context', () {
    final processor = _MemorySpanProcessor();
    final provider = TracerProvider(processor: processor);
    Trace.configure(provider);

    final span = Trace.suppress(() => Trace.tracer.startSpan('suppressed'));

    expect(span.context.isValid, isTrue);
    expect(span.context.sampled, isFalse);
    expect(span.isRecording, isFalse);
  });

  test('multi processors isolate a failing child and continue', () async {
    final diagnostics = <Object>[];
    final healthySpans = _MemorySpanProcessor();
    final spans = MultiSpanProcessor([
      _ThrowingSpanProcessor(),
      healthySpans,
    ], onInternalError: (error, _) => diagnostics.add(error));
    final healthyLogs = _MemoryLogProcessor();
    final logs = MultiLogProcessor([
      _ThrowingLogProcessor(),
      healthyLogs,
    ], onInternalError: (error, _) => diagnostics.add(error));
    final span = _TestSpan(
      const SpanContext(
        traceId: '11111111111111111111111111111111',
        spanId: '2222222222222222',
        sampled: true,
      ),
    );

    spans
      ..onStart(span)
      ..onEnd(_span());
    logs.emit(_log());
    await spans.forceFlush();
    await logs.forceFlush();
    await spans.shutdown();
    await logs.shutdown();

    expect(healthySpans.starts, 1);
    expect(healthySpans.ends, 1);
    expect(healthyLogs.records, 1);
    expect(diagnostics, hasLength(9));
  });

  test('multi error exporter fans out every lifecycle operation', () async {
    final first = _ErrorExporter();
    final second = _ErrorExporter();
    final exporter = MultiErrorExporter([first, second]);

    await exporter.export(_errorReport());
    await exporter.forceFlush();
    await exporter.shutdown();

    expect(first.values, hasLength(1));
    expect(second.values, hasLength(1));
    expect(first.flushes, 1);
    expect(second.shutdowns, 1);
  });

  test('multi signal components have a terminal idempotent shutdown', () async {
    final spanChild = _LifecycleSpanProcessor();
    final spans = MultiSpanProcessor([spanChild]);
    final logChild = _LifecycleLogProcessor();
    final logs = MultiLogProcessor([logChild]);
    final errorChild = _ErrorExporter();
    final errors = MultiErrorExporter([errorChild]);

    await Future.wait([
      spans.shutdown(),
      spans.shutdown(),
      logs.shutdown(),
      logs.shutdown(),
      errors.shutdown(),
      errors.shutdown(),
    ]);
    spans
      ..onStart(
        _TestSpan(
          const SpanContext(
            traceId: '11111111111111111111111111111111',
            spanId: '2222222222222222',
            sampled: true,
          ),
        ),
      )
      ..onEnd(_span());
    logs.emit(_log());

    expect(spanChild.flushes, 1);
    expect(spanChild.shutdowns, 1);
    expect(spanChild.starts, 0);
    expect(spanChild.ends, 0);
    expect(logChild.flushes, 1);
    expect(logChild.shutdowns, 1);
    expect(logChild.records, 0);
    expect(errorChild.shutdowns, 1);
    await expectLater(errors.export(_errorReport()), throwsStateError);
  });

  test('console exporters emit valid JSON records', () async {
    final printed = <String>[];
    await runZoned(
      () async {
        await const ConsoleSpanExporter().export([_span()]);
        await const ConsoleLogExporter().export([_log()]);
        await const ConsoleMetricExporter().export([_metric()]);
        await const ConsoleErrorExporter().export(_errorReport());
      },
      zoneSpecification: ZoneSpecification(
        print: (_, _, _, line) => printed.add(line),
      ),
    );

    expect(printed, hasLength(4));
    for (final line in printed) {
      expect(jsonDecode(line), isA<Map<String, Object?>>());
    }
  });

  test('console exporters offer human-friendly output', () async {
    final printed = <String>[];
    const options = PrettyConsoleOptions(
      colors: false,
      includeTimestamp: false,
      includeTraceContext: false,
      includeStackTrace: false,
    );

    await ConsoleSpanExporter.pretty(
      options: options,
      writer: printed.add,
    ).export([_span()]);
    await ConsoleLogExporter.pretty(
      options: options,
      writer: printed.add,
    ).export([_log()]);
    await ConsoleMetricExporter.pretty(
      options: options,
      writer: printed.add,
    ).export([_metric()]);
    await ConsoleErrorExporter.pretty(
      options: options,
      writer: printed.add,
    ).export(_errorReport());

    expect(printed, hasLength(4));
    expect(
      printed[0],
      allOf(contains('SPAN'), contains('[test]'), contains('1.00 ms')),
    );
    expect(
      printed[1],
      allOf(contains('INFO'), contains('[test]'), contains('one=1')),
    );
    expect(
      printed[2],
      allOf(contains('METRIC'), contains('metric'), contains('1')),
    );
    expect(
      printed[3],
      allOf(contains('ERROR'), contains('exception'), contains('handled')),
    );
    for (final line in printed) {
      expect(line, isNot(startsWith('{')));
      expect(line, isNot(contains('\x1B[')));
    }
  });

  test('pretty console options control details and ANSI colors', () async {
    final printed = <String>[];
    const options = PrettyConsoleOptions(
      includeTimestamp: false,
      includeResource: true,
      multilineAttributes: true,
    );

    await ConsoleLogExporter.pretty(
      options: options,
      writer: printed.add,
    ).export([_log()]);

    expect(printed.single, contains('\x1B['));
    expect(printed.single, contains('\n    one'));
  });

  test('pretty console exporters render rich telemetry details', () async {
    final printed = <String>[];
    const options = PrettyConsoleOptions(
      colors: false,
      includeResource: true,
      includeScopeVersion: true,
      maxValueLength: 32,
    );

    await ConsoleSpanExporter.pretty(
      options: options,
      writer: printed.add,
    ).export([_richSpan()]);
    await ConsoleLogExporter.pretty(
      options: options,
      writer: printed.add,
    ).export([_richLog()]);
    await ConsoleMetricExporter.pretty(
      options: options,
      writer: printed.add,
    ).export([_histogramMetric(), _emptyMetric()]);
    await ConsoleErrorExporter.pretty(
      options: options,
      writer: printed.add,
    ).export(_richErrorReport());

    expect(printed, hasLength(5));
    expect(
      printed[0],
      allOf(
        contains('checkout@test-version'),
        contains('status'),
        contains('parent'),
        contains('events'),
        contains('links'),
        contains('dropped'),
        contains('resource'),
      ),
    );
    expect(
      printed[1],
      allOf(contains('FATAL'), contains('trace'), contains('stack')),
    );
    expect(
      printed[2],
      allOf(contains('avg=5.00 ms'), contains('≤ 5.0 ms'), contains('+Inf')),
    );
    expect(printed[3], contains('none'));
    expect(
      printed[4],
      allOf([
        contains('reason'),
        contains('tags'),
        contains('contexts'),
        contains('breadcrumbs'),
        contains('fingerprint'),
        contains('attachments'),
        contains('user'),
        contains('stack'),
      ]),
    );
  });

  test('periodic metric reader exports and shuts down once', () async {
    final exporter = _MetricExporter();
    final reader = PeriodicMetricReader(
      exporter,
      interval: const Duration(milliseconds: 1),
    );
    final provider = MeterProvider(readers: [reader]);
    provider.getMeter('test').createGauge<int>('gauge').record(1);

    await Future<void>.delayed(const Duration(milliseconds: 8));
    final first = reader.shutdown();
    final second = reader.shutdown();
    await Future.wait([first, second]);

    expect(exporter.values, isNotEmpty);
    expect(exporter.shutdowns, 1);
  });

  test('isolate error listener close is idempotent', () {
    final listener = Errors.listenToIsolateErrors();
    listener
      ..close()
      ..close();
  });
}

SpanData _span() => SpanData(
  name: 'span',
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
  attributes: const {'one': 1},
  events: const [],
  links: const [],
);

SpanData _richSpan() => SpanData(
  name: 'checkout',
  context: const SpanContext(
    traceId: '11111111111111111111111111111111',
    spanId: '2222222222222222',
    sampled: true,
  ),
  parentSpanId: '3333333333333333',
  kind: SpanKind.server,
  startTime: DateTime.utc(2026),
  endTime: DateTime.utc(2026).add(const Duration(seconds: 2)),
  status: SpanStatus.error,
  statusDescription: 'gateway unavailable',
  resource: Resource({'service.name': 'checkout'}),
  instrumentationScope: InstrumentationScope(
    'checkout',
    version: 'test-version',
  ),
  attributes: const {'http.response.status_code': 503},
  events: [
    SpanEvent(
      name: 'request.sent',
      timestamp: DateTime.utc(2026).add(const Duration(milliseconds: 50)),
      attributes: const {'attempt': 1},
    ),
  ],
  links: [
    SpanLink(
      const SpanContext(
        traceId: '44444444444444444444444444444444',
        spanId: '5555555555555555',
        sampled: true,
      ),
      attributes: const {'type': 'retry'},
    ),
  ],
  droppedAttributes: 1,
  droppedEvents: 2,
  droppedLinks: 3,
);

LogRecord _log() => LogRecord(
  timestamp: DateTime.utc(2026),
  observedTimestamp: DateTime.utc(2026),
  severity: LogSeverity.info,
  body: 'log',
  attributes: const {'one': 1},
  resource: Resource.empty,
  instrumentationScope: InstrumentationScope('test'),
);

LogRecord _richLog() => LogRecord(
  timestamp: DateTime.utc(2026),
  observedTimestamp: DateTime.utc(2026),
  severity: LogSeverity.fatal,
  body: 'payment failed',
  attributes: const {'retryable': false},
  spanContext: const SpanContext(
    traceId: '11111111111111111111111111111111',
    spanId: '2222222222222222',
    sampled: true,
  ),
  error: StateError('declined'),
  stackTrace: StackTrace.fromString('#0 checkout (checkout.dart:1)'),
  resource: Resource({'service.name': 'checkout'}),
  instrumentationScope: InstrumentationScope('checkout'),
);

MetricData _metric() => MetricData(
  name: 'metric',
  kind: InstrumentKind.gauge,
  description: null,
  unit: '1',
  resource: Resource.empty,
  instrumentationScope: InstrumentationScope('test'),
  points: [
    MetricPoint(
      attributes: const {'one': 1},
      timestamp: DateTime.utc(2026),
      value: 1,
    ),
  ],
);

MetricData _histogramMetric() => MetricData(
  name: 'request.duration',
  kind: InstrumentKind.histogram,
  description: 'Request duration',
  unit: 'ms',
  resource: Resource({'service.name': 'checkout'}),
  instrumentationScope: InstrumentationScope('checkout'),
  temporality: AggregationTemporality.cumulative,
  points: [
    MetricPoint(
      attributes: const {'route': '/checkout'},
      timestamp: DateTime.utc(2026),
      count: 2,
      sum: 10,
      min: 4,
      max: 6,
      boundaries: const [5],
      bucketCounts: const [1, 1],
    ),
  ],
);

MetricData _emptyMetric() => MetricData(
  name: 'empty',
  kind: InstrumentKind.gauge,
  description: null,
  unit: null,
  resource: Resource.empty,
  instrumentationScope: InstrumentationScope('test'),
  points: const [],
);

ErrorReport _errorReport() => ErrorReport(
  id: const ErrorId('error'),
  timestamp: DateTime.utc(2026),
  exception: StateError('error'),
  message: 'error',
  stackTrace: StackTrace.current,
  severity: ErrorSeverity.error,
  fatal: false,
  handled: true,
  mechanism: ErrorMechanism.manual,
  resource: Resource.empty,
  instrumentationScope: InstrumentationScope('test'),
  attributes: const {'one': 1},
  tags: const {},
  contexts: const {},
  fingerprint: const [],
  breadcrumbs: const [],
  attachments: const [],
);

ErrorReport _richErrorReport() => ErrorReport(
  id: const ErrorId('error-rich'),
  timestamp: DateTime.utc(2026),
  exception: StateError('declined'),
  message: 'payment failed',
  stackTrace: StackTrace.fromString('#0 checkout (checkout.dart:1)'),
  severity: ErrorSeverity.fatal,
  fatal: true,
  handled: false,
  mechanism: ErrorMechanism.zone,
  reason: 'gateway rejected payment',
  resource: Resource({'service.name': 'checkout'}),
  instrumentationScope: InstrumentationScope('checkout'),
  attributes: const {'retryable': false},
  tags: const {'environment': 'test'},
  contexts: const {
    'device': {'model': 'test'},
  },
  fingerprint: const ['payment', 'declined'],
  breadcrumbs: [
    ErrorBreadcrumb(
      timestamp: DateTime.utc(2026).subtract(const Duration(milliseconds: 20)),
      category: 'payment',
      message: 'requested',
      data: const {'method': 'card'},
    ),
  ],
  attachments: [
    ErrorAttachment(filename: 'request.txt', bytes: const [1, 2, 3]),
  ],
  user: ErrorUser(id: 'user-1', data: const {'plan': 'premium'}),
  spanContext: const SpanContext(
    traceId: '11111111111111111111111111111111',
    spanId: '2222222222222222',
    sampled: true,
  ),
);

final class _SpanExporter implements SpanExporter {
  final List<SpanData> values = [];
  @override
  Future<void> export(List<SpanData> batch) async => values.addAll(batch);
  @override
  Future<void> shutdown() async {}
}

final class _LogExporter implements LogExporter {
  final List<LogRecord> values = [];
  @override
  Future<void> export(List<LogRecord> batch) async => values.addAll(batch);
  @override
  Future<void> shutdown() async {}
}

final class _MetricExporter implements MetricExporter {
  final List<MetricData> values = [];
  int shutdowns = 0;
  @override
  Future<void> export(List<MetricData> metrics) async => values.addAll(metrics);
  @override
  Future<void> shutdown() async {
    shutdowns++;
  }
}

final class _ErrorExporter implements ErrorExporter {
  final List<ErrorReport> values = [];
  int flushes = 0;
  int shutdowns = 0;
  @override
  Future<void> export(ErrorReport report) async => values.add(report);
  @override
  Future<void> forceFlush() async => flushes++;
  @override
  Future<void> shutdown() async => shutdowns++;
}

final class _MemorySpanProcessor implements SpanProcessor {
  int starts = 0;
  int ends = 0;
  @override
  void onStart(Span span) => starts++;
  @override
  void onEnd(SpanData span) => ends++;
  @override
  Future<void> forceFlush() async {}
  @override
  Future<void> shutdown() async {}
}

final class _LifecycleSpanProcessor implements SpanProcessor {
  _LifecycleSpanProcessor({this.shutdownBlocker});

  final Future<void>? shutdownBlocker;
  int starts = 0;
  int ends = 0;
  int flushes = 0;
  int shutdowns = 0;

  @override
  void onStart(Span span) => starts++;
  @override
  void onEnd(SpanData span) => ends++;
  @override
  Future<void> forceFlush() async => flushes++;
  @override
  Future<void> shutdown() async {
    shutdowns++;
    await shutdownBlocker;
  }
}

final class _ThrowingSpanProcessor implements SpanProcessor {
  @override
  void onStart(Span span) => throw StateError('start');
  @override
  void onEnd(SpanData span) => throw StateError('end');
  @override
  Future<void> forceFlush() => Future.error(StateError('flush'));
  @override
  Future<void> shutdown() => Future.error(StateError('shutdown'));
}

final class _MemoryLogProcessor implements LogProcessor {
  int records = 0;
  @override
  void emit(LogRecord record) => records++;
  @override
  Future<void> forceFlush() async {}
  @override
  Future<void> shutdown() async {}
}

final class _LifecycleLogProcessor implements LogProcessor {
  int records = 0;
  int flushes = 0;
  int shutdowns = 0;

  @override
  void emit(LogRecord record) => records++;
  @override
  Future<void> forceFlush() async => flushes++;
  @override
  Future<void> shutdown() async => shutdowns++;
}

final class _ThrowingLogProcessor implements LogProcessor {
  @override
  void emit(LogRecord record) => throw StateError('emit');
  @override
  Future<void> forceFlush() => Future.error(StateError('flush'));
  @override
  Future<void> shutdown() => Future.error(StateError('shutdown'));
}

final class _TestSpan implements Span {
  _TestSpan(this.context);

  @override
  final SpanContext context;
  @override
  bool get hasEnded => false;
  @override
  bool get isRecording => true;
  @override
  String get name => 'test';
  @override
  void addEvent(String name, {Map<String, Object?> attributes = const {}}) {}
  @override
  void addLink(
    SpanContext context, {
    Map<String, Object?> attributes = const {},
  }) {}
  @override
  void end() {}
  @override
  void recordException(Object exception, {StackTrace? stackTrace}) {}
  @override
  R run<R>(R Function() callback) => callback();
  @override
  void setAttribute(String key, Object? value) {}
  @override
  void setStatus(SpanStatus status, {String? description}) {}
  @override
  void updateName(String name) {}
}
