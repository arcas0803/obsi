/// Creates an immutable snapshot of JSON-like structured data.
///
/// Maps must use string keys. Cycles and structures deeper than [maxDepth]
/// are rejected so exporters cannot recurse forever.
Object? immutableStructuredValue(Object? value, {int maxDepth = 32}) =>
    _copy(value, Set<Object>.identity(), 0, maxDepth);

/// Performs immutable structured map.
Map<String, Object?> immutableStructuredMap(
  Map<String, Object?> value, {
  int maxDepth = 32,
}) => Map<String, Object?>.unmodifiable(
  _copy(value, Set<Object>.identity(), 0, maxDepth)! as Map,
);

Object? _copy(Object? value, Set<Object> active, int depth, int maxDepth) {
  if (depth > maxDepth) {
    throw ArgumentError.value(value, 'value', 'Maximum depth exceeded');
  }
  if (value is Map) {
    if (!active.add(value)) {
      throw ArgumentError.value(value, 'value', 'Cycles are not supported');
    }
    final copy = <String, Object?>{};
    for (final entry in value.entries) {
      if (entry.key is! String) {
        throw ArgumentError.value(
          entry.key,
          'value',
          'Map keys must be strings',
        );
      }
      copy[entry.key as String] = _copy(
        entry.value,
        active,
        depth + 1,
        maxDepth,
      );
    }
    active.remove(value);
    return Map<String, Object?>.unmodifiable(copy);
  }
  if (value is Iterable) {
    if (!active.add(value)) {
      throw ArgumentError.value(value, 'value', 'Cycles are not supported');
    }
    final copy = List<Object?>.unmodifiable(
      value.map((item) => _copy(item, active, depth + 1, maxDepth)),
    );
    active.remove(value);
    return copy;
  }
  if (value == null || value is String || value is bool || value is int) {
    return value;
  }
  if (value is double && value.isFinite) return value;
  throw ArgumentError.value(
    value,
    'value',
    'Only finite JSON-compatible values are supported',
  );
}
