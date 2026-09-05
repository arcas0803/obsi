## 1.1.0

- Added compact semantic trace summaries, configurable diagnostic detail,
  readable exceptions, and bounded local trace trees across export batches.
- Preserved JSON output and const pretty constructors; tree mode is opt-in.

## 1.0.1

- Added opt-in human-friendly console formatting for spans, logs, metrics, and
  errors while preserving newline-delimited JSON as the default.
- Added shared presentation controls for ANSI colors, timestamps, scope and
  trace context, resources, stack traces, multiline attributes, value bounds,
  and custom console writers.

## 1.0.0

- Initial pure Dart observability core with tracing, logs, metrics, errors,
  W3C context propagation, bounded processors, and lifecycle management.
- Added strict input validation, immutable structured error data, bounded
  in-flight exports, exporter timeouts and idempotent shutdown.
- Added compatible metric instrument reuse and conflict detection.
- Added internal diagnostics and counters for dropped or failed telemetry.
- Added conformance, failure, lifecycle, fuzz, concurrency and stress tests.
- Added deterministic ratio and parent-based sampling with record-only support.
- Added metric views, temporality/start-time metadata and per-view cardinality.
- Added default SDK resources, composite propagation, central attribute
  redaction, and bounded error-export backpressure.
