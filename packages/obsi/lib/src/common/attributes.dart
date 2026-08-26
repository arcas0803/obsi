/// Defines the attributes type.
typedef Attributes = Map<String, Object?>;

/// Values accepted by all Obsi telemetry signals.
bool isValidAttributeValue(Object? value) {
  if (value is String ||
      value is bool ||
      value is int ||
      value is double && value.isFinite) {
    return true;
  }
  if (value is List<Object?>) {
    if (value.isEmpty) return true;
    final firstType = value.first.runtimeType;
    return value.every(
      (item) =>
          item != null &&
          item.runtimeType == firstType &&
          (item is String ||
              item is bool ||
              item is int ||
              item is double && item.isFinite),
    );
  }
  return false;
}

/// Performs validated attributes.
Map<String, Object?> validatedAttributes(
  Map<String, Object?> attributes, {
  int? limit,
}) {
  final result = <String, Object?>{};
  for (final entry in attributes.entries) {
    if (limit != null && result.length >= limit) break;
    if (entry.key.isEmpty) {
      throw ArgumentError.value(
        entry.key,
        'attributes',
        'Keys cannot be empty',
      );
    }
    if (!isValidAttributeValue(entry.value)) {
      throw ArgumentError.value(
        entry.value,
        entry.key,
        'Unsupported attribute value',
      );
    }
    result[entry.key] = entry.value is List
        ? List<Object?>.unmodifiable(entry.value as List)
        : entry.value;
  }
  return Map.unmodifiable(result);
}
