import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:obsi/obsi.dart';
import 'package:obsi_error_crashlytics/obsi_error_crashlytics.dart';
import 'package:obsi_flutter/obsi_flutter.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  tearDown(Errors.disable);

  test('maps report fields and records fatal errors', () async {
    final client = _FakeCrashlyticsClient();
    final exporter = CrashlyticsErrorExporter(client: client);

    await exporter.export(_report());
    await exporter.forceFlush();

    expect(client.userIdentifier, 'user-1');
    expect(client.keys['obsi.fatal'], isTrue);
    expect(client.keys['obsi.trace_id'], 'a' * 32);
    expect(client.logs.single, contains('starting checkout'));
    expect(client.exceptions.single, isA<StateError>());
    expect(client.fatal, isTrue);
    expect(exporter.exportedReports, 1);
  });

  test('integration can be installed and restored', () {
    final integration = ObsiFlutterErrorIntegration();
    integration.install(
      preserveExistingHandlers: false,
      requireConfiguredManager: false,
    );
    expect(integration.isInstalled, isTrue);
    integration.uninstall();
    expect(integration.isInstalled, isFalse);
  });

  test(
    'clears stale global keys and user identifiers between reports',
    () async {
      final client = _FakeCrashlyticsClient();
      final exporter = CrashlyticsErrorExporter(client: client);

      await exporter.export(_report());
      await exporter.export(
        _report().copyWith(
          clearUser: true,
          tags: const {},
          attributes: const {},
        ),
      );

      expect(client.userIdentifier, '');
      expect(client.keys['tag.environment'], '');
      expect(client.keys['attribute.cart.items'], '');
      expect(client.keys['obsi.error_id'], 'error-1');
    },
  );

  test(
    'limits keys and values by UTF-8 bytes without splitting Unicode',
    () async {
      final client = _FakeCrashlyticsClient();
      final exporter = CrashlyticsErrorExporter(client: client);
      final longKey = 'key.${'á' * 700}';
      final longValue = '🚀' * 400;

      await exporter.export(
        _report().copyWith(attributes: {longKey: longValue}),
      );

      for (final entry in client.keys.entries) {
        expect(utf8.encode(entry.key).length, lessThanOrEqualTo(1024));
        if (entry.value is String) {
          expect(
            utf8.encode(entry.value as String).length,
            lessThanOrEqualTo(1024),
          );
        }
      }
    },
  );

  test('a failed export does not poison the serialized queue', () async {
    final client = _FakeCrashlyticsClient()..failNextKey = true;
    final exporter = CrashlyticsErrorExporter(client: client);

    await expectLater(exporter.export(_report()), throwsStateError);
    await exporter.export(_report());

    expect(exporter.failedReports, 1);
    expect(exporter.exportedReports, 1);
    expect(client.exceptions, hasLength(1));
  });

  test('forceFlush can send unsent reports and shutdown is terminal', () async {
    final client = _FakeCrashlyticsClient();
    final exporter = CrashlyticsErrorExporter(
      client: client,
      sendUnsentReportsOnFlush: true,
    );

    await exporter.export(_report());
    await Future.wait([exporter.shutdown(), exporter.shutdown()]);

    expect(client.unsentReportSends, 1);
    await expectLater(exporter.export(_report()), throwsA(isA<StateError>()));
  });

  test(
    'integration captures Flutter and platform errors with context',
    () async {
      final memory = _MemoryErrorExporter();
      final manager = ErrorManager(exporter: memory, processors: const []);
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
      expect(memory.reports, hasLength(2));
      expect(memory.reports[0].mechanism, ErrorMechanism.flutterFramework);
      expect(memory.reports[0].contexts['flutter']?['library'], 'checkout');
      expect(memory.reports[1].mechanism, ErrorMechanism.platformDispatcher);
      integration.uninstall();
      await manager.shutdown();
    },
  );

  test('prevents conflicting global integrations', () {
    final first = ObsiFlutterErrorIntegration()
      ..install(
        preserveExistingHandlers: false,
        requireConfiguredManager: false,
      );
    final second = ObsiFlutterErrorIntegration();
    addTearDown(() {
      if (first.isInstalled) first.uninstall();
    });

    expect(
      () => second.install(requireConfiguredManager: false),
      throwsStateError,
    );
    first.uninstall();
  });

  test('validates Crashlytics limits eagerly', () {
    final client = _FakeCrashlyticsClient();
    expect(
      () => CrashlyticsErrorExporter(client: client, maxCustomKeys: 0),
      throwsArgumentError,
    );
    expect(
      () => CrashlyticsErrorExporter(client: client, maxCustomKeys: 65),
      throwsArgumentError,
    );
    expect(
      () => CrashlyticsErrorExporter(client: client, maxValueBytes: 0),
      throwsArgumentError,
    );
    expect(
      () => CrashlyticsErrorExporter(client: client, maxBreadcrumbs: -1),
      throwsArgumentError,
    );
  });

  test('keeps truncated custom keys unique and bounds their count', () async {
    final client = _FakeCrashlyticsClient();
    final exporter = CrashlyticsErrorExporter(
      client: client,
      maxCustomKeys: 10,
      maxValueBytes: 64,
    );
    final prefix = 'shared.${'x' * 100}';

    await exporter.export(
      _report().copyWith(
        attributes: {
          '$prefix.one': 'one',
          '$prefix.two': 'two',
          for (var index = 0; index < 20; index++) 'extra.$index': index,
        },
      ),
    );

    expect(client.keys.length, 10);
    expect(client.keys.keys.toSet(), hasLength(10));
    expect(
      client.keys.keys.every((key) => utf8.encode(key).length <= 64),
      isTrue,
    );
  });

  test('exports only the newest bounded breadcrumbs in order', () async {
    final client = _FakeCrashlyticsClient();
    final exporter = CrashlyticsErrorExporter(
      client: client,
      maxBreadcrumbs: 2,
    );
    final report = _report().copyWith(
      breadcrumbs: [
        for (var index = 0; index < 4; index++)
          ErrorBreadcrumb(
            timestamp: DateTime.utc(2026),
            category: 'test',
            message: '$index',
          ),
      ],
    );

    await exporter.export(report);

    expect(client.logs, hasLength(2));
    expect(client.logs[0], contains('2'));
    expect(client.logs[1], contains('3'));
  });

  test('requires an ErrorManager before installing by default', () {
    Errors.disable();
    expect(ObsiFlutterErrorIntegration().install, throwsStateError);
  });

  test('preserves existing Flutter and platform handlers', () async {
    final originalFlutter = FlutterError.onError;
    final originalPlatform = PlatformDispatcher.instance.onError;
    var flutterCalls = 0;
    var platformCalls = 0;
    FlutterError.onError = (_) => flutterCalls++;
    PlatformDispatcher.instance.onError = (_, _) {
      platformCalls++;
      return false;
    };
    final manager = ErrorManager(
      exporter: _MemoryErrorExporter(),
      processors: const [],
    );
    Errors.configure(manager);
    final integration = ObsiFlutterErrorIntegration()..install();
    addTearDown(() {
      if (integration.isInstalled) integration.uninstall();
      FlutterError.onError = originalFlutter;
      PlatformDispatcher.instance.onError = originalPlatform;
    });

    FlutterError.onError!(
      FlutterErrorDetails(exception: StateError('framework')),
    );
    final platformResult = PlatformDispatcher.instance.onError!(
      StateError('platform'),
      StackTrace.current,
    );
    await manager.forceFlush();
    integration.uninstall();

    expect(flutterCalls, 1);
    expect(platformCalls, 1);
    expect(platformResult, isFalse);
    expect(FlutterError.onError, isNot(same(originalFlutter)));
    expect(PlatformDispatcher.instance.onError, isNot(same(originalPlatform)));
    FlutterError.onError = originalFlutter;
    PlatformDispatcher.instance.onError = originalPlatform;
    await manager.shutdown();
  });
}

