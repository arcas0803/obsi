import '../api/tracer.dart';
import '../common/instrumentation_scope.dart';
import '../common/diagnostics.dart';
import '../common/resource.dart';
import '../common/redaction.dart';
import '../processing/span_processor.dart';
import 'default_tracer.dart';
import 'id_generator.dart';
import 'sampler.dart';
import 'span_limits.dart';

/// Represents tracer provider.
final class TracerProvider {
  /// Creates a instance.
  TracerProvider({
    required this.processor,
    this.sampler = const ParentBasedSampler(),
    Resource? resource,
    this.spanLimits = const SpanLimits(),
    IdGenerator? idGenerator,
    this.onInternalError,
    this.attributeRedactor,
  }) : resource = resource ?? Resource.defaultResource,
       _idGenerator = idGenerator ?? RandomIdGenerator() {
    spanLimits.validate();
    tracer = getTracer('obsi.default');
  }

  /// The processor.
  final SpanProcessor processor;

  /// The sampler.
  final Sampler sampler;

  /// The resource.
  final Resource resource;

  /// The span limits.
  final SpanLimits spanLimits;
  final IdGenerator _idGenerator;

  /// The on internal error.
  final TelemetryErrorHandler? onInternalError;

  /// The attribute redactor.
  final AttributeRedactor? attributeRedactor;

  /// The tracer.
  late final Tracer tracer;
  Future<void>? _shutdownFuture;

  /// Performs get tracer.
  Tracer getTracer(
    String name, {
    String? version,
    String? schemaUrl,
    Map<String, Object?> attributes = const {},
  }) => DefaultTracer(
    processor: processor,
    sampler: sampler,
    idGenerator: _idGenerator,
    resource: resource,
    instrumentationScope: InstrumentationScope(
      name,
      version: version,
      schemaUrl: schemaUrl,
      attributes: attributes,
    ),
    spanLimits: spanLimits,
    onInternalError: onInternalError,
    attributeRedactor: attributeRedactor,
  );

  /// Performs force flush.
  Future<void> forceFlush() => _shutdownFuture ?? processor.forceFlush();

  /// Performs shutdown.
  Future<void> shutdown() => _shutdownFuture ??= processor.shutdown();
}
