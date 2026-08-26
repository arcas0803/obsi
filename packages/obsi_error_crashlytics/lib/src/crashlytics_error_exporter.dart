import 'dart:convert';

import 'package:firebase_crashlytics/firebase_crashlytics.dart';
import 'package:obsi/obsi.dart';

/// Minimal boundary around Firebase Crashlytics, useful for testing and DI.
abstract interface class CrashlyticsClient {
  /// Performs record error.
  Future<void> recordError(
    Object exception,
    StackTrace? stackTrace, {
    Object? reason,
    Iterable<Object> information = const [],
    bool fatal = false,
  });

  /// Performs log.
  Future<void> log(String message);

  /// Performs set custom key.
  Future<void> setCustomKey(String key, Object value);

  /// Performs set user identifier.
  Future<void> setUserIdentifier(String identifier);

  /// Performs send unsent reports.
  Future<void> sendUnsentReports();
}

/// Represents firebase crashlytics client.
final class FirebaseCrashlyticsClient implements CrashlyticsClient {
  /// Creates a instance.
  FirebaseCrashlyticsClient([FirebaseCrashlytics? instance])
    : _instance = instance ?? FirebaseCrashlytics.instance;

  final FirebaseCrashlytics _instance;

  /// Performs record error.
  @override
  Future<void> recordError(
    Object exception,
    StackTrace? stackTrace, {
    Object? reason,
    Iterable<Object> information = const [],
    bool fatal = false,
  }) => _instance.recordError(
    exception,
    stackTrace,
    reason: reason,
    information: information,
    printDetails: false,
    fatal: fatal,
  );

  /// Performs log.
  @override
  Future<void> log(String message) => _instance.log(message);

  /// Performs set custom key.
  @override
  Future<void> setCustomKey(String key, Object value) =>
      _instance.setCustomKey(key, value);

  /// Performs set user identifier.
  @override
  Future<void> setUserIdentifier(String identifier) =>
      _instance.setUserIdentifier(identifier);

  /// Performs send unsent reports.
  @override
  Future<void> sendUnsentReports() => _instance.sendUnsentReports();
}

/// Exports Obsi reports to Firebase Crashlytics.
///
/// Operations are serialized because Crashlytics custom keys are global state.
final class CrashlyticsErrorExporter implements ErrorExporter {
  /// Creates a instance.
  CrashlyticsErrorExporter({
    CrashlyticsClient? client,
    this.sendUnsentReportsOnFlush = false,
    this.maxCustomKeys = 64,
    this.maxValueBytes = 1024,
    this.maxBreadcrumbs = 100,
  }) : _client = client ?? FirebaseCrashlyticsClient() {
    if (maxCustomKeys <= 0 || maxCustomKeys > 64) {
      throw ArgumentError.value(maxCustomKeys, 'maxCustomKeys');
    }
    if (maxValueBytes <= 0) {
      throw ArgumentError.value(maxValueBytes, 'maxValueBytes');
    }
    if (maxBreadcrumbs < 0) {
      throw ArgumentError.value(maxBreadcrumbs, 'maxBreadcrumbs');
    }
  }

  final CrashlyticsClient _client;

  /// The send unsent reports on flush.
  final bool sendUnsentReportsOnFlush;

  /// The max custom keys.
  final int maxCustomKeys;

  /// The max value bytes.
  final int maxValueBytes;

  /// The max breadcrumbs.
  final int maxBreadcrumbs;
  Future<void> _tail = Future.value();
  Set<String> _activeKeys = const {};
  bool _shutdown = false;
  Future<void>? _shutdownFuture;
  int _exportedReports = 0;
  int _failedReports = 0;

  /// The exported reports.
  int get exportedReports => _exportedReports;

  /// The failed reports.
  int get failedReports => _failedReports;

  /// Performs export.
  @override
  Future<void> export(ErrorReport report) {
    if (_shutdown) return Future.error(StateError('Exporter is shut down'));
    final operation = _tail
        .then((_) => _exportOne(report))
        .then(
          (_) {
            _exportedReports++;
          },
          onError: (Object error, StackTrace stackTrace) {
            _failedReports++;
            Error.throwWithStackTrace(error, stackTrace);
          },
        );
    _tail = operation.catchError((_) {});
    return operation;
  }

