import 'dart:async';

import 'error_api.dart';
import '../common/structured_data.dart';

/// Represents error scope.
final class ErrorScope {
  /// Creates a instance.
  ErrorScope({
    this.user,
    Map<String, String> tags = const {},
    Map<String, Map<String, Object?>> contexts = const {},
    List<String> fingerprint = const [],
    List<ErrorAttachment> attachments = const [],
    this.breadcrumbLimit = 100,
    List<ErrorBreadcrumb> breadcrumbs = const [],
  }) : tags = Map.unmodifiable(tags),
       contexts = Map.unmodifiable({
         for (final entry in contexts.entries)
           entry.key: immutableStructuredMap(entry.value),
       }),
       fingerprint = List.unmodifiable(fingerprint),
       attachments = List.unmodifiable(attachments),
       _breadcrumbs = List.of(
         breadcrumbs.skip(
           breadcrumbs.length > breadcrumbLimit
               ? breadcrumbs.length - breadcrumbLimit
               : 0,
         ),
       ) {
    if (breadcrumbLimit < 0) {
      throw ArgumentError.value(breadcrumbLimit, 'breadcrumbLimit');
    }
  }

  static final Object _zoneKey = Object();

  /// The empty.
  static final ErrorScope empty = ErrorScope(breadcrumbLimit: 0);

  /// The user.
  final ErrorUser? user;

  /// The tags.
  final Map<String, String> tags;

  /// The contexts.
  final Map<String, Map<String, Object?>> contexts;

  /// The fingerprint.
  final List<String> fingerprint;

  /// The attachments.
  final List<ErrorAttachment> attachments;

  /// The breadcrumb limit.
  final int breadcrumbLimit;
  final List<ErrorBreadcrumb> _breadcrumbs;

  /// The zone current.
  static ErrorScope? get zoneCurrent => Zone.current[_zoneKey] as ErrorScope?;

  /// The breadcrumbs.
  List<ErrorBreadcrumb> get breadcrumbs => List.unmodifiable(_breadcrumbs);

  /// Performs add breadcrumb.
  void addBreadcrumb(ErrorBreadcrumb breadcrumb) {
    if (breadcrumbLimit <= 0) return;
    if (_breadcrumbs.length == breadcrumbLimit) _breadcrumbs.removeAt(0);
    _breadcrumbs.add(breadcrumb);
  }

  /// Performs fork.
  ErrorScope fork({
    ErrorUser? user,
    Map<String, String> tags = const {},
    Map<String, Map<String, Object?>> contexts = const {},
    List<String>? fingerprint,
    List<ErrorAttachment> attachments = const [],
    int? breadcrumbLimit,
  }) => ErrorScope(
    user: user ?? this.user,
    tags: {...this.tags, ...tags},
    contexts: {...this.contexts, ...contexts},
    fingerprint: fingerprint ?? this.fingerprint,
    attachments: [...this.attachments, ...attachments],
    breadcrumbLimit: breadcrumbLimit ?? this.breadcrumbLimit,
    breadcrumbs: _breadcrumbs,
  );

  /// Performs run.
  R run<R>(R Function() callback) =>
      runZoned(callback, zoneValues: {_zoneKey: this});
}
