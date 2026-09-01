# obsi

[![pub package](https://img.shields.io/pub/v/obsi.svg)](https://pub.dev/packages/obsi)
[![CI](https://github.com/arcas0803/obsi/actions/workflows/ci.yml/badge.svg)](https://github.com/arcas0803/obsi/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](https://github.com/arcas0803/obsi/blob/main/LICENSE)

`obsi` is the observability core for Dart applications. It helps explain what
an application is doing through four related signals:

- **traces** follow an operation and each step it performs;
- **logs** record structured events with execution context;
- **metrics** measure counts, current state, and distributions over time;
- **errors** capture failures with user data, breadcrumbs, and technical context.

The package also provides resources, sampling, W3C propagation, baggage,
processors, and exporter contracts. It is pure Dart: there is no Flutter, HTTP
client, backend, or OpenTelemetry SDK dependency. Backends and framework
instrumentations are added through optional packages.

## Installation

```sh
dart pub add obsi
```

```dart
import 'package:obsi/obsi.dart';
```

## The mental model

An Obsi installation has three layers:

1. Application code creates telemetry through a `Tracer`, `Logger`, `Meter`, or
   `ErrorManager`.
2. A processor decides when to deliver it. A batch processor, for example,
   queues spans and exports them outside the application path.
3. An exporter sends the data to a destination such as the console, OTLP,
   Sentry, Crashlytics, or your own implementation.

`ObsiProvider` groups all four signals and `Obsi` exposes them through one
process-wide facade. Global access is optional: providers can also be injected
directly into application classes.

```text
application → tracer/logger/meter/errors → processor/reader → exporter
```

## First configuration

The following example configures all four signals with console exporters. It is
a useful starting point before connecting a production backend.

```dart
final resource = Resource({
  'service.name': 'checkout-api',
  'service.version': '1.0.0',
  'deployment.environment.name': 'development',
});

final provider = ObsiProvider(
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
    readers: [
      PeriodicMetricReader(
        const ConsoleMetricExporter(),
        interval: const Duration(seconds: 30),
      ),
    ],
  ),
  errors: ErrorManager(
    resource: resource,
    exporter: const ConsoleErrorExporter(),
  ),
);

Obsi.configure(provider);

try {
  await runApplication();
} finally {
  await Obsi.shutdown();
}
```

`Resource` describes the process producing telemetry. Reuse the same resource
across providers so traces, logs, metrics, and errors can be queried as parts of
the same service.

`BatchSpanProcessor` and `BatchLogProcessor` are suitable for production: they
keep bounded queues and export outside the main execution path. The
`Simple...Processor` variants deliver each item immediately and are useful for
tests and small programs.

### Human-friendly console output

The default console exporters continue to emit one JSON object per record. This
is useful for CI, log collectors, and other machine consumers. During local
development, use the named `pretty` constructors for readable, colored output:

```dart
const pretty = PrettyConsoleOptions(
  colors: true,
  includeResource: false,
  includeTraceContext: true,
  includeStackTrace: true,
);

final provider = ObsiProvider(
  traces: TracerProvider(
    processor: BatchSpanProcessor(
      const ConsoleSpanExporter.pretty(options: pretty),
    ),
  ),
  logs: LoggerProvider(
    processor: BatchLogProcessor(
      const ConsoleLogExporter.pretty(options: pretty),
    ),
  ),
  metrics: MeterProvider(
    readers: [
      PeriodicMetricReader(
        const ConsoleMetricExporter.pretty(options: pretty),
      ),
    ],
  ),
  errors: ErrorManager(
    exporter: const ConsoleErrorExporter.pretty(options: pretty),
  ),
);
```

Pretty output prioritizes severity or signal type, scope, message, duration,
attributes, trace correlation, metric points, span events, error breadcrumbs,
and stack traces. Set `colors: false` for terminals without ANSI support. Other
options can hide timestamps, scope, trace context, resources, or stack traces;
print attributes on separate lines; and bound displayed value lengths.

Every console exporter also accepts a `writer` callback. For example, Flutter
applications can pass `debugPrint`, while tests can collect output in a list.
The callback changes only the destination, not JSON or pretty formatting.

## Tracing: follow an operation

A trace represents a complete operation. Each `Span` is one step within it.
`trace()` creates a span, makes it current inside the callback, records failures,
and ends it when the callback completes.

```dart
final tracer = Obsi.tracer;

final order = await tracer.trace(
  'order.create',
  () async {
    final customer = await tracer.trace(
      'customer.load',
      () => repository.loadCustomer(),
    );

    return tracer.trace(
      'order.persist',
      () => repository.createOrder(customer),
    );
  },
  attributes: {
    'order.channel': 'web',
    'cart.items': 3,
  },
);
```

Nested spans inherit the current span through Dart `Zone` context, which is
preserved across `Future` and `await`. Use `traceSync()` for synchronous work.
Use `traceStream()` when the span must remain open until a stream completes,
fails, or is cancelled.

For full control, create a span manually:

```dart
final span = Obsi.tracer.startSpan(
  'payment.authorize',
  kind: SpanKind.client,
  attributes: {'payment.provider': 'example'},
);

try {
  await span.run(() => paymentClient.authorize());
  span
    ..addEvent('payment.accepted')
    ..setStatus(SpanStatus.ok);
} catch (error, stackTrace) {
  span
    ..recordException(error, stackTrace: stackTrace)
    ..setStatus(SpanStatus.error);
  rethrow;
} finally {
  span.end();
}
```

Use `SpanKind.client` for outbound calls, `server` for inbound requests,
`producer` and `consumer` for messaging, and `internal` for local work. Prefer
stable names such as `GET /users/:id`; unique values such as
`GET /users/87421` create unnecessary cardinality.

### Sampling

The sampler decides whether a new trace should be recorded and exported. A
parent-based sampler preserves an upstream decision and applies a local ratio
only to root traces:

```dart
final traces = TracerProvider(
  processor: BatchSpanProcessor(spanExporter),
  sampler: ParentBasedSampler(
    root: TraceIdRatioBasedSampler(0.10),
  ),
);
```

`AlwaysOnSampler` records everything and `AlwaysOffSampler` drops everything.
Sampling reduces volume, but it does not replace bounded queues or a backend
retention policy.

## Logging: events with context

A logger is named after the component producing its records. Its name and
version become the `InstrumentationScope`, allowing modules and libraries in
the same service to be distinguished.

```dart
final logger = Obsi.logger('checkout.payment', version: '1.0.0');

logger.info(
  'Payment requested',
  attributes: {
    'payment.method': 'card',
    'order.currency': 'EUR',
  },
);

try {
  await charge();
} catch (error, stackTrace) {
  logger.error(
    'Payment failed',
    error: error,
    stackTrace: stackTrace,
    attributes: {'payment.retryable': true},
  );
  rethrow;
}
```

When a log is emitted inside a span, Obsi automatically attaches its trace and
span identifiers. Logs also become error breadcrumbs, so a later error report
contains the events that led to the failure.

The API provides `trace`, `debug`, `info`, `warn`, `error`, `fatal`, and the
generic `log` method. `LoggerProvider.minimumSeverity` drops less important
levels before processing.

## Metrics: measure aggregate behavior

A `Meter` creates instruments. Choose the instrument based on the question you
want the metric to answer:

- `Counter`: how many times did something happen? It only increases.
- `UpDownCounter`: how many items exist now? It can increase or decrease.
- `Histogram`: how are durations or sizes distributed?
- `Gauge`: what is the latest known value?
- observable instruments: what is the value when the reader collects it?

```dart
final meter = Obsi.meter('checkout.orders', version: '1.0.0')!;

final created = meter.createCounter<int>(
  'orders.created',
  unit: '{order}',
);
final active = meter.createUpDownCounter<int>(
  'orders.active',
  unit: '{order}',
);
final duration = meter.createHistogram<double>(
  'orders.processing.duration',
  unit: 's',
  boundaries: [0.01, 0.05, 0.1, 0.5, 1, 2.5, 5],
);

final stopwatch = Stopwatch()..start();
active.add(1);
try {
  await processOrder();
  created.add(1, attributes: {'order.result': 'accepted'});
} finally {
  active.add(-1);
  duration.record(
    stopwatch.elapsedMicroseconds / Duration.microsecondsPerSecond,
    attributes: {'order.channel': 'web'},
  );
}
```

Use an observable instrument for a value already maintained by the application:

```dart
meter.createObservableGauge<int>(
  'worker.queue.depth',
  () => [Observation(queue.length)],
  unit: '{job}',
);
```

Metric attributes create distinct time series and must have low cardinality.
`status=success` is appropriate; `user.id` and `order.id` are not. The provider
bounds cardinality and exposes `droppedMeasurements`. A `MetricView` customizes
buckets and limits for one instrument:

```dart
final metrics = MeterProvider(
  readers: [PeriodicMetricReader(metricExporter)],
  cardinalityLimit: 2000,
  views: const [
    MetricView(
      instrumentName: 'orders.processing.duration',
      histogramBoundaries: [0.01, 0.1, 0.5, 1, 5],
      cardinalityLimit: 100,
    ),
  ],
);
```

## Errors: capture and enrich failures

`ErrorManager` builds an `ErrorReport`, runs its processors, and passes it to an
`ErrorExporter`. Its default pipeline sanitizes common sensitive fields,
deduplicates repeated reports, and rate-limits non-fatal errors.

`Errors.guard()` is useful at an operation boundary. It captures an error and
then rethrows it with the original stack trace:

```dart
await Errors.guard(
  () async {
    await runCommand();
  },
  fatal: false,
  handled: true,
);
```

`withScope()` adds context to one synchronous or asynchronous branch without
mutating concurrent requests:

```dart
await Errors.withScope(
  () async {
    Errors.addBreadcrumb(ErrorBreadcrumb(
      timestamp: DateTime.now(),
      category: 'checkout',
      message: 'User confirmed the order',
      data: {'cart.items': 3},
    ));

    try {
      await submitOrder();
    } catch (error, stackTrace) {
      final errorId = await Errors.captureException(
        error,
        stackTrace: stackTrace,
        reason: 'Order submission failed',
        tags: {'feature': 'checkout'},
        contexts: {
          'order': {'currency': 'EUR', 'items': 3},
        },
      );
      Obsi.logger('checkout').warn(
        'Error report accepted',
        attributes: {'error.id': '$errorId'},
      );
    }
  },
  user: ErrorUser(id: 'customer-42'),
  tags: {'tenant': 'acme'},
);
```

An `ErrorId` means the local pipeline accepted the report; it does not prove
that a remote backend received it. Inspect `acceptedReports`, `exportedReports`,
`droppedReports`, `exportFailures`, and `processorFailures` to monitor delivery.

Use `Errors.runGuarded()` for otherwise uncaught asynchronous failures. Dart
isolates do not share memory: use `Errors.listenToIsolateErrors()` for a
secondary isolate and close the returned `ErrorIsolateListener`. Flutter global
errors are handled by the optional `obsi_flutter` package.

## Attributes, privacy, and conventions

Attributes support `String`, `bool`, `int`, finite `double`, and homogeneous
lists of those types. Empty keys, null values, non-finite numbers, and
unsupported types throw `ArgumentError`. Failing early prevents ambiguous data
from reaching exporters.

Apply the same redactor to providers that receive external data:

```dart
final redact = SensitiveAttributeRedactor(
  sensitiveKeys: ['password', 'token', 'authorization', 'email'],
).call;

final traces = TracerProvider(
  processor: BatchSpanProcessor(spanExporter),
  attributeRedactor: redact,
);
final logs = LoggerProvider(
  processor: BatchLogProcessor(logExporter),
  attributeRedactor: redact,
);
final metrics = MeterProvider(
  readers: [PeriodicMetricReader(metricExporter)],
  attributeRedactor: redact,
);
```

`SemanticAttributes`, `SemanticEvents`, `SemanticMetrics`, and `SemanticHttp`
provide names and helpers aligned with OpenTelemetry conventions. Use them in
instrumentations instead of introducing multiple names for the same concept.

## Distributed context and baggage

`W3CTraceContextPropagator` injects and extracts `traceparent` and `tracestate`.
`W3CBaggagePropagator` does the same for baggage. The HTTP, Dio, and Shelf
integrations already use them, so most applications only need to install the
appropriate instrumentation package.

Baggage carries small values that must follow an operation across layers or
services:

```dart
await Baggage.empty
    .set('tenant.id', 'acme')
    .set('release.channel', 'stable')
    .run(() async {
      await Obsi.tracer.trace('catalog.refresh', refreshCatalog);
    });
```

Never store secrets or large objects in baggage because it can travel through
network headers. Active context uses Dart `Zone`; each isolate must configure
its own Obsi installation.

## Exporters and composition

Console exporters are intended for development. Production applications
typically use OTLP for traces, logs, and metrics, and Sentry or Crashlytics for
errors. `MultiSpanProcessor`, `MultiLogProcessor`, and `MultiErrorExporter`
deliver one signal to multiple destinations:

```dart
final processor = MultiSpanProcessor([
  BatchSpanProcessor(primaryExporter),
  BatchSpanProcessor(auditExporter),
]);
```

A processor owns its exporter. An `ObsiProvider` owns its signal providers. Do
not share the same owned instance with multiple owners unless that
implementation explicitly supports repeated shutdown.

## Lifecycle and internal failures

- `Obsi.configure(provider)` installs a provider without closing a previous
  installation. It is normally called once during startup.
- `await Obsi.replace(next)` detaches the previous provider, waits for it to
  drain and close, and then installs the replacement.
- `Obsi.disable()` only detaches global facades; it does not flush or release
  resources.
- `await Obsi.shutdown()` stops accepting telemetry, drains accepted work, and
  closes every owned resource exactly once.

Shutdown is idempotent and safe under concurrent calls. While `replace` or
`shutdown` is pending, synchronous `configure` and `disable` calls throw
`StateError`. After terminal shutdown, synchronous signal APIs ignore new work;
terminal asynchronous APIs may complete with `StateError`.

Pipelines use limits and timeouts so an unavailable backend cannot consume
memory indefinitely. Monitor counters such as `droppedSpans`, `droppedRecords`,
`droppedMeasurements`, `droppedReports`, and `exportFailures` as part of the
observability system itself.

Internal failures are delivered to a `TelemetryErrorHandler`. The handler must
use a fallback channel that does not call Obsi recursively:

```dart
void telemetryDiagnostic(Object error, StackTrace stackTrace) {
  stderr.writeln('Obsi failure: $error\n$stackTrace');
}

final processor = BatchSpanProcessor(
  spanExporter,
  maxQueueSize: 2048,
  maxExportBatchSize: 512,
  exportTimeout: const Duration(seconds: 10),
  onExportError: telemetryDiagnostic,
);
```

## API inventory

| Concept | Main public API | When to use it |
| --- | --- | --- |
| Complete installation | `Obsi`, `ObsiProvider` | Configure and close traces, logs, metrics, and errors as one unit. |
| Per-signal facades | `Trace`, `Logs`, `Metrics`, `Errors` | Configure or access one signal without a complete `ObsiProvider`. |
| Service identity | `Resource` | Attach service name, version, environment, host, and common metadata to every signal. |
| Component identity | `InstrumentationScope` | Identify the module or library creating telemetry; normally created by `getTracer`, `getLogger`, or `getMeter`. |
| Attributes and privacy | `Attributes`, `AttributeRedactor`, `SensitiveAttributeRedactor` | Validate metadata and remove credentials or personal data before export. |
| Internal diagnostics | `TelemetryErrorHandler` | Observe timeouts and exporter failures without breaking business operations. |
| Semantic conventions | `SemanticAttributes`, `SemanticEvents`, `SemanticMetrics`, `SemanticHttp` | Produce consistent names and attributes, especially in instrumentations. |
| Trace creation | `TracerProvider`, `Tracer`, `Span`, `SpanData` | Measure operations, dependencies, and internal steps. `SpanData` is the immutable exporter snapshot. |
| Span model | `SpanContext`, `SpanKind`, `SpanStatus`, `SpanEvent`, `SpanLink`, `SpanLimits` | Represent distributed context, operation type, outcome, events, cross-trace relationships, and data limits. |
| Sampling | `Sampler`, `AlwaysOnSampler`, `AlwaysOffSampler`, `ParentBasedSampler`, `TraceIdRatioBasedSampler`, `SamplingParameters`, `SamplingResult`, `SamplingDecision` | Control which traces are recorded and exported. |
| ID generation | `IdGenerator`, `RandomIdGenerator` | Generate trace, span, and error IDs. Implement a custom generator only when a different valid policy is required. |
| Span processing | `SpanProcessor`, `SimpleSpanProcessor`, `BatchSpanProcessor`, `MultiSpanProcessor` | Use simple for immediate delivery, batch for production, and multi for multiple destinations. |
| Span export | `SpanExporter`, `ConsoleSpanExporter` | Implement a custom backend or inspect spans during development. |
| Logging | `LoggerProvider`, `Logger`, `LogRecord`, `LogSeverity` | Emit structured events correlated with the current span. |
| Log processing | `LogProcessor`, `SimpleLogProcessor`, `BatchLogProcessor`, `MultiLogProcessor`, `LogExporter`, `ConsoleLogExporter` | Control how logs are batched and where they are sent. |
| Synchronous metrics | `MeterProvider`, `Meter`, `Counter`, `UpDownCounter`, `Gauge`, `Histogram` | Record measurements directly from application code. |
| Observable metrics | `ObservableCounter`, `ObservableUpDownCounter`, `ObservableGauge`, `Observation` | Read current values during collection, such as queue depth or resource use. |
| Metric collection | `MetricReader`, `ManualMetricReader`, `PeriodicMetricReader`, `MetricExporter`, `ConsoleMetricExporter` | Use manual collection in tests and periodic collection in long-running services. |
| Metric model | `InstrumentKind`, `MetricPoint`, `MetricData`, `MetricView`, `AggregationTemporality`, `MetricProducer` | Implement exporters/readers and configure buckets, cardinality, and temporality. |
| Error capture | `ErrorManager`, `Errors`, `ErrorReport`, `ErrorId`, `ErrorSeverity`, `ErrorMechanism` | Turn exceptions into enriched, correlated reports. |
| Error context | `ErrorScope`, `ErrorUser`, `ErrorBreadcrumb`, `ErrorAttachment` | Add user, recent activity, tags, contexts, fingerprints, and attachments without leaking across requests. |
| Error policy | `ErrorProcessor`, `ErrorSanitizingProcessor`, `ErrorDeduplicationProcessor`, `ErrorSamplingProcessor`, `ErrorRateLimitProcessor`, `ErrorBeforeSendProcessor` | Filter, transform, deduplicate, sample, and rate-limit reports before export. |
| Error export | `ErrorExporter`, `MultiErrorExporter`, `ConsoleErrorExporter` | Connect a backend, fan out to destinations, or inspect reports locally. |
| Isolate errors | `ErrorIsolateListener` | Listen for uncaught errors from a secondary isolate; the caller must close it. |
| Trace propagation | `TracePropagator`, `W3CTraceContextPropagator`, `CompositeTracePropagator` | Continue traces through headers or combine propagation formats. |
| Baggage | `Baggage`, `BaggageEntry`, `BaggagePropagator`, `W3CBaggagePropagator` | Carry small business-context values across operations and services. |

Only declarations exported by `package:obsi/obsi.dart` belong to the stable API.
Paths under `package:obsi/src/...` are internal.

## Official plugins

| Package | What it adds | When to use it |
| --- | --- | --- |
| [`obsi_exporter_otlp`](https://pub.dev/packages/obsi_exporter_otlp) | OTLP HTTP/Protobuf and HTTP/JSON exporters | OpenTelemetry Collector and compatible observability backends. |
| [`obsi_error_sentry`](https://pub.dev/packages/obsi_error_sentry) | Sentry error exporter | Dart or Flutter applications using Sentry. |
| [`obsi_error_crashlytics`](https://pub.dev/packages/obsi_error_crashlytics) | Firebase Crashlytics exporter | Flutter application error delivery. |
| [`obsi_flutter`](https://pub.dev/packages/obsi_flutter) | Flutter error capture and `NavigatorObserver` | Global Flutter failures, navigation traces, and screen-duration metrics. |
| [`obsi_instrumentation_http`](https://pub.dev/packages/obsi_instrumentation_http) | Instrumented `package:http` client | HTTP traces, metrics, and propagation. |
| [`obsi_instrumentation_dio`](https://pub.dev/packages/obsi_instrumentation_dio) | Dio interceptor | Instrument existing Dio clients without wrapping every request. |
| [`obsi_instrumentation_shelf`](https://pub.dev/packages/obsi_instrumentation_shelf) | Shelf middleware | Continue traces and measure inbound Shelf requests. |

Complete examples are available for a [CLI](https://github.com/arcas0803/obsi/tree/main/examples/cli),
[Shelf server](https://github.com/arcas0803/obsi/tree/main/examples/server),
and [Flutter application](https://github.com/arcas0803/obsi/tree/main/packages/obsi_flutter/example).

Obsi 1.x follows semantic versioning. Compatible additions may be released in a
minor version; incompatible changes are reserved for a major version. The
project is distributed under the
[MIT License](https://github.com/arcas0803/obsi/blob/main/LICENSE).
