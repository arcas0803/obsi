import 'package:obsi/obsi.dart';

Future<void> main() async {
  const iterations = 100000;
  _measure(10000, () => Trace.tracer.traceSync('warmup', () {}));
  final noOp = _measure(iterations, () {
    Trace.tracer.traceSync('operation', () {});
  });

  final provider = TracerProvider(processor: _DiscardingProcessor());
  Trace.configure(provider);
  _measure(10000, () => Trace.tracer.traceSync('warmup', () {}));
  final sampled = _measure(iterations, () {
    Trace.tracer.traceSync('operation', () {});
  });
  await provider.shutdown();

  // ignore: avoid_print
  print('no-op: ${noOp.inMicroseconds / iterations} us/op');
  // ignore: avoid_print
  print('sampled: ${sampled.inMicroseconds / iterations} us/op');
}

Duration _measure(int iterations, void Function() operation) {
  final stopwatch = Stopwatch()..start();
  for (var index = 0; index < iterations; index++) {
    operation();
  }
  return stopwatch.elapsed;
}

final class _DiscardingProcessor implements SpanProcessor {
  @override
  void onEnd(SpanData span) {}
  @override
  void onStart(Span span) {}
  @override
  Future<void> forceFlush() async {}
  @override
  Future<void> shutdown() async {}
}
