# obsi_error_sentry

[![pub package](https://img.shields.io/pub/v/obsi_error_sentry.svg)](https://pub.dev/packages/obsi_error_sentry)
[![CI](https://github.com/arcas0803/obsi/actions/workflows/ci.yml/badge.svg)](https://github.com/arcas0803/obsi/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](https://github.com/arcas0803/obsi/blob/main/LICENSE)

`obsi_error_sentry` delivers error reports created by
[`obsi`](https://pub.dev/packages/obsi) through the Sentry Dart SDK. It maps
Obsi's vendor-neutral report model to an isolated Sentry event scope.

The `obsi` core remains responsible for capturing exceptions, managing
zone-local scopes, sanitizing data, deduplicating reports, sampling, rate
limiting, and correlating errors with traces.

## Installation

```sh
dart pub add obsi obsi_error_sentry sentry
```

```dart
import 'package:obsi/obsi.dart';
import 'package:obsi_error_sentry/obsi_error_sentry.dart';
import 'package:sentry/sentry.dart';
```

## How it works

```text
exception → ErrorManager → error processors → SentryErrorExporter → Sentry
                │
                └─ user, tags, contexts, breadcrumbs, attachments, trace IDs
```

Every report uses an isolated Sentry scope. Report-specific user data, tags, or
breadcrumbs do not mutate the scope of another concurrent capture.

## Basic configuration

```dart
await Sentry.init((options) {
  options.dsn = sentryDsn;
  options.environment = 'production';
});

final errors = ErrorManager(
  resource: Resource({
    'service.name': 'checkout-api',
    'service.version': '1.0.0',
  }),
  exporter: SentryErrorExporter(closeOnShutdown: true),
);

Obsi.configure(ObsiProvider(errors: errors));

try {
  await Errors.guard(runApplication);
} finally {
  await Obsi.shutdown();
}
```

Set `closeOnShutdown: true` only when this Obsi installation owns the global
Sentry SDK. If another library or application layer owns Sentry, leave the
default false and close it there.

## Enriching an event

```dart
await Errors.withScope(
  () async {
    Errors.addBreadcrumb(ErrorBreadcrumb(
      timestamp: DateTime.now(),
      category: 'payment',
      message: 'Authorization requested',
      data: {'payment.method': 'card'},
    ));

    try {
      await authorizePayment();
    } catch (error, stackTrace) {
      await Errors.captureException(
        error,
        stackTrace: stackTrace,
        reason: 'Payment provider rejected the request',
        tags: {'feature': 'checkout'},
        contexts: {
          'payment': {'currency': 'EUR', 'retry': 0},
        },
        fingerprint: ['payment-provider', 'authorization'],
      );
    }
  },
  user: ErrorUser(id: 'customer-42'),
  tags: {'tenant': 'acme'},
);
```

The exporter maps exception, stack trace, message, severity, user, fingerprint,
tags, contexts, breadcrumbs, attachments, Obsi resource and instrumentation
scope, and the active trace/span identifiers.

## Delivery acceptance

Sentry returns an event ID when it accepts a capture. `requireEventId` defaults
to true. An empty ID increments `rejectedReports` and throws
`SentryDeliveryRejectedException`.

```dart
final exporter = SentryErrorExporter(
  requireEventId: true,
  closeOnShutdown: false,
);
```

Set `requireEventId: false` only when intentional Sentry-side sampling should
count as a successful local export. `exportedReports` and `rejectedReports`
provide adapter-level health; Obsi's `ErrorManager` exposes pipeline counters.

## Privacy

User data, tags, contexts, breadcrumbs, and attachments may contain sensitive
information. Configure Obsi error processors before the exporter and review
application-specific fields. The default core pipeline sanitizes common secret
keys, but cannot infer every domain-specific privacy rule.

## Ownership and shutdown

The exporter waits for in-flight captures during `forceFlush()` and
`shutdown()`. Shutdown is idempotent and terminal; later exports complete with
`StateError`. Capture failures retain their original error and stack trace.

For Flutter, initialize `sentry_flutter` normally and add
[`obsi_flutter`](https://pub.dev/packages/obsi_flutter) when Flutter framework
and root-isolate failures should be captured automatically.

## API inventory

| Concept | Public API | When to use it |
| --- | --- | --- |
| Sentry delivery | `SentryErrorExporter` | Connect an Obsi `ErrorManager` to the Sentry Dart SDK. |
| Rejected delivery | `SentryDeliveryRejectedException` | Detect an empty Sentry event ID when acceptance is required. |
| Capture injection | `SentryCapture` | Supply a test double or a custom Sentry hub capture function. |
| Scope mapping | `applyErrorReportToSentryScope` | Reuse Obsi-to-Sentry field mapping in an advanced custom integration. |

Only declarations exported by
`package:obsi_error_sentry/obsi_error_sentry.dart` are stable. See
[`obsi`](https://pub.dev/packages/obsi) for error scopes, processors, capture
APIs, and lifecycle. Licensed under the
[MIT License](https://github.com/arcas0803/obsi/blob/main/LICENSE).
