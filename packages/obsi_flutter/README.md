# obsi_flutter

[![pub package](https://img.shields.io/pub/v/obsi_flutter.svg)](https://pub.dev/packages/obsi_flutter)
[![CI](https://github.com/arcas0803/obsi/actions/workflows/ci.yml/badge.svg)](https://github.com/arcas0803/obsi/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](https://github.com/arcas0803/obsi/blob/main/LICENSE)

`obsi_flutter` connects Flutter runtime behavior to
[`obsi`](https://pub.dev/packages/obsi). It provides:

- global capture for Flutter framework and root-isolate errors;
- navigation spans and breadcrumbs;
- navigation transition counts and visible-screen duration metrics;
- optional structured navigation logs.

The `obsi` core is required and owns providers, exporters, sampling, error
policy, redaction, and shutdown. This package does not choose a backend.

## Installation

```sh
flutter pub add obsi obsi_flutter
```

```dart
import 'package:flutter/material.dart';
import 'package:obsi/obsi.dart';
import 'package:obsi_flutter/obsi_flutter.dart';
```

## How it works

```text
FlutterError.onError ─────────────┐
PlatformDispatcher.onError ───────┼→ Obsi ErrorManager → configured exporter
                                  │
NavigatorObserver callbacks ──────┴→ traces + metrics + breadcrumbs + logs
```

The error integration temporarily owns Flutter's global handlers. The
navigation observer is a normal `NavigatorObserver` and can be attached to
Navigator 1.0 or router packages that accept standard observers.

## Complete configuration

Configure Obsi before installing global Flutter handlers:

```dart
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  final resource = Resource({
    'service.name': 'checkout-mobile',
    'service.version': '1.0.0',
  });
  Obsi.configure(ObsiProvider(
    traces: TracerProvider(
      resource: resource,
      processor: BatchSpanProcessor(const ConsoleSpanExporter()),
    ),
    logs: LoggerProvider(
      resource: resource,
      processor: BatchLogProcessor(const ConsoleLogExporter()),
    ),
    metrics: MeterProvider(
      resource: resource,
      readers: [PeriodicMetricReader(const ConsoleMetricExporter())],
    ),
    errors: ErrorManager(
      resource: resource,
      exporter: const ConsoleErrorExporter(),
    ),
  ));

  ObsiFlutterErrorIntegration().install();
  runApp(const App());
}
```

Production applications normally replace console exporters with OTLP, Sentry,
Crashlytics, or custom exporters.

## Capturing Flutter errors

`ObsiFlutterErrorIntegration` captures:

- `FlutterError.onError` for framework failures;
- `PlatformDispatcher.instance.onError` for otherwise uncaught root-isolate
  asynchronous failures.

```dart
final flutterErrors = ObsiFlutterErrorIntegration();

flutterErrors.install(
  fatal: true,
  preserveExistingHandlers: true,
  requireConfiguredManager: true,
);
```

Existing handlers are preserved and invoked by default. Installing the same
instance again is a no-op. Installing another instance while one owns the
handlers throws `StateError`, preventing handlers from being restored out of
order.

When an application deliberately replaces handlers or has a controlled
teardown path, restore the previous handlers before closing Obsi:

```dart
flutterErrors.uninstall();
await Obsi.shutdown();
```

`uninstall()` is idempotent for its owner and throws `StateError` if another
component changed handler ownership unexpectedly. Secondary isolates require
their own Obsi configuration or `Errors.listenToIsolateErrors()`.

## Observing navigation

Attach one observer to each navigator:

```dart
MaterialApp(
  navigatorObservers: [
    ObsiNavigatorObserver(
      tracer: Obsi.tracer,
      meter: Obsi.meter('navigation'),
      logger: Obsi.logger('navigation'),
      navigatorName: 'root',
    ),
  ],
  home: const HomePage(),
);
```

The observer records push, pop, replace, remove, and user-gesture transitions.
It also counts transitions and records how long the visible screen remained on
top of its navigator.

For nested navigators, install one observer per navigator and assign a distinct
`navigatorName` such as `root`, `checkout`, or `tabs.account`. This keeps screen
duration state separate.

## Route names and privacy

By default, the observer uses `RouteSettings.name` and ignores unnamed routes.
It never falls back to `Route.toString()` because that output can include route
arguments or user data.

```dart
final observer = ObsiNavigatorObserver(
  navigatorName: 'root',
  options: ObsiNavigatorObserverOptions(
    routeNameResolver: (route) => route.settings.name,
    shouldInstrument: (route) => route.settings.name != '/debug',
    attributes: (operation, route, previousRoute) => {
      'app.navigation.source': 'primary',
    },
    includeUnnamedRoutes: false,
    recordBreadcrumbs: true,
    emitLogs: false,
    traceUserGestures: true,
    onInstrumentationError: diagnostics,
  ),
);
```

Prefer stable templates such as `/products/:id` over `/products/87421`.
Callback errors and invalid attributes are reported through
`onInstrumentationError` and never escape into Navigator.

## Breadcrumbs, logs, and metrics

Navigation breadcrumbs are enabled by default and become part of later Obsi
error reports. Structured logs are opt-in because Obsi logs already become
generic log breadcrumbs; enabling both may duplicate similar context.

The observer emits:

| Signal | Name | Meaning |
| --- | --- | --- |
| Counter | `navigation.transition.count` | Number of navigation operations by route and navigator. |
| Histogram | `navigation.screen.visible.duration` | Seconds for which a route remained visible. |
| Span | Navigation operation name | Push, pop, replace, remove, or gesture transition. |
| Breadcrumb | Navigation category | Recent route activity attached to error reports. |

Keep route names and custom metric attributes low-cardinality.

## Ownership and lifecycle

The observer does not own its navigator, tracer, meter, logger, or Obsi
provider. Flutter disposes the observer with the navigator lifecycle.

The error integration owns global handlers only between `install()` and
`uninstall()`. A mobile process may terminate without an asynchronous shutdown
window; flush telemetry at controlled lifecycle boundaries when the host
application provides them.

## API inventory

| Concept | Public API | When to use it |
| --- | --- | --- |
| Global Flutter errors | `ObsiFlutterErrorIntegration` | Capture framework and uncaught root-isolate failures through Obsi. |
| Navigation telemetry | `ObsiNavigatorObserver` | Add traces, metrics, breadcrumbs, and optional logs to a Navigator. |
| Observer configuration | `ObsiNavigatorObserverOptions` | Configure route resolution, filtering, attributes, unnamed routes, gestures, logs, and diagnostics. |
| Route naming | `ObsiRouteNameResolver` | Convert a route into a stable, sanitized name or template. |
| Route filtering | `ObsiRoutePredicate` | Exclude routes from navigation telemetry. |
| Custom metadata | `ObsiNavigationAttributeBuilder` | Add validated attributes for a transition. |
| Navigation attributes | `ObsiNavigationAttributes` | Reference stable attribute names emitted by the observer. |
| Navigation metrics | `ObsiNavigationMetrics` | Reference the transition-count and screen-duration metric names. |

Only declarations exported by `package:obsi_flutter/obsi_flutter.dart` are
stable. The example integration is tested locally on Android and iOS before a
release.

Choose [`obsi_error_sentry`](https://pub.dev/packages/obsi_error_sentry) or
[`obsi_error_crashlytics`](https://pub.dev/packages/obsi_error_crashlytics) for
remote error delivery. See [`obsi`](https://pub.dev/packages/obsi) for signal
configuration, privacy, and lifecycle. Licensed under the
[MIT License](https://github.com/arcas0803/obsi/blob/main/LICENSE).
