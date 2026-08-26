import 'dart:io';

import 'package:obsi/obsi.dart';
import 'package:obsi_exporter_otlp/obsi_exporter_otlp.dart';
import 'package:test/test.dart';

void main() {
  final enabled = Platform.environment['OTEL_COLLECTOR_INTEGRATION'] == 'true';

  test(
    'exports all signals to a real OpenTelemetry Collector over Protobuf',
    () async {
      final endpoint = Uri.parse(
        Platform.environment['OTEL_EXPORTER_OTLP_ENDPOINT'] ??
            'http://127.0.0.1:4318',
      );
      final resource = Resource({'service.name': 'obsi-collector-test'});
      final scope = InstrumentationScope('collector-test', version: '1.0.0');
      final environment = {'OTEL_EXPORTER_OTLP_ENDPOINT': endpoint.toString()};
      final spans = OtlpHttpSpanExporter.fromEnvironment(
        environment: environment,
      );
      final logs = OtlpHttpLogExporter.fromEnvironment(
        environment: environment,
      );
      final metrics = OtlpHttpMetricExporter.fromEnvironment(
        environment: environment,
      );

      await spans.export([
        SpanData(
          name: 'collector-span',
          context: const SpanContext(
            traceId: '11111111111111111111111111111111',
            spanId: '2222222222222222',
            sampled: true,
          ),
          parentSpanId: null,
          kind: SpanKind.internal,
          startTime: DateTime.utc(2026),
          endTime: DateTime.utc(2026).add(const Duration(milliseconds: 1)),
          status: SpanStatus.ok,
          statusDescription: null,
          resource: resource,
          instrumentationScope: scope,
          attributes: const {'test.signal': 'traces'},
          events: const [],
          links: const [],
        ),
      ]);
      await logs.export([
        LogRecord(
          timestamp: DateTime.utc(2026),
          observedTimestamp: DateTime.utc(2026),
          severity: LogSeverity.info,
          body: 'collector-log',
          attributes: const {'test.signal': 'logs'},
          resource: resource,
          instrumentationScope: scope,
        ),
      ]);
      await metrics.export([
        MetricData(
          name: 'collector.metric',
          kind: InstrumentKind.counter,
          description: 'Collector compatibility test',
          unit: '1',
          resource: resource,
          instrumentationScope: scope,
          points: [
            MetricPoint(
              attributes: const {'test.signal': 'metrics'},
              timestamp: DateTime.utc(2026),
              value: 1,
            ),
          ],
        ),
      ]);
      await Future.wait([
        spans.shutdown(),
        logs.shutdown(),
        metrics.shutdown(),
      ]);
    },
    skip: enabled ? false : 'Set OTEL_COLLECTOR_INTEGRATION=true to run.',
  );
}
