import 'dart:async';

import 'package:obsi/obsi.dart';
import 'package:obsi_error_sentry/obsi_error_sentry.dart';
import 'package:sentry/sentry.dart';
import 'package:test/test.dart';

void main() {
  test('maps an Obsi error to an isolated Sentry scope', () async {
    late Object captured;
    late Scope mappedScope;
    final exporter = SentryErrorExporter(
      capture: (exception, {stackTrace, message, withScope}) async {
        captured = exception;
        mappedScope = Scope(SentryOptions());
        await withScope!(mappedScope);
        return SentryId.newId();
      },
    );

    await exporter.export(_report());

    expect(captured, isA<StateError>());
    expect(mappedScope.level, SentryLevel.fatal);
    expect(mappedScope.tags['environment'], 'test');
    expect(mappedScope.tags['obsi.trace_id'], 'a' * 32);
    expect(mappedScope.user?.id, 'user-1');
    expect(mappedScope.fingerprint, ['checkout', 'state']);
    expect(mappedScope.breadcrumbs.single.category, 'log');
    expect(mappedScope.attachments.single.filename, 'state.txt');
    expect(mappedScope.contexts['request'], isNotNull);
    expect(mappedScope.tags['obsi.integration'], 'obsi_error_sentry');
    expect(exporter.exportedReports, 1);
  });

  test('treats an empty Sentry event id as rejected delivery', () async {
    final exporter = SentryErrorExporter(
      capture: (_, {stackTrace, message, withScope}) async =>
          const SentryId.empty(),
    );

    await expectLater(
      exporter.export(_report()),
      throwsA(isA<SentryDeliveryRejectedException>()),
    );

    expect(exporter.exportedReports, 0);
    expect(exporter.rejectedReports, 1);
  });

  test('forceFlush waits for in-flight captures', () async {
    final capture = Completer<SentryId>();
    final exporter = SentryErrorExporter(
      capture: (_, {stackTrace, message, withScope}) => capture.future,
    );
    final export = exporter.export(_report());
    var flushed = false;
    final flush = exporter.forceFlush().then((_) => flushed = true);

    await Future<void>.delayed(Duration.zero);
    expect(flushed, isFalse);
    capture.complete(SentryId.newId());
    await Future.wait([export, flush]);
    expect(flushed, isTrue);
  });

  test(
    'shutdown is idempotent, optionally closes Sentry, and is terminal',
    () async {
      var closes = 0;
      final exporter = SentryErrorExporter(
        capture: (_, {stackTrace, message, withScope}) async =>
            SentryId.newId(),
        close: () async => closes++,
        closeOnShutdown: true,
      );

      await Future.wait([exporter.shutdown(), exporter.shutdown()]);

      expect(closes, 1);
      await expectLater(exporter.export(_report()), throwsA(isA<StateError>()));
    },
  );

  test(
    'can accept an empty id when the host SDK intentionally samples',
    () async {
      final exporter = SentryErrorExporter(
        capture: (_, {stackTrace, message, withScope}) async =>
            const SentryId.empty(),
        requireEventId: false,
      );

      await exporter.export(_report());

      expect(exporter.exportedReports, 1);
      expect(exporter.rejectedReports, 0);
    },
  );
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
  contexts: const {
    'request': {'route': '/checkout'},
  },
  fingerprint: const ['checkout', 'state'],
  breadcrumbs: [
    ErrorBreadcrumb(
      timestamp: DateTime.utc(2026),
      category: 'log',
      message: 'starting checkout',
    ),
  ],
  attachments: [
    ErrorAttachment(filename: 'state.txt', bytes: const [1, 2, 3]),
  ],
  user: ErrorUser(id: 'user-1'),
  spanContext: SpanContext(traceId: 'a' * 32, spanId: 'b' * 16, sampled: true),
  resource: Resource(const {'service.name': 'shop'}),
  instrumentationScope: InstrumentationScope('shop.errors'),
);
