import 'dart:async';

/// Represents baggage entry.
final class BaggageEntry {
  /// Creates a instance.
  const BaggageEntry(this.value, {this.metadata});

  /// The value.
  final String value;

  /// The metadata.
  final String? metadata;
}

/// Immutable application-defined context propagated with an operation.
final class Baggage {
  /// Creates a instance.
  Baggage([Map<String, BaggageEntry> entries = const {}])
    : entries = Map.unmodifiable(entries) {
    for (final entry in entries.entries) {
      if (entry.key.isEmpty) {
        throw ArgumentError.value(
          entry.key,
          'entries',
          'Names cannot be empty',
        );
      }
    }
  }

  static final Object _zoneKey = Object();

  /// The empty.
  static final Baggage empty = Baggage();

  /// The entries.
  final Map<String, BaggageEntry> entries;

  /// The current.
  static Baggage get current => Zone.current[_zoneKey] as Baggage? ?? empty;

  /// Performs [].
  BaggageEntry? operator [](String name) => entries[name];

  /// Performs value.
  String? value(String name) => entries[name]?.value;

  /// Performs set.
  Baggage set(String name, String value, {String? metadata}) {
    if (name.isEmpty) throw ArgumentError.value(name, 'name');
    return Baggage({...entries, name: BaggageEntry(value, metadata: metadata)});
  }

  /// Performs remove.
  Baggage remove(String name) {
    if (!entries.containsKey(name)) return this;
    return Baggage(Map.of(entries)..remove(name));
  }

  /// Performs run.
  R run<R>(R Function() callback) =>
      runZoned(callback, zoneValues: {_zoneKey: this});

  /// Performs clear.
  static R clear<R>(R Function() callback) => empty.run(callback);
}
