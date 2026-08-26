import 'package:obsi/obsi.dart';
import 'package:obsi_exporter_otlp/obsi_exporter_otlp.dart';

Future<void> main() async {
  final provider = TracerProvider(
    processor: BatchSpanProcessor(OtlpHttpSpanExporter()),
    resource: Resource({'service.name': 'example'}),
  );
  Trace.configure(provider);
  await Trace.tracer.trace('example-operation', () async {});
  await provider.shutdown();
}
