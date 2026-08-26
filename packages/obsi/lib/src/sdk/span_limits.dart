/// Represents span limits.
final class SpanLimits {
  /// Creates a instance.
  const SpanLimits({
    this.attributeCountLimit = 128,
    this.eventCountLimit = 128,
    this.linkCountLimit = 128,
    this.attributePerEventCountLimit = 128,
    this.attributePerLinkCountLimit = 128,
  });

  /// The attribute count limit.
  final int attributeCountLimit;

  /// The event count limit.
  final int eventCountLimit;

  /// The link count limit.
  final int linkCountLimit;

  /// The attribute per event count limit.
  final int attributePerEventCountLimit;

  /// The attribute per link count limit.
  final int attributePerLinkCountLimit;

  /// Performs validate.
  void validate() {
    final values = {
      'attributeCountLimit': attributeCountLimit,
      'eventCountLimit': eventCountLimit,
      'linkCountLimit': linkCountLimit,
      'attributePerEventCountLimit': attributePerEventCountLimit,
      'attributePerLinkCountLimit': attributePerLinkCountLimit,
    };
    for (final entry in values.entries) {
      if (entry.value < 0) throw ArgumentError.value(entry.value, entry.key);
    }
  }
}
