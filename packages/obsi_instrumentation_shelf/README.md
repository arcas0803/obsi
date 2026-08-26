# obsi_instrumentation_shelf

[![pub package](https://img.shields.io/pub/v/obsi_instrumentation_shelf.svg)](https://pub.dev/packages/obsi_instrumentation_shelf)
[![CI](https://github.com/arcas0803/obsi/actions/workflows/ci.yml/badge.svg)](https://github.com/arcas0803/obsi/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](https://github.com/arcas0803/obsi/blob/main/LICENSE)

`obsi_instrumentation_shelf` instruments inbound Shelf requests. It extracts
W3C trace context and baggage, creates server spans, and optionally records
OpenTelemetry-compatible request-duration metrics.

The package requires [`obsi`](https://pub.dev/packages/obsi). The core provides
the tracer, meter, exporters, sampling, error management, and lifecycle.

## Installation

```sh
dart pub add obsi obsi_instrumentation_shelf shelf
```

```dart
import 'package:obsi/obsi.dart';
import 'package:obsi_instrumentation_shelf/obsi_instrumentation_shelf.dart';
import 'package:shelf/shelf.dart';
```

## How it works

The middleware surrounds a Shelf handler and keeps context current throughout
its asynchronous execution and response body stream.

```text
request → obsiMiddleware → handler → response stream
              │
              ├─ extract W3C context and baggage
              ├─ server span
              └─ http.server.request.duration
```

## Basic usage

```dart
final handler = const Pipeline()
    .addMiddleware(obsiMiddleware(
      tracer: Obsi.tracer,
      meter: Obsi.meter('http.server'),
      routeResolver: (request) => switch (request.url.path) {
        'users' => '/users',
        _ => '/unknown',
      },
    ))
    .addHandler((request) => Response.ok('ok'));
```

Incoming `traceparent` and `tracestate` continue a distributed trace. Incoming
baggage is available through `Baggage.current` inside the handler.

## Route templates and cardinality

`routeResolver` should return a low-cardinality route template such as
`/users/:id`, not the raw path `/users/87421`. The template is used in span
names and metric attributes, so raw identifiers would create excessive
cardinality.

```dart
obsiMiddleware(
  routeResolver: router.resolveTemplate,
  options: ObsiShelfOptions(
    shouldInstrument: (request) => request.url.path != 'health',
    requestAttributes: (request) => {
      'app.tenant.type': 'public',
    },
    responseAttributes: (request, response) => {
      'app.response.cached': response.headers['x-cache'] == 'HIT',
    },
    onInstrumentationError: diagnostics,
  ),
);
```

Route, filter, attribute, and propagator callbacks are failure-isolated. Their
errors are reported through `onInstrumentationError` without replacing the
application response.

## HTTP semantics and failures

Server spans and metrics use stable method, scheme, route, status, and
`error.type` attributes. Query values are redacted. Unknown methods normalize
to `_OTHER`, while the original method remains available on the span.

Server `4xx` responses leave span status unset because they normally represent
valid server handling of a client error. Server `5xx`, handler exceptions, and
response-stream failures set error status. Original errors and stack traces are
re-thrown unchanged.

## Response streams

By default, the span remains open until the response body completes, fails, or
is cancelled. This measures the full server operation.

```dart
obsiMiddleware(
  options: const ObsiShelfOptions(traceResponseBody: false),
);
```

Set `traceResponseBody` to false only when handler-return latency, rather than
complete response duration, is the intended boundary.

## Ownership and graceful shutdown

The middleware owns neither the Shelf server, handler, response stream, tracer,
nor meter. During shutdown, stop accepting requests, let active requests drain,
then call `await Obsi.shutdown()`.

## API inventory

| Concept | Public API | When to use it |
| --- | --- | --- |
| Shelf instrumentation | `obsiMiddleware` | Add server traces, W3C extraction, baggage, and metrics to a Shelf pipeline. |
| Configuration | `ObsiShelfOptions` | Configure filtering, custom attributes, response-stream boundaries, and diagnostics. |
| Request filter | `ShelfRequestPredicate` | Exclude health checks or intentionally unobserved routes. |
| Request attributes | `ShelfAttributeBuilder` | Add validated application metadata before the handler runs. |
| Response attributes | `ShelfResponseAttributeBuilder` | Add validated metadata after the handler returns. |

Only declarations exported by
`package:obsi_instrumentation_shelf/obsi_instrumentation_shelf.dart` are stable.
See [`obsi`](https://pub.dev/packages/obsi) for providers, sampling, semantic
constants, privacy, and lifecycle. Licensed under the
[MIT License](https://github.com/arcas0803/obsi/blob/main/LICENSE).
