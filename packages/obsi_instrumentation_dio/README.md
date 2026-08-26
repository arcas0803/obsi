# obsi_instrumentation_dio

[![pub package](https://img.shields.io/pub/v/obsi_instrumentation_dio.svg)](https://pub.dev/packages/obsi_instrumentation_dio)
[![CI](https://github.com/arcas0803/obsi/actions/workflows/ci.yml/badge.svg)](https://github.com/arcas0803/obsi/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](https://github.com/arcas0803/obsi/blob/main/LICENSE)

`obsi_instrumentation_dio` instruments Dio requests with client spans, W3C
trace context, baggage, and OpenTelemetry-compatible HTTP duration metrics.
The interceptor is concurrency-safe and creates one span for each request
attempt.

The package requires [`obsi`](https://pub.dev/packages/obsi), which owns the
tracer, meter, exporters, sampling, privacy policy, and shutdown lifecycle.

## Installation

```sh
dart pub add obsi obsi_instrumentation_dio dio
```

```dart
import 'package:dio/dio.dart';
import 'package:obsi/obsi.dart';
import 'package:obsi_instrumentation_dio/obsi_instrumentation_dio.dart';
```

## How it works

Add one `ObsiDioInterceptor` to a Dio instance. It observes the normal Dio
request, response, and error callbacks without changing the response model.

```text
Dio request → ObsiDioInterceptor → HttpClientAdapter
                    │
                    ├─ client span + W3C headers
                    └─ http.client.request.duration
```

## Basic usage

```dart
final dio = Dio();
dio.interceptors.add(ObsiDioInterceptor(
  tracer: Obsi.tracer,
  meter: Obsi.meter('http.client'),
));

final response = await dio.get<Map<String, Object?>>(
  'https://api.example.com/users',
);
```

Active trace context and baggage are injected into request headers. When a
meter is supplied, request duration is recorded in seconds using recommended
histogram buckets.

## Filtering and customization

```dart
dio.interceptors.add(ObsiDioInterceptor(
  tracer: Obsi.tracer,
  meter: Obsi.meter('http.client'),
  options: ObsiDioOptions(
    shouldInstrument: (request) =>
        request.uri.host != 'collector.internal',
    spanNameBuilder: (request) => '${request.method} catalog-api',
    requestAttributes: (request) => {
      'app.http.retry': request.extra['retry'] ?? 0,
    },
    responseAttributes: (response) => {
      'app.response.cached': response.headers.value('x-cache') == 'HIT',
    },
    onInstrumentationError: diagnostics,
  ),
));
```

Callbacks and propagators are failure-isolated. Invalid custom attributes are
reported through `onInstrumentationError` and ignored rather than breaking the
request. Install only one Obsi interceptor on a Dio instance; duplicate
interceptors are detected and do not create nested duplicate spans.

## HTTP semantics, failures, and privacy

Spans and metrics use stable method, URL, server, status, and `error.type`
attributes. Unknown methods normalize to `_OTHER`, with the original value kept
on the span. Credentials, query values, and fragments are redacted by default;
`urlSanitizer` can enforce a stricter policy.

HTTP failures and transport failures preserve the original `DioException`.
Obsi records the standard `error.type` plus `dio.error.type`, exposed through
`ObsiDioAttributes`. Intentional cancellation ends the span without marking the
operation as an application failure.

## Streaming requests

For `ResponseType.stream`, `traceResponseBody: true` keeps the span open until
the body completes, fails, or is cancelled. This measures the complete
operation rather than time-to-headers.

```dart
final interceptor = ObsiDioInterceptor(
  options: const ObsiDioOptions(traceResponseBody: false),
);
```

Set it to false only when header latency is the intended measurement boundary.

## Ownership and lifecycle

The interceptor does not own `Dio`, its adapter, the tracer, or the meter.
Remove it through Dio's normal interceptor lifecycle if the client outlives the
instrumentation. Stop creating requests before `await Obsi.shutdown()`.

Do not instrument requests sent by `obsi_exporter_otlp`; exporter recursion can
create an unbounded telemetry loop.

## API inventory

| Concept | Public API | When to use it |
| --- | --- | --- |
| Dio instrumentation | `ObsiDioInterceptor` | Add tracing, propagation, and metrics to a Dio instance. |
| Configuration | `ObsiDioOptions` | Configure filters, names, attributes, URL privacy, stream boundaries, and diagnostics. |
| Package attributes | `ObsiDioAttributes` | Read the stable `dio.error.type` attribute name. |
| Request filter | `DioRequestPredicate` | Exclude collector, health-check, or intentionally unobserved requests. |
| Span naming | `DioClientSpanNameBuilder` | Produce a stable application-specific name. |
| Request metadata | `DioRequestAttributeBuilder` | Add validated attributes before request dispatch. |
| Response metadata | `DioResponseAttributeBuilder` | Add validated attributes from a Dio response. |
| URL privacy | `DioUrlSanitizer` | Replace the default credential, query, and fragment sanitization. |

Only declarations exported by
`package:obsi_instrumentation_dio/obsi_instrumentation_dio.dart` are stable.
See [`obsi`](https://pub.dev/packages/obsi) for configuration, sampling,
semantic constants, redaction, and shutdown. Licensed under the
[MIT License](https://github.com/arcas0803/obsi/blob/main/LICENSE).
