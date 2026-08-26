import 'package:obsi/obsi.dart';
import 'package:obsi_exporter_otlp/obsi_exporter_otlp.dart';

/// Runs a traced CLI command and flushes every telemetry signal before exit.
Future<void> main(List<String> arguments) async {
  final resource = Resource({
    'service.name': 'obsi-cli-example',
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
      attributeRedactor: SensitiveAttributeRedactor().call,
    ),
    errors: ErrorManager(
      resource: resource,
      exporter: const ConsoleErrorExporter(),
    ),
  );
  Obsi.configure(provider);

  final logger = Obsi.logger('example.cli', version: '1.0.0');
  final meter = Obsi.meter('example.cli', version: '1.0.0')!;
  final runs = meter.createCounter<int>('cli.command.runs');

  try {
    await Errors.guard(
      () async {
        await Obsi.tracer.trace(
          'cli.command',
          attributes: {'cli.arguments.count': arguments.length},
          () async {
            logger.info('Command started');
            runs.add(1, attributes: const {'command': 'example'});
            await Future<void>.delayed(const Duration(milliseconds: 10));
            logger.info('Command completed');
          },
        );
      },
      fatal: false,
      handled: true,
    );
  } finally {
    await Obsi.shutdown();
  }
}
