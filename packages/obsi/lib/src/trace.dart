import 'api/tracer.dart';
import 'context/zone_trace_context.dart';
import 'sdk/noop.dart';
import 'sdk/tracer_provider.dart';

/// Global entry point. Tracing is disabled until [configure] is called.
final class Trace {
  Trace._();

  static Tracer _tracer = const NoopTracer();
  static TracerProvider? _provider;

  /// The tracer.
  static Tracer get tracer => _tracer;

  /// The provider.
  static TracerProvider? get provider => _provider;

  /// Performs configure.
  static void configure(TracerProvider provider) {
    _provider = provider;
    _tracer = provider.tracer;
  }

  /// Performs disable.
  static void disable() {
    _provider = null;
    _tracer = const NoopTracer();
  }

  /// Performs suppress.
  static R suppress<R>(R Function() callback) =>
      ZoneTraceContext.suppress(callback);
}
