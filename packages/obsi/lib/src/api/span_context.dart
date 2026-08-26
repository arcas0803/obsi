/// Immutable identity used to relate and propagate spans.
final class SpanContext {
  /// Creates a instance.
  const SpanContext({
    required this.traceId,
    required this.spanId,
    required this.sampled,
    this.traceState,
    this.isRemote = false,
  });

  /// The trace id.
  final String traceId;

  /// The span id.
  final String spanId;

  /// The sampled.
  final bool sampled;

  /// The trace state.
  final String? traceState;

  /// The is remote.
  final bool isRemote;

  /// The is valid.
  bool get isValid =>
      _isHex(traceId, 32) &&
      _isHex(spanId, 16) &&
      !_isAllZeros(traceId) &&
      !_isAllZeros(spanId);

  /// Performs ==.
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is SpanContext &&
          traceId == other.traceId &&
          spanId == other.spanId &&
          sampled == other.sampled &&
          traceState == other.traceState &&
          isRemote == other.isRemote;

  /// The hash code.
  @override
  int get hashCode =>
      Object.hash(traceId, spanId, sampled, traceState, isRemote);

  static bool _isHex(String value, int length) =>
      value.length == length && RegExp(r'^[0-9a-f]+$').hasMatch(value);

  static bool _isAllZeros(String value) =>
      value.codeUnits.every((unit) => unit == 0x30);
}