ErrorReport _report() => ErrorReport(
  id: const ErrorId('error-1'),
  timestamp: DateTime.utc(2026),
  exception: StateError('broken'),
  message: 'Bad state: broken',
  stackTrace: StackTrace.current,
  severity: ErrorSeverity.fatal,
  fatal: true,
  handled: false,
  mechanism: ErrorMechanism.zone,
  reason: 'checkout failed',
  attributes: const {'cart.items': 2},
  tags: const {'environment': 'test'},
  contexts: const {},
  fingerprint: const [],
  breadcrumbs: [
    ErrorBreadcrumb(
      timestamp: DateTime.utc(2026),
      category: 'log',
      message: 'starting checkout',
    ),
  ],
  attachments: const [],
  user: ErrorUser(id: 'user-1'),
  spanContext: SpanContext(traceId: 'a' * 32, spanId: 'b' * 16, sampled: true),
  resource: Resource(const {'service.name': 'shop'}),
  instrumentationScope: InstrumentationScope('shop.errors'),
);

final class _FakeCrashlyticsClient implements CrashlyticsClient {
  final Map<String, Object> keys = {};
  final List<String> logs = [];
  String? userIdentifier;
  final List<Object> exceptions = [];
  bool? fatal;
  bool failNextKey = false;
  int unsentReportSends = 0;

  @override
  Future<void> log(String message) async => logs.add(message);

  @override
  Future<void> recordError(
    Object exception,
    StackTrace? stackTrace, {
    Object? reason,
    Iterable<Object> information = const [],
    bool fatal = false,
  }) async {
    exceptions.add(exception);
    this.fatal = fatal;
  }

  @override
  Future<void> sendUnsentReports() async => unsentReportSends++;

  @override
  Future<void> setCustomKey(String key, Object value) async {
    if (failNextKey) {
      failNextKey = false;
      throw StateError('key failed');
    }
    keys[key] = value;
  }

  @override
  Future<void> setUserIdentifier(String identifier) async {
    userIdentifier = identifier;
  }
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
