import 'package:obsi/obsi.dart';

Future<void> main() async {
  final provider = TracerProvider(
    processor: SimpleSpanProcessor(const ConsoleSpanExporter()),
  );
  Trace.configure(provider);

  await Trace.tracer.trace(
    'load-user',
    attributes: {'user.id': '42'},
    () async {
      await Future<void>.delayed(const Duration(milliseconds: 10));
      Trace.tracer.traceSync('map-user', () {});
    },
  );

  await provider.shutdown();
}
