import 'attributes.dart';

/// Represents instrumentation scope.
final class InstrumentationScope {
  /// Creates a instance.
  InstrumentationScope(
    this.name, {
    this.version,
    this.schemaUrl,
    Map<String, Object?> attributes = const {},
  }) : attributes = validatedAttributes(attributes) {
    if (name.isEmpty) throw ArgumentError.value(name, 'name');
  }

  /// The name.
  final String name;

  /// The version.
  final String? version;

  /// The schema url.
  final String? schemaUrl;

  /// The attributes.
  final Map<String, Object?> attributes;
}
