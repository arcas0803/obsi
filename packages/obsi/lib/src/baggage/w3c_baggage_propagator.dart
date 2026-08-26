import 'baggage.dart';
import 'baggage_propagator.dart';

/// Represents w3 cbaggage propagator.
final class W3CBaggagePropagator implements BaggagePropagator {
  /// Creates a instance.
  const W3CBaggagePropagator({
    this.maxEntries = 64,
    this.maxHeaderLength = 8192,
    this.maxEntryLength = 4096,
  });

  /// The max entries.
  final int maxEntries;

  /// The max header length.
  final int maxHeaderLength;

  /// The max entry length.
  final int maxEntryLength;

  void _validateLimits() {
    if (maxEntries <= 0 || maxEntries > 180) {
      throw ArgumentError.value(maxEntries, 'maxEntries');
    }
    if (maxHeaderLength <= 0) {
      throw ArgumentError.value(maxHeaderLength, 'maxHeaderLength');
    }
    if (maxEntryLength <= 0 || maxEntryLength > maxHeaderLength) {
      throw ArgumentError.value(maxEntryLength, 'maxEntryLength');
    }
  }

  /// Performs inject.
  @override
  void inject(Baggage baggage, Map<String, String> carrier) {
    _validateLimits();
    final members = <String>[];
    var length = 0;
    for (final entry in baggage.entries.entries.take(maxEntries)) {
      if (!_token.hasMatch(entry.key)) continue;
      final key = entry.key;
      final value = Uri.encodeComponent(entry.value.value);
      final metadata = entry.value.metadata;
      if (metadata != null && !_validProperties(metadata)) continue;
      final member = '$key=$value${metadata == null ? '' : ';$metadata'}';
      if (member.length > maxEntryLength) continue;
      final addedLength = member.length + (members.isEmpty ? 0 : 1);
      if (length + addedLength > maxHeaderLength) break;
      members.add(member);
      length += addedLength;
    }
    if (members.isNotEmpty) carrier['baggage'] = members.join(',');
  }

  /// Performs extract.
  @override
  Baggage extract(Map<String, String> carrier) {
    _validateLimits();
    final header = _header(carrier, 'baggage');
    if (header == null ||
        header.length > maxHeaderLength ||
        header.codeUnits.any((unit) => unit > 0x7f)) {
      return Baggage.empty;
    }
    final entries = <String, BaggageEntry>{};
    for (final rawMember in header.split(',')) {
      if (entries.length >= maxEntries) break;
      final member = rawMember.trim();
      if (member.isEmpty || member.length > maxEntryLength) continue;
      final separator = member.indexOf('=');
      if (separator <= 0) continue;
      final rawKey = member.substring(0, separator).trim();
      if (!_token.hasMatch(rawKey)) continue;
      final remainder = member.substring(separator + 1);
      final metadataStart = remainder.indexOf(';');
      final rawValue = metadataStart < 0
          ? remainder.trim()
          : remainder.substring(0, metadataStart).trim();
      final metadata = metadataStart < 0
          ? null
          : remainder.substring(metadataStart + 1).trim();
      if (metadata != null &&
          metadata.isNotEmpty &&
          !_validProperties(metadata)) {
        continue;
      }
      try {
        final key = rawKey;
        final value = Uri.decodeComponent(rawValue);
        if (key.isEmpty || entries.containsKey(key)) continue;
        entries[key] = BaggageEntry(
          value,
          metadata: metadata?.isEmpty == true ? null : metadata,
        );
      } on ArgumentError {
        continue;
      } on FormatException {
        continue;
      }
    }
    return Baggage(entries);
  }

  static String? _header(Map<String, String> carrier, String name) {
    for (final entry in carrier.entries) {
      if (entry.key.toLowerCase() == name) return entry.value;
    }
    return null;
  }

  static final RegExp _token = RegExp(r"^[!#$%&'*+.^_`|~0-9A-Za-z-]+$");

  static bool _validProperties(String value) {
    for (final property in value.split(';')) {
      final trimmed = property.trim();
      if (trimmed.isEmpty) return false;
      final separator = trimmed.indexOf('=');
      final key = separator < 0
          ? trimmed
          : trimmed.substring(0, separator).trim();
      if (!_token.hasMatch(key)) return false;
      if (separator >= 0) {
        final propertyValue = trimmed.substring(separator + 1).trim();
        if (propertyValue.codeUnits.any(
          (unit) =>
              unit < 0x21 ||
              unit > 0x7e ||
              unit == 0x22 ||
              unit == 0x2c ||
              unit == 0x3b ||
              unit == 0x5c,
        )) {
          return false;
        }
      }
    }
    return true;
  }
}
