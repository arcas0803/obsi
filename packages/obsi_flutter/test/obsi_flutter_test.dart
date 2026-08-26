import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:obsi/obsi.dart';
import 'package:obsi_flutter/obsi_flutter.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  tearDown(Errors.disable);

  test('installs, rejects competing ownership, and restores handlers', () {
    final previous = FlutterError.onError;
    final integration = ObsiFlutterErrorIntegration()
      ..install(
        requireConfiguredManager: false,
        preserveExistingHandlers: false,
      );

    expect(integration.isInstalled, isTrue);
    expect(
      () => ObsiFlutterErrorIntegration().install(
        requireConfiguredManager: false,
      ),
      throwsStateError,
    );

    integration.uninstall();
    expect(integration.isInstalled, isFalse);
    expect(FlutterError.onError, same(previous));
  });

  test('requires an Obsi error manager by default', () {
    expect(ObsiFlutterErrorIntegration().install, throwsStateError);
  });

  test('captures Flutter framework and platform errors with context', () async {
    final exporter = _MemoryErrorExporter();
    final manager = ErrorManager(exporter: exporter, processors: const []);
    Errors.configure(manager);
    final integration = ObsiFlutterErrorIntegration()
      ..install(preserveExistingHandlers: false);
    addTearDown(() {
      if (integration.isInstalled) integration.uninstall();
    });

    FlutterError.onError!(
      FlutterErrorDetails(
        exception: StateError('framework'),
        stack: StackTrace.current,
        library: 'checkout',
        context: ErrorDescription('building checkout'),
      ),
    );
    final platformHandled = PlatformDispatcher.instance.onError!(
      StateError('platform'),
      StackTrace.current,
    );
    await manager.forceFlush();

    expect(platformHandled, isTrue);
    expect(exporter.reports, hasLength(2));
    expect(exporter.reports[0].mechanism, ErrorMechanism.flutterFramework);
    expect(exporter.reports[0].contexts['flutter']?['library'], 'checkout');
    expect(exporter.reports[1].mechanism, ErrorMechanism.platformDispatcher);
    integration.uninstall();
    await manager.shutdown();
  });

  testWidgets('observes real push/pop, metrics, and error breadcrumbs', (
    tester,
  ) async {
    final spans = _MemorySpanExporter();
    final traces = TracerProvider(processor: SimpleSpanProcessor(spans));
    final metricExporter = _MemoryMetricExporter();
    final reader = ManualMetricReader(metricExporter);
    final meters = MeterProvider(readers: [reader]);
    final observer = ObsiNavigatorObserver(
      tracer: traces.tracer,
      meter: meters.getMeter('navigation'),
    );
    late List<ErrorBreadcrumb> breadcrumbs;

    await ErrorScope().run(() async {
      await tester.pumpWidget(
        MaterialApp(
          navigatorObservers: [observer],
          initialRoute: '/',
          routes: {
            '/': (context) => Scaffold(
              body: TextButton(
                key: const ValueKey('open-details'),
                onPressed: () => Navigator.of(context).pushNamed('/details'),
                child: const Text('Open'),
              ),
            ),
            '/details': (context) => Scaffold(
              body: TextButton(
                key: const ValueKey('go-back'),
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('Back'),
              ),
            ),
          },
        ),
      );
      await tester.tap(find.byKey(const ValueKey('open-details')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('go-back')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('go-back')));
      await tester.pumpAndSettle();
      breadcrumbs = Errors.currentScope.breadcrumbs;
    });
    await traces.shutdown();
    await reader.collect();

    expect(spans.spans.map((span) => span.attributes['navigation.operation']), [
      'push',
      'push',
      'pop',
    ]);
    expect(spans.spans[1].attributes['app.screen.name'], '/details');
    expect(spans.spans[2].attributes['app.screen.name'], '/');
    expect(breadcrumbs.map((item) => item.category).toSet(), {'navigation'});
    expect(breadcrumbs.last.message, 'pop /');
    final names = metricExporter.metrics.map((metric) => metric.name).toSet();
    expect(names, contains(ObsiNavigationMetrics.transitionCount));
    expect(names, contains(ObsiNavigationMetrics.screenVisibleDuration));
    await meters.shutdown();
  });

  test('ignores unnamed routes safely by default', () async {
    final spans = _MemorySpanExporter();
    final traces = TracerProvider(processor: SimpleSpanProcessor(spans));
    final observer = ObsiNavigatorObserver(tracer: traces.tracer);
    final route = PageRouteBuilder<void>(
      pageBuilder: (_, _, _) => const SizedBox(),
    );

    observer
      ..didPush(route, null)
      ..didChangeTop(route, null)
      ..didStartUserGesture(route, null)
      ..didStopUserGesture();
    await traces.shutdown();

    expect(spans.spans, isEmpty);
  });

  test(
    'supports unnamed routes, custom names, attributes, and navigator IDs',
    () async {
      final spans = _MemorySpanExporter();
      final traces = TracerProvider(processor: SimpleSpanProcessor(spans));
      final observer = ObsiNavigatorObserver(
        tracer: traces.tracer,
        navigatorName: 'shell-a',
        options: ObsiNavigatorObserverOptions(
          includeUnnamedRoutes: true,
          routeNameResolver: (_) => 'catalog',
          attributes: (operation, _, _) => {'app.flow': operation},
        ),
      );
      final route = PageRouteBuilder<void>(
        pageBuilder: (_, _, _) => const SizedBox(),
      );

      observer.didPush(route, null);
      await traces.shutdown();

      final span = spans.spans.single;
      expect(span.attributes['app.screen.name'], 'catalog');
      expect(span.attributes['navigation.navigator.name'], 'shell-a');
      expect(span.attributes['app.flow'], 'push');
    },
  );

  test('covers replace, remove, and gesture transitions', () async {
    final spans = _MemorySpanExporter();
    final traces = TracerProvider(processor: SimpleSpanProcessor(spans));
    final observer = ObsiNavigatorObserver(tracer: traces.tracer);
    final first = _route('/one');
    final second = _route('/two');

    observer
      ..didPush(first, null)
      ..didChangeTop(first, null)
      ..didReplace(newRoute: second, oldRoute: first)
      ..didChangeTop(second, first)
      ..didStartUserGesture(second, first)
      ..didStopUserGesture()
      ..didRemove(second, first);
    await traces.shutdown();

    expect(spans.spans.map((span) => span.attributes['navigation.operation']), [
      'push',
      'replace',
      'gesture.start',
      'gesture.stop',
      'remove',
    ]);
  });

  test('emits structured logs only when enabled', () async {
    final logs = _MemoryLogExporter();
    final logProvider = LoggerProvider(processor: SimpleLogProcessor(logs));
    final observer = ObsiNavigatorObserver(
      logger: logProvider.getLogger('navigation'),
      options: const ObsiNavigatorObserverOptions(
        emitLogs: true,
        recordBreadcrumbs: false,
      ),
    );

    observer.didPush(_route('/logged'), null);
    await logProvider.shutdown();

    expect(logs.records.single.body, 'Navigation push');
    expect(logs.records.single.attributes['app.screen.name'], '/logged');
  });

  test('filtering and callback failures never escape the observer', () async {
    final diagnostics = <Object>[];
    final spans = _MemorySpanExporter();
    final traces = TracerProvider(processor: SimpleSpanProcessor(spans));
    final filtered = ObsiNavigatorObserver(
      tracer: traces.tracer,
      options: const ObsiNavigatorObserverOptions(
        shouldInstrument: _neverInstrument,
      ),
    );
    final failing = ObsiNavigatorObserver(
      tracer: traces.tracer,
      options: ObsiNavigatorObserverOptions(
        routeNameResolver: (_) => throw StateError('name'),
        shouldInstrument: (_) => throw StateError('filter'),
        attributes: (_, _, _) => throw StateError('attributes'),
        includeUnnamedRoutes: true,
        onInstrumentationError: (error, _) => diagnostics.add(error),
      ),
    );

    filtered.didPush(_route('/filtered'), null);
    failing.didPush(_route('/safe'), null);
    await traces.shutdown();

    expect(spans.spans, hasLength(1));
    expect(diagnostics, hasLength(3));
  });

  test('can disable gestures and breadcrumbs', () async {
    final spans = _MemorySpanExporter();
    final traces = TracerProvider(processor: SimpleSpanProcessor(spans));
    final observer = ObsiNavigatorObserver(
      tracer: traces.tracer,
      options: const ObsiNavigatorObserverOptions(
        traceUserGestures: false,
        recordBreadcrumbs: false,
      ),
    );
    final route = _route('/screen');

    await ErrorScope().run(() async {
      observer
        ..didStartUserGesture(route, null)
        ..didStopUserGesture();
      expect(Errors.currentScope.breadcrumbs, isEmpty);
    });
    await traces.shutdown();
    expect(spans.spans, isEmpty);
  });
}

bool _neverInstrument(Route<dynamic> _) => false;

Route<void> _route(String name) => PageRouteBuilder<void>(
  settings: RouteSettings(name: name),
  pageBuilder: (_, _, _) => const SizedBox(),
);

final class _MemorySpanExporter implements SpanExporter {
  final List<SpanData> spans = [];

  @override
  Future<void> export(List<SpanData> batch) async => spans.addAll(batch);

  @override
  Future<void> shutdown() async {}
}

final class _MemoryMetricExporter implements MetricExporter {
  final List<MetricData> metrics = [];

  @override
  Future<void> export(List<MetricData> batch) async => metrics.addAll(batch);

  @override
  Future<void> shutdown() async {}
}

final class _MemoryLogExporter implements LogExporter {
  final List<LogRecord> records = [];

  @override
  Future<void> export(List<LogRecord> batch) async => records.addAll(batch);

  @override
  Future<void> shutdown() async {}
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
