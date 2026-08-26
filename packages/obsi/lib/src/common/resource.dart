import 'attributes.dart';

/// Represents resource.
final class Resource {
  /// Creates a instance.
  Resource([Map<String, Object?> attributes = const {}])
    : attributes = validatedAttributes(attributes);

  /// The empty.
  static final Resource empty = Resource();

  /// SDK resource used when an application does not provide one explicitly.
  static final Resource defaultResource = Resource(const {
    'service.name': 'unknown_service:dart',
    'telemetry.sdk.name': 'obsi',
    'telemetry.sdk.language': 'dart',
    'telemetry.sdk.version': '1.0.0',
  });

  /// The attributes.
  final Map<String, Object?> attributes;

  /// Performs merge.
  Resource merge(Resource other) =>
      Resource({...attributes, ...other.attributes});
}
