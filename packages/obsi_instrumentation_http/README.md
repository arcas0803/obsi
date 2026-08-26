# obsi_instrumentation_http

[![pub package](https://img.shields.io/pub/v/obsi_instrumentation_http.svg)](https://pub.dev/packages/obsi_instrumentation_http)
[![CI](https://github.com/arcas0803/obsi/actions/workflows/ci.yml/badge.svg)](https://github.com/arcas0803/obsi/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](https://github.com/arcas0803/obsi/blob/main/LICENSE)

`obsi_instrumentation_http` instruments outbound requests made with
`package:http`. It creates client spans, injects W3C trace context and baggage,
and optionally records OpenTelemetry-compatible HTTP duration metrics.

The package requires [`obsi`](https://pub.dev/packages/obsi). The core owns the
tracer, meter, sampling, exporters, and application lifecycle; this package
only wraps an HTTP client.

## Installation

```sh
dart pub add obsi obsi_instrumentation_http http
```

```dart
import 'package:http/http.dart' as http;
import 'package:obsi/obsi.dart';
import 'package:obsi_instrumentation_http/obsi_instrumentation_http.dart';
```

## How it works

`ObsiHttpClient` is an `http.BaseClient`. Existing `get`, `post`, `send`, and
other `package:http` calls continue to work through it.

```text
application → ObsiHttpClient → wrapped http.Client → remote service
                    │
                    ├─ client span + W3C headers
                    └─ http.client.request.duration
```

One span is created for each request. The span remains open until the response
body completes, fails, or is cancelled—not merely until response headers arrive.

## Basic usage

```dart
final client = ObsiHttpClient(
  http.Client(),
  tracer: Obsi.tracer,
  meter: Obsi.meter('http.client'),
);

try {
  final response = await client.get(
    Uri.parse('https://api.example.com/users'),
  );
  handle(response);
} finally {
  client.close();
}
```

When a meter is supplied, the client records
`http.client.request.duration` in seconds with recommended explicit histogram
buckets. Trace and baggage headers are injected from the current Obsi context.

## Filtering and custom attributes

Exporter and health-check traffic should usually be excluded. Custom callbacks
can add low-cardinality application context:

```dart
final client = ObsiHttpClient(
  sharedClient,
  tracer: Obsi.tracer,
  meter: Obsi.meter('http.client'),
  options: ObsiHttpClientOptions(
    shouldInstrument: (request) =>
        request.url.host != 'collector.internal',
    spanNameBuilder: (request) => '${request.method} external-api',
    requestAttributes: (request) => {
      'app.http.retry': 0,
      'app.remote.system': 'catalog',
    },
    responseAttributes: (request, response) => {
      'app.response.cached': response.headers['x-cache'] == 'HIT',
    },
    closeInnerClient: false,
    onInstrumentationError: diagnostics,
  ),
);
```

Callback and propagator failures are reported through
`onInstrumentationError` and never replace the HTTP response or error. Custom
attributes still pass through Obsi validation and provider redaction.

## HTTP semantics and privacy

The instrumentation emits stable HTTP semantic attributes for method,
sanitized URL, server address and port, response status, and `error.type`.
Unknown methods are normalized to `_OTHER` while the original method is kept on
the span.

URL credentials, query values, and fragments are redacted by default. A custom
`urlSanitizer` can apply stricter application rules. It must never return
secrets merely because the destination backend is trusted.

HTTP `4xx` and `5xx` responses set client error status. Transport and response
stream failures are recorded with their stack trace and rethrown unchanged.

## Streaming and ownership

The returned body stream forwards pause, resume, cancellation, data, and errors.
The span and duration metric end exactly once when that stream reaches a
terminal state.

By default, closing `ObsiHttpClient` also closes the wrapped client. Set
`closeInnerClient: false` when the caller owns a shared client. Closing this
wrapper never shuts down the Obsi tracer or meter; finish application telemetry
with `await Obsi.shutdown()`.

## API inventory

| Concept | Public API | When to use it |
| --- | --- | --- |
| Instrumented client | `ObsiHttpClient` | Replace or wrap an `http.Client` to trace outbound traffic. |
| Configuration | `ObsiHttpClientOptions` | Configure filtering, naming, custom attributes, sanitization, diagnostics, and ownership. |
| Request filter | `HttpRequestPredicate` | Exclude collector, health-check, or intentionally unobserved traffic. |
| Span naming | `HttpClientSpanNameBuilder` | Apply a stable application-specific span name. |
| Request metadata | `HttpRequestAttributeBuilder` | Add validated attributes known before sending. |
| Response metadata | `HttpResponseAttributeBuilder` | Add validated attributes after headers arrive. |
| URL privacy | `HttpUrlSanitizer` | Replace the default credential, query, and fragment redaction policy. |

Only declarations exported by
`package:obsi_instrumentation_http/obsi_instrumentation_http.dart` are stable.
See [`obsi`](https://pub.dev/packages/obsi) for providers, sampling, semantic
constants, redaction, and shutdown. Licensed under the
[MIT License](https://github.com/arcas0803/obsi/blob/main/LICENSE).
