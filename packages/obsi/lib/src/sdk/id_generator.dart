import 'dart:math';

/// Represents id generator.
abstract interface class IdGenerator {
  /// Performs generate trace id.
  String generateTraceId();

  /// Performs generate span id.
  String generateSpanId();
}

/// Represents random id generator.
final class RandomIdGenerator implements IdGenerator {
  /// Creates a instance.
  RandomIdGenerator({Random? random}) : _random = random ?? Random.secure();

  final Random _random;

  /// Performs generate trace id.
  @override
  String generateTraceId() => _hex(16);

  /// Performs generate span id.
  @override
  String generateSpanId() => _hex(8);

  String _hex(int byteCount) {
    final buffer = StringBuffer();
    var nonZero = false;
    for (var index = 0; index < byteCount; index++) {
      final byte = _random.nextInt(256);
      nonZero = nonZero || byte != 0;
      buffer.write(byte.toRadixString(16).padLeft(2, '0'));
    }
    return nonZero ? buffer.toString() : _hex(byteCount);
  }
}
