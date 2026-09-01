## 1.0.1

- Updated the `obsi` dependency baseline to 1.0.1.

## 1.0.0

- Added production OTLP/HTTP trace, log, and metric export with binary Protocol
  Buffers by default and JSON as an explicit compatibility option.
- Added canonical Protobuf wire encoding and Protobuf JSON mapping,
  resource/scope grouping, environment configuration, gzip, bounded requests
  and responses, retries, partial-success decoding, lifecycle guarantees, and
  exporter counters.
- Added interoperability coverage against a real OpenTelemetry Collector.
