import '../api/span.dart';
import '../api/span_context.dart';
import '../common/attributes.dart';

/// Decision returned by a [Sampler].
enum SamplingDecision {
  /// The drop value.
  drop,

  /// The record only value.
  recordOnly,

  /// The record and sample value.
  recordAndSample,
}

/// Immutable input supplied before a span is created.
final class SamplingParameters {
  /// Creates a instance.
  SamplingParameters({
    required this.traceId,
    required this.name,
    required this.kind,
    required Map<String, Object?> attributes,
    required List<SpanLink> links,
    this.parent,
  }) : attributes = validatedAttributes(attributes),
       links = List.unmodifiable(links);

  /// The trace id.
  final String traceId;

  /// The name.
  final String name;

  /// The kind.
  final SpanKind kind;

  /// The attributes.
  final Map<String, Object?> attributes;

  /// The links.
  final List<SpanLink> links;

  /// The parent.
  final SpanContext? parent;
}

/// Sampling decision plus optional data to attach to the created span.
final class SamplingResult {
  /// Creates a instance.
  SamplingResult(
    this.decision, {
    Map<String, Object?> attributes = const {},
    this.traceState,
  }) : attributes = validatedAttributes(attributes);

  /// The drop.
  static final drop = SamplingResult(SamplingDecision.drop);

  /// The record only.
  static final recordOnly = SamplingResult(SamplingDecision.recordOnly);

  /// The record and sample.
  static final recordAndSample = SamplingResult(
    SamplingDecision.recordAndSample,
  );

  /// The decision.
  final SamplingDecision decision;

  /// The attributes.
  final Map<String, Object?> attributes;

  /// The trace state.
  final String? traceState;
}

/// Represents sampler.
abstract interface class Sampler {
  /// Performs sample.
  SamplingResult sample(SamplingParameters parameters);
}

/// Represents always on sampler.
final class AlwaysOnSampler implements Sampler {
  /// Creates a instance.
  const AlwaysOnSampler();

  /// Performs sample.
  @override
  SamplingResult sample(SamplingParameters parameters) =>
      SamplingResult.recordAndSample;
}

/// Represents always off sampler.
final class AlwaysOffSampler implements Sampler {
  /// Creates a instance.
  const AlwaysOffSampler();

  /// Performs sample.
  @override
  SamplingResult sample(SamplingParameters parameters) => SamplingResult.drop;
}

/// Deterministic head sampler based on the trace identifier.
final class TraceIdRatioBasedSampler implements Sampler {
  /// Creates a instance.
  TraceIdRatioBasedSampler(this.ratio) {
    if (!ratio.isFinite || ratio < 0 || ratio > 1) {
      throw ArgumentError.value(ratio, 'ratio', 'Must be between 0 and 1');
    }
  }

  /// The ratio.
  final double ratio;

  /// Performs sample.
  @override
  SamplingResult sample(SamplingParameters parameters) {
    if (ratio <= 0) return SamplingResult.drop;
    if (ratio >= 1) return SamplingResult.recordAndSample;
    // Thirteen hexadecimal digits fit exactly in JavaScript's integer range,
    // keeping decisions stable across Dart VM, Flutter, and web.
    final value = int.parse(parameters.traceId.substring(0, 13), radix: 16);
    const range = 0x10000000000000;
    return value < ratio * range
        ? SamplingResult.recordAndSample
        : SamplingResult.drop;
  }
}

/// Honors a valid parent's sampled flag and delegates root spans to [root].
final class ParentBasedSampler implements Sampler {
  /// Creates a instance.
  const ParentBasedSampler({this.root = const AlwaysOnSampler()});

  /// The root.
  final Sampler root;

  /// Performs sample.
  @override
  SamplingResult sample(SamplingParameters parameters) {
    final parent = parameters.parent;
    if (parent == null) return root.sample(parameters);
    return parent.sampled
        ? SamplingResult.recordAndSample
        : SamplingResult.drop;
  }
}
