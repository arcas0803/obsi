import 'package:obsi/obsi.dart';
import 'package:test/test.dart';

void main() {
  late _MemorySpanExporter spanExporter;
  late TracerProvider tracerProvider;

  setUp(() {
    spanExporter = _MemorySpanExporter();
    tracerProvider = TracerProvider(
      processor: SimpleSpanProcessor(spanExporter),
    );
    Trace.configure(tracerProvider);
  });

  tearDown(() async {
    Errors.disable();
    Trace.disable();
    await tracerProvider.shutdown();
  });

  test('captures scoped context and correlates the active trace', () async {
    final exporter = _MemoryErrorExporter();
    final manager = ErrorManager(
      exporter: exporter,
      processors: [ErrorSanitizingProcessor()],
      resource: Resource(const {'service.name': 'checkout'}),
    );
    Errors.configure(manager);

    await Errors.withScope(
      () => Trace.tracer.trace('checkout', () async {
        Errors.addBreadcrumb(
          ErrorBreadcrumb(
            timestamp: DateTime.now(),
            category: 'navigation',
            message: '/checkout',
          ),
        );
        await Errors.captureException(
          StateError('payment rejected'),
          attributes: const {'password': 'secret', 'attempt': 2},
        );
      }),
      user: ErrorUser(id: 'customer-1'),
      tags: const {'tenant': 'acme'},
    );

    final report = exporter.reports.single;
    expect(report.user?.id, 'customer-1');
    expect(report.tags['tenant'], 'acme');
    expect(report.attributes['password'], '[Filtered]');
    expect(report.breadcrumbs.single.message, '/checkout');
    expect(report.spanContext?.traceId, isNotEmpty);
    expect(report.resource.attributes['service.name'], 'checkout');
  });

  test(
    'deduplicates equivalent reports inside the configured window',
    () async {
      final exporter = _MemoryErrorExporter();
      final manager = ErrorManager(
        exporter: exporter,
        processors: [ErrorDeduplicationProcessor()],
      );
      Errors.configure(manager);

      final first = await Errors.captureException(StateError('same'));
      final second = await Errors.captureException(StateError('same'));

      expect(first, isNotNull);
      expect(second, isNull);
      expect(exporter.reports, hasLength(1));
    },
  );

  test(
    'guard captures an unhandled fatal error and preserves the throw',
    () async {
      final exporter = _MemoryErrorExporter();
      Errors.configure(ErrorManager(exporter: exporter, processors: const []));

      await expectLater(
        Errors.guard<void>(() => throw ArgumentError('invalid')),
        throwsArgumentError,
      );

      final report = exporter.reports.single;
      expect(report.fatal, isTrue);
      expect(report.handled, isFalse);
      expect(report.mechanism, ErrorMechanism.zone);
    },
  );

  test('scope keeps only the most recent breadcrumbs', () {
    final scope = ErrorScope(breadcrumbLimit: 2);
    for (final message in ['one', 'two', 'three']) {
      scope.addBreadcrumb(
        ErrorBreadcrumb(
          timestamp: DateTime.now(),
          category: 'test',
          message: message,
        ),
      );
    }

    expect(scope.breadcrumbs.map((item) => item.message), ['two', 'three']);
  });

  test('structured logs become error breadcrumbs', () async {
    final exporter = _MemoryErrorExporter();
    Errors.configure(ErrorManager(exporter: exporter, processors: const []));
    final logs = LoggerProvider(processor: SimpleLogProcessor(_DiscardLogs()));
    final logger = logs.getLogger('checkout');

    logger.info('payment started', attributes: const {'attempt': 1});
    await Errors.captureException(StateError('payment failed'));

    final breadcrumb = exporter.reports.single.breadcrumbs.single;
    expect(breadcrumb.category, 'log');
    expect(breadcrumb.message, 'payment started');
    expect(breadcrumb.data['attempt'], 1);
    await logs.shutdown();
  });

  test('exporter failures are isolated and reported internally', () async {
    Object? internalError;
    final manager = ErrorManager(
      exporter: _FailingErrorExporter(),
      processors: const [],
      onInternalError: (error, _) => internalError = error,
    );

    final id = await manager.captureException(StateError('application'));

    expect(id, isNotNull);
    expect(internalError, isA<StateError>());
  });
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

final class _FailingErrorExporter implements ErrorExporter {
  @override
  Future<void> export(ErrorReport report) =>
      Future.error(StateError('exporter failed'));

  @override
  Future<void> forceFlush() async {}

  @override
  Future<void> shutdown() async {}
}

final class _MemorySpanExporter implements SpanExporter {
  @override
  Future<void> export(List<SpanData> batch) async {}

  @override
  Future<void> shutdown() async {}
}

final class _DiscardLogs implements LogExporter {
  @override
  Future<void> export(List<LogRecord> batch) async {}

  @override
  Future<void> shutdown() async {}
}
