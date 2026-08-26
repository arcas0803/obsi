import 'attributes.dart';

/// Defines the attribute redactor type.
typedef AttributeRedactor =
    Map<String, Object?> Function(Map<String, Object?> attributes);

/// Replaces values whose attribute keys contain a sensitive pattern.
final class SensitiveAttributeRedactor {
  /// Creates a instance.
  SensitiveAttributeRedactor({
    Iterable<Pattern> sensitiveKeys = const [
      'password',
      'passwd',
      'secret',
      'token',
      'authorization',
      'cookie',
      'email',
    ],
    this.replacement = '[Filtered]',
  }) : sensitiveKeys = List.unmodifiable(sensitiveKeys);

  /// The sensitive keys.
  final List<Pattern> sensitiveKeys;

  /// The replacement.
  final String replacement;

  /// Performs call.
  Map<String, Object?> call(Map<String, Object?> attributes) =>
      validatedAttributes({
        for (final entry in attributes.entries)
          entry.key: _isSensitive(entry.key) ? replacement : entry.value,
      });

  bool _isSensitive(String key) {
    final normalized = key.toLowerCase();
    return sensitiveKeys.any((pattern) => normalized.contains(pattern));
  }
}