  Future<void> _exportOne(ErrorReport report) async {
    await _client.setUserIdentifier(
      _limitUtf8(report.user?.id ?? '', maxValueBytes),
    );

    final keys = <String, Object>{};
    for (final entry in _customKeys(report).entries) {
      if (keys.length >= maxCustomKeys) break;
      final key = _uniqueKey(entry.key, keys.keys, maxValueBytes);
      keys[key] = _crashlyticsValue(entry.value, maxValueBytes);
    }
    final knownKeys = _activeKeys.toSet();
    for (final staleKey in _activeKeys.difference(keys.keys.toSet())) {
      await _client.setCustomKey(staleKey, '');
      knownKeys.remove(staleKey);
      _activeKeys = Set.unmodifiable(knownKeys);
    }
    for (final entry in keys.entries) {
      await _client.setCustomKey(entry.key, entry.value);
      knownKeys.add(entry.key);
      _activeKeys = Set.unmodifiable(knownKeys);
    }
    final breadcrumbStart = report.breadcrumbs.length > maxBreadcrumbs
        ? report.breadcrumbs.length - maxBreadcrumbs
        : 0;
    for (final breadcrumb in report.breadcrumbs.skip(breadcrumbStart)) {
      await _client.log(
        _limitUtf8(
          '[${breadcrumb.category}] ${breadcrumb.message ?? ''} '
          '${jsonEncode(breadcrumb.data)}',
          maxValueBytes,
        ),
      );
    }
    await _client.recordError(
      report.exception,
      report.stackTrace,
      reason: report.reason ?? report.message,
      information: [
        'obsi.error_id=${report.id.value}',
        'mechanism=${report.mechanism.name}',
        'handled=${report.handled}',
        'severity=${report.severity.name}',
        if (report.spanContext case final span?) ...[
          'trace_id=${span.traceId}',
          'span_id=${span.spanId}',
        ],
      ],
      fatal: report.fatal,
    );
  }

  /// Performs force flush.
  @override
  Future<void> forceFlush() async {
    await _tail;
    if (sendUnsentReportsOnFlush) await _client.sendUnsentReports();
  }

  /// Performs shutdown.
  @override
  Future<void> shutdown() => _shutdownFuture ??= _doShutdown();

  Future<void> _doShutdown() async {
    _shutdown = true;
    await forceFlush();
  }
}

Map<String, Object?> _customKeys(ErrorReport report) => {
  'obsi.error_id': report.id.value,
  'obsi.severity': report.severity.name,
  'obsi.mechanism': report.mechanism.name,
  'obsi.handled': report.handled,
  'obsi.fatal': report.fatal,
  'obsi.integration': 'obsi_error_crashlytics',
  'obsi.attachment_count': report.attachments.length,
  if (report.spanContext case final span?) ...{
    'obsi.trace_id': span.traceId,
    'obsi.span_id': span.spanId,
  },
  for (final entry in report.tags.entries) 'tag.${entry.key}': entry.value,
  for (final entry in report.attributes.entries)
    'attribute.${entry.key}': entry.value,
  for (final entry in report.resource.attributes.entries)
    'resource.${entry.key}': entry.value,
  for (final context in report.contexts.entries)
    'context.${context.key}': jsonEncode(context.value),
};

Object _crashlyticsValue(Object? value, int limit) {
  if (value is num || value is bool) return value as Object;
  if (value is String) return _limitUtf8(value, limit);
  return _limitUtf8(jsonEncode(value), limit);
}

String _limitUtf8(String value, int limit) {
  if (utf8.encode(value).length <= limit) return value;
  final buffer = StringBuffer();
  var bytes = 0;
  for (final rune in value.runes) {
    final character = String.fromCharCode(rune);
    final size = utf8.encode(character).length;
    if (bytes + size > limit) break;
    buffer.write(character);
    bytes += size;
  }
  return buffer.toString();
}

String _uniqueKey(String value, Iterable<String> existing, int limit) {
  var candidate = _limitUtf8(value, limit);
  if (!existing.contains(candidate)) return candidate;
  final suffix = '.${_fnv1a(value).toRadixString(16)}';
  final prefixLimit = limit - utf8.encode(suffix).length;
  candidate = '${_limitUtf8(value, prefixLimit)}$suffix';
  var counter = 1;
  while (existing.contains(candidate)) {
    final numberedSuffix = '$suffix.$counter';
    candidate =
        '${_limitUtf8(value, limit - utf8.encode(numberedSuffix).length)}'
        '$numberedSuffix';
    counter++;
  }
  return candidate;
}

int _fnv1a(String value) {
  var hash = 0x811c9dc5;
  for (final byte in utf8.encode(value)) {
    hash ^= byte;
    hash = (hash * 0x01000193) & 0xffffffff;
  }
  return hash;
}
