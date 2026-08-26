import 'dart:async';
import 'dart:io';

import 'package:obsi/obsi.dart';
import 'package:obsi_exporter_otlp/obsi_exporter_otlp.dart';
import 'package:obsi_instrumentation_shelf/obsi_instrumentation_shelf.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart';

/// Starts a fully instrumented Shelf server and performs graceful shutdown.
Future<void> main() async {
  final resource = Resource({
    'service.name': 'obsi-server-example',
    'service.version': '1.0.0',
    'deployment.environment.name': 'development',
  });
  final provider = ObsiProvider(
    traces: TracerProvider(
      resource: resource,
      processor: BatchSpanProcessor(OtlpHttpSpanExporter.fromEnvironment()),
      attributeRedactor: SensitiveAttributeRedactor().call,
    ),
    logs: LoggerProvider(
      resource: resource,
      processor: BatchLogProcessor(OtlpHttpLogExporter.fromEnvironment()),
      attributeRedactor: SensitiveAttributeRedactor().call,
    ),
    metrics: MeterProvider(
      resource: resource,
      readers: [
        PeriodicMetricReader(
          OtlpHttpMetricExporter.fromEnvironment(),
          interval: const Duration(seconds: 30),
        ),
      ],
      views: const [
        MetricView(
          instrumentName: SemanticMetrics.httpServerRequestDuration,
          cardinalityLimit: 500,
        ),
      ],
      attributeRedactor: SensitiveAttributeRedactor().call,
    ),
    errors: ErrorManager(
      resource: resource,
      exporter: const ConsoleErrorExporter(),
    ),
  );
  Obsi.configure(provider);

  final handler = const Pipeline()
      .addMiddleware(
        obsiMiddleware(
          tracer: Obsi.tracer,
          meter: Obsi.meter('example.http.server'),
          routeResolver: (request) => switch (request.url.path) {
            'health' => '/health',
            _ => '/unknown',
          },
          options: ObsiShelfOptions(
            shouldInstrument: (request) => request.url.path != 'health',
          ),
        ),
      )
      .addHandler((request) async {
        if (request.url.path == 'health') return Response.ok('ok');
        return Response.notFound('not found');
      });

  final server = await serve(handler, InternetAddress.loopbackIPv4, 8080);
  Obsi.logger(
    'example.server',
  ).info('Server started', attributes: {'server.port': server.port});

  try {
    await Future.any([
      ProcessSignal.sigint.watch().first,
      ProcessSignal.sigterm.watch().first,
    ]);
  } finally {
    await server.close(force: false);
    await Obsi.shutdown();
  }
}
