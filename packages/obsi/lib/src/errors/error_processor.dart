import 'dart:async';
import 'dart:math';

import 'error_api.dart';

/// Represents error processor.
abstract interface class ErrorProcessor {
  /// Performs process.
  FutureOr<ErrorReport?> process(ErrorReport report);
}

/// Represents error sampling processor.
final class ErrorSamplingProcessor implements ErrorProcessor {
  /// Creates a instance.
  ErrorSamplingProcessor(this.sampleRate, {Random? random})
    : _random = random ?? Random() {
    if (!sampleRate.isFinite || sampleRate < 0 || sampleRate > 1) {
      throw ArgumentError.value(sampleRate, 'sampleRate');
    }
  }

  /// The sample rate.
  final double sampleRate;
  final Random _random;

  /// Performs process.
  @override
  ErrorReport? process(ErrorReport report) =>
      report.fatal || _random.nextDouble() < sampleRate ? report : null;
}

/// Represents error deduplication processor.
final class ErrorDeduplicationProcessor implements ErrorProcessor {
  /// Creates a instance.
  ErrorDeduplicationProcessor({
    this.window = const Duration(seconds: 5),
    this.maxEntries = 2048,
    this.maxFingerprintLength = 1024,
  }) {
    if (window.isNegative) throw ArgumentError.value(window, 'window');
    if (maxEntries <= 0) throw ArgumentError.value(maxEntries, 'maxEntries');
    if (maxFingerprintLength <= 0) {
      throw ArgumentError.value(maxFingerprintLength, 'maxFingerprintLength');
    }
  }

  /// The window.
  final Duration window;

  /// The max entries.
  final int maxEntries;

  /// The max fingerprint length.
  final int maxFingerprintLength;
  final Map<String, DateTime> _seen = {};

  /// Performs process.
  @override
  ErrorReport? process(ErrorReport report) {
    if (report.fatal) return report;
    final now = report.timestamp;
    _seen.removeWhere((_, timestamp) {
      final age = now.difference(timestamp);
      return age.isNegative || age > window;
    });
    var key = report.fingerprint.isNotEmpty
        ? report.fingerprint.join('|')
        : '${report.exception.runtimeType}|${report.message}|'
              '${report.stackTrace?.toString().split('\n').firstOrNull ?? ''}';
    if (key.length > maxFingerprintLength) {
      key = key.substring(0, maxFingerprintLength);
    }
    final previous = _seen[key];
    if (previous != null && now.difference(previous) <= window) return null;
    if (_seen.length >= maxEntries) _seen.remove(_seen.keys.first);
    _seen[key] = now;
    return report;
  }
}

/// Represents error rate limit processor.
final class ErrorRateLimitProcessor implements ErrorProcessor {
  /// Creates a instance.
  ErrorRateLimitProcessor({
    this.maxReports = 100,
    this.interval = const Duration(minutes: 1),
  }) {
    if (maxReports <= 0) throw ArgumentError.value(maxReports, 'maxReports');
    if (interval <= Duration.zero) {
      throw ArgumentError.value(interval, 'interval');
    }
  }

  /// The max reports.
  final int maxReports;

  /// The interval.
  final Duration interval;
  final List<DateTime> _accepted = [];

  /// Performs process.
  @override
  ErrorReport? process(ErrorReport report) {
    if (report.fatal) return report;
    _accepted.removeWhere((timestamp) {
      final age = report.timestamp.difference(timestamp);
      return age.isNegative || age > interval;
    });
    if (_accepted.length >= maxReports) return null;
    _accepted.add(report.timestamp);
    return report;
  }
}

/// Represents error sanitizing processor.
final class ErrorSanitizingProcessor implements ErrorProcessor {
  /// Creates a instance.
  ErrorSanitizingProcessor({
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

  /// Performs process.
  @override
  ErrorReport process(ErrorReport report) => report.copyWith(
    attributes: _sanitizeMap(report.attributes),
    tags: {
      for (final entry in report.tags.entries)
        entry.key: _isSensitive(entry.key) ? replacement : entry.value,
    },
    contexts: {
      for (final entry in report.contexts.entries)
        entry.key: _sanitizeMap(entry.value),
    },
    breadcrumbs: [
      for (final breadcrumb in report.breadcrumbs)
        ErrorBreadcrumb(
          timestamp: breadcrumb.timestamp,
          category: breadcrumb.category,
          message: breadcrumb.message,
          level: breadcrumb.level,
          data: _sanitizeMap(breadcrumb.data),
        ),
    ],
    user: report.user == null
        ? null
        : ErrorUser(
            id: report.user!.id,
            email: report.user!.email == null ? null : replacement,
            username: report.user!.username,
            ipAddress: report.user!.ipAddress,
            data: _sanitizeMap(report.user!.data),
          ),
  );

  Map<String, Object?> _sanitizeMap(Map<String, Object?> source) => {
    for (final entry in source.entries)
      entry.key: _isSensitive(entry.key)
          ? replacement
          : _sanitizeValue(entry.value),
  };

  Object? _sanitizeValue(Object? value) {
    if (value is Map) {
      return _sanitizeMap(Map<String, Object?>.from(value));
    }
    if (value is Iterable) {
      return [for (final item in value) _sanitizeValue(item)];
    }
    return value;
  }

  bool _isSensitive(String key) {
    final normalized = key.toLowerCase();
    return sensitiveKeys.any((pattern) => normalized.contains(pattern));
  }
}

/// Runs a final user-defined transformation before export.
final class ErrorBeforeSendProcessor implements ErrorProcessor {
  /// Creates a instance.
  const ErrorBeforeSendProcessor(this.callback);

  /// The callback.
  final FutureOr<ErrorReport?> Function(ErrorReport report) callback;

  /// Performs process.
  @override
  FutureOr<ErrorReport?> process(ErrorReport report) => callback(report);
}
