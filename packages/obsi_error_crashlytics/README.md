# obsi_error_crashlytics

[![pub package](https://img.shields.io/pub/v/obsi_error_crashlytics.svg)](https://pub.dev/packages/obsi_error_crashlytics)
[![CI](https://github.com/arcas0803/obsi/actions/workflows/ci.yml/badge.svg)](https://github.com/arcas0803/obsi/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](https://github.com/arcas0803/obsi/blob/main/LICENSE)

`obsi_error_crashlytics` delivers error reports created by
[`obsi`](https://pub.dev/packages/obsi) to Firebase Crashlytics. It maps Obsi
errors, scoped context, breadcrumbs, and trace correlation onto the native
Crashlytics SDK.

The `obsi` core owns capture policy, sanitization, deduplication, sampling, and
rate limiting. Use [`obsi_flutter`](https://pub.dev/packages/obsi_flutter) when
Flutter framework and root-isolate errors should be captured automatically.

## Installation and native setup

Run `flutterfire configure`, add valid Android and iOS Firebase configuration,
and initialize Firebase before creating the exporter.

```sh
flutter pub add obsi obsi_flutter obsi_error_crashlytics firebase_core
```

```dart
import 'package:firebase_core/firebase_core.dart';
import 'package:obsi/obsi.dart';
import 'package:obsi_error_crashlytics/obsi_error_crashlytics.dart';
import 'package:obsi_flutter/obsi_flutter.dart';
```

## How it works

Crashlytics custom keys and user identity are global mutable state. The exporter
therefore serializes reports and clears keys that belonged to a previous report
before sending the next one.

```text
exception → ErrorManager → CrashlyticsErrorExporter → Firebase Crashlytics
                              │
                              ├─ serialized global custom keys
                              ├─ user identifier and breadcrumbs
                              └─ fatality, resource, trace and span IDs
```

## Complete configuration

```dart
await Firebase.initializeApp();

final errors = ErrorManager(
  resource: Resource({
    'service.name': 'checkout-mobile',
    'service.version': '1.0.0',
  }),
  exporter: CrashlyticsErrorExporter(
    sendUnsentReportsOnFlush: true,
  ),
);

Obsi.configure(ObsiProvider(errors: errors));
final flutterErrors = ObsiFlutterErrorIntegration()..install();
runApp(const App());

// Call from a controlled teardown path when the host provides one.
Future<void> shutdownTelemetry() async {
  flutterErrors.uninstall();
  await Obsi.shutdown();
}
```

In a normal mobile application, process termination may not provide an
asynchronous teardown window. Configure Obsi during startup and flush at every
controlled lifecycle boundary available to the host application.

## Report mapping

The exporter maps fatality, reason, user ID, resource data, trace and span IDs,
instrumentation scope, tags, attributes, contexts, and fingerprints to custom
keys. Obsi breadcrumbs become Crashlytics log entries.

Crashlytics limits custom keys and values. The exporter enforces those limits
by UTF-8 bytes without splitting a Unicode character:

```dart
final exporter = CrashlyticsErrorExporter(
  maxCustomKeys: 64,
  maxValueBytes: 1024,
  maxBreadcrumbs: 100,
  sendUnsentReportsOnFlush: false,
);
```

`maxCustomKeys` must be between 1 and 64, `maxValueBytes` must be positive, and
`maxBreadcrumbs` cannot be negative. Invalid values throw `ArgumentError`
during startup.

## Delivery health and failures

`exportedReports` counts completed deliveries and `failedReports` counts failed
Crashlytics operations. A failure does not poison the serialized queue; later
reports are still attempted.

`sendUnsentReportsOnFlush` controls whether `forceFlush()` asks Crashlytics to
send locally retained reports. This can affect user consent and network policy,
so enable it only when appropriate for the host application.

## Privacy and production verification

Crashlytics custom keys and logs may contain user data. Sanitize reports through
the processors in `obsi` and avoid raw tokens, email addresses, request bodies,
or unique values that are unnecessary for diagnosis.

Release validation exercises local Android and iOS integration hosts without
transmitting real user data. Before releasing an application, send a deliberate
error or test crash from a non-debug build and confirm symbolication and
metadata in the actual Firebase project.

## Ownership and shutdown

The exporter owns neither Firebase nor Flutter's global error handlers.
`shutdown()` drains the serialized queue and becomes terminal; later exports
complete with `StateError`. `ObsiFlutterErrorIntegration` must be uninstalled
separately when handlers are replaced or during controlled teardown.

## API inventory

| Concept | Public API | When to use it |
| --- | --- | --- |
| Crashlytics delivery | `CrashlyticsErrorExporter` | Connect an Obsi `ErrorManager` to Firebase Crashlytics. |
| Client boundary | `CrashlyticsClient` | Inject a test double or a custom Crashlytics access layer. |
| Firebase adapter | `FirebaseCrashlyticsClient` | Use the default production adapter around `FirebaseCrashlytics`. |

Only declarations exported by
`package:obsi_error_crashlytics/obsi_error_crashlytics.dart` are stable. See
[`obsi`](https://pub.dev/packages/obsi) for error capture, scopes, processors,
privacy, and lifecycle. Licensed under the
[MIT License](https://github.com/arcas0803/obsi/blob/main/LICENSE).
