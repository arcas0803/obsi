# obsi_exporter_otlp

[![pub package](https://img.shields.io/pub/v/obsi_exporter_otlp.svg)](https://pub.dev/packages/obsi_exporter_otlp)
[![CI](https://github.com/arcas0803/obsi/actions/workflows/ci.yml/badge.svg)](https://github.com/arcas0803/obsi/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](https://github.com/arcas0803/obsi/blob/main/LICENSE)

`obsi_exporter_otlp` sends traces, logs, and metrics produced by
[`obsi`](https://pub.dev/packages/obsi) to an OpenTelemetry Collector or an
OTLP-compatible backend. The package implements OTLP over HTTP with binary
Protocol Buffers by default and JSON as an explicit compatibility option.

This package is a transport layer. The `obsi` core remains responsible for
creating signals, resources, batching, sampling, cardinality, and shutdown.

## Installation

```sh
dart pub add obsi obsi_exporter_otlp
```

```dart
import 'package:obsi/obsi.dart';
import 'package:obsi_exporter_otlp/obsi_exporter_otlp.dart';
```

## The mental model

Each signal has its own endpoint and exporter:

```text
BatchSpanProcessor ─────────→ OtlpHttpSpanExporter   → /v1/traces
BatchLogProcessor ──────────→ OtlpHttpLogExporter    → /v1/logs
PeriodicMetricReader ───────→ OtlpHttpMetricExporter → /v1/metrics
```

The exporter groups data by `Resource` and `InstrumentationScope`, encodes an
OTLP request, sends it over HTTP, and interprets standard success and
partial-success responses. Exporters do not make sampling or batching
decisions.

## Complete configuration

The simplest production configuration reads standard OpenTelemetry environment
variables:

```dart
final resource = Resource({
  'service.name': 'checkout-api',
  'service.version': '1.0.0',
});

Obsi.configure(ObsiProvider(
  traces: TracerProvider(
    resource: resource,
    processor: BatchSpanProcessor(
      OtlpHttpSpanExporter.fromEnvironment(),
    ),
  ),
  logs: LoggerProvider(
    resource: resource,
    processor: BatchLogProcessor(
      OtlpHttpLogExporter.fromEnvironment(),
    ),
  ),
  metrics: MeterProvider(
    resource: resource,
    readers: [
      PeriodicMetricReader(
        OtlpHttpMetricExporter.fromEnvironment(),
        interval: const Duration(seconds: 30),
      ),
    ],
  ),
));

try {
  await runApplication();
} finally {
  await Obsi.shutdown();
}
```

With no configuration, the exporters use:

| Signal | Default endpoint |
| --- | --- |
| Traces | `http://localhost:4318/v1/traces` |
| Logs | `http://localhost:4318/v1/logs` |
| Metrics | `http://localhost:4318/v1/metrics` |

## Environment configuration

`fromEnvironment()` understands the standard general and signal-specific
`OTEL_EXPORTER_OTLP_*` variables. Signal-specific values take precedence.

```sh
export OTEL_EXPORTER_OTLP_ENDPOINT=https://collector.example
export OTEL_EXPORTER_OTLP_HEADERS='authorization=Bearer%20token'
export OTEL_EXPORTER_OTLP_PROTOCOL=http/protobuf
export OTEL_EXPORTER_OTLP_COMPRESSION=gzip
export OTEL_EXPORTER_OTLP_TIMEOUT=10000
```

Use `OTEL_EXPORTER_OTLP_TRACES_ENDPOINT`,
`OTEL_EXPORTER_OTLP_LOGS_ENDPOINT`, or
`OTEL_EXPORTER_OTLP_METRICS_ENDPOINT` when one signal needs a different URL.
Supported protocols are `http/protobuf` and `http/json`. Configuring `grpc` or
an unknown value throws `FormatException` during startup.

## Direct configuration

Construct an exporter directly when configuration comes from application
settings rather than process environment:

```dart
final exporter = OtlpHttpSpanExporter(
  endpoint: Uri.parse('https://collector.example/v1/traces'),
  headers: {'authorization': 'Bearer $token'},
  protocol: OtlpHttpProtocol.httpProtobuf,
  compression: OtlpCompression.gzip,
  timeout: const Duration(seconds: 10),
  maxRetries: 5,
  maxRequestSize: 16 * 1024 * 1024,
  maxResponseSize: 1024 * 1024,
);
```

Use `httpJson` only when the receiver explicitly requires OTLP JSON. Binary
Protobuf is smaller and is the default OTLP/HTTP encoding.

## Retries, limits, and partial success

Connection failures, timeouts, and HTTP `429`, `502`, `503`, and `504` responses
are retried. The exporter honors `Retry-After` and otherwise uses bounded
exponential backoff with jitter. Permanent `4xx` errors are not retried.

Requests are checked against `maxRequestSize` before network I/O. Responses are
streamed with `maxResponseSize` enforcement. This prevents a faulty endpoint
from causing unbounded allocations.

OTLP can accept part of a batch and reject the rest. In that case the exporter
throws `OtlpPartialSuccessException` with `rejectedItems` and the Collector
message. It does not retry the accepted batch because doing so would duplicate
the successful data.

```dart
try {
  await exporter.export(spans);
} on OtlpPartialSuccessException catch (error) {
  fallbackLog('Rejected ${error.rejectedItems}: ${error.message}');
}
```

`requestCount`, `retryCount`, and `failureCount` expose transport health. They
can be monitored through a fallback channel, but must not be recorded through
the same failing exporter.

## Ownership and shutdown

An exporter owns an HTTP client it creates internally. If an `http.Client` is
injected, the caller retains ownership and must close it.

`shutdown()` is idempotent and waits for every request accepted before shutdown
started. It then closes only owned resources. New exports, including empty
batches, complete with `StateError` after shutdown. In normal applications,
let the owning Obsi processor close the exporter through `Obsi.shutdown()`.

Do not instrument OTLP endpoint requests with the HTTP or Dio integration. That
would create telemetry while exporting telemetry and can cause recursion.

## Failure reference

| Failure | Meaning | Typical action |
| --- | --- | --- |
| `ArgumentError` | Invalid endpoint, timeout, size, retry, or backoff setting | Fix startup configuration. |
| `FormatException` | Invalid environment variable | Reject deployment configuration before serving traffic. |
| `OtlpExportException` | Permanent non-success HTTP response | Inspect status and response body. |
| `OtlpRequestTooLargeException` | Encoded batch exceeds the local request limit | Reduce processor batch size or raise the reviewed limit. |
| `OtlpResponseTooLargeException` | Collector response exceeds the local limit | Inspect the endpoint; do not blindly remove the limit. |
| `OtlpPartialSuccessException` | Collector accepted only part of the request | Inspect rejected item count and Collector diagnostics. |
| `StateError` | Export attempted after shutdown | Fix ownership or lifecycle ordering. |

## API inventory

| Concept | Public API | When to use it |
| --- | --- | --- |
| Trace delivery | `OtlpHttpSpanExporter` | Export `SpanData` through a `SimpleSpanProcessor` or `BatchSpanProcessor`. |
| Log delivery | `OtlpHttpLogExporter` | Export `LogRecord` through a log processor. |
| Metric delivery | `OtlpHttpMetricExporter` | Export `MetricData` through a metric reader. |
| Environment resolution | `OtlpHttpEnvironmentConfiguration`, `OtlpSignal` | Inspect or resolve standard OTLP settings for one signal. |
| Wire protocol | `OtlpHttpProtocol` | Select binary Protobuf or explicit JSON encoding. |
| Compression | `OtlpCompression` | Enable gzip for lower bandwidth at the cost of local CPU. |
| HTTP failure | `OtlpExportException` | Handle permanent non-success Collector responses. |
| Payload limits | `OtlpRequestTooLargeException`, `OtlpResponseTooLargeException` | Detect locally rejected oversized traffic. |
| Partial acceptance | `OtlpPartialSuccessException` | Diagnose Collector-side item rejection without duplicating accepted data. |

Only declarations exported by
`package:obsi_exporter_otlp/obsi_exporter_otlp.dart` are stable. The wire format
is tested against a real OpenTelemetry Collector in CI.

See [`obsi`](https://pub.dev/packages/obsi) for signal creation, resources,
batching, sampling, redaction, and lifecycle. Licensed under the
[MIT License](https://github.com/arcas0803/obsi/blob/main/LICENSE).
