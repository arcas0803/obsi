# Obsi

[![CI](https://github.com/arcas0803/obsi/actions/workflows/ci.yml/badge.svg)](https://github.com/arcas0803/obsi/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

Obsi is a production-oriented observability toolkit for Dart and Flutter. It
combines distributed tracing, structured logs, metrics, error management, W3C
context propagation, OTLP export, and focused framework instrumentations. The
`obsi` core is pure Dart and optional packages add only their required dependencies.

## Workspace

| Package | Purpose | Runtime |
| --- | --- | --- |
| [`obsi`](packages/obsi) | Core signals, propagation, and lifecycle | Dart |
| [`obsi_exporter_otlp`](packages/obsi_exporter_otlp) | OTLP HTTP/Protobuf and HTTP/JSON | Dart |
| [`obsi_error_sentry`](packages/obsi_error_sentry) | Sentry error delivery | Dart |
| [`obsi_error_crashlytics`](packages/obsi_error_crashlytics) | Firebase Crashlytics delivery | Flutter |
| [`obsi_flutter`](packages/obsi_flutter) | Flutter errors and Navigator telemetry | Flutter |
| [`obsi_instrumentation_http`](packages/obsi_instrumentation_http) | `package:http` client | Dart |
| [`obsi_instrumentation_dio`](packages/obsi_instrumentation_dio) | Dio client | Dart |
| [`obsi_instrumentation_shelf`](packages/obsi_instrumentation_shelf) | Shelf server | Dart |

Each package README is its self-contained pub.dev manual, including examples,
configuration, lifecycle rules, and a public API inventory.

Core console exporters preserve newline-delimited JSON as their default output
and also expose `ConsoleSpanExporter.pretty`, `ConsoleLogExporter.pretty`,
`ConsoleMetricExporter.pretty`, and `ConsoleErrorExporter.pretty` for readable
local development. See the [`obsi` console output guide](packages/obsi#human-friendly-console-output)
for configuration and display options.

## Project goals

- A dependency-free pure Dart core with stable 1.x contracts.
- Safe defaults: bounded resources, sanitization, failure isolation,
  deterministic ownership, and idempotent shutdown.
- OpenTelemetry-compatible semantics, W3C propagation, and OTLP transport.
- Integrations that preserve application behavior, streams, and privacy.
- Release gates for analysis, docs, publication, coverage, and a real
  Collector, plus local Android/iOS integration tests before publishing.

See [CONTRIBUTING.md](CONTRIBUTING.md), [SECURITY.md](SECURITY.md), and the
[MIT License](LICENSE).
