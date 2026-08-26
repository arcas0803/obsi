import 'dart:async';

import 'error_api.dart';
import 'error_manager.dart';
import 'error_scope.dart';
import 'isolate_error_listener.dart';

/// Global facade for capturing errors and managing zone-local error scopes.
final class Errors {
  Errors._();

  static ErrorManager? _manager;
  static final ErrorScope _fallbackScope = ErrorScope();

  /// Currently configured manager, or `null` when reporting is disabled.
  static ErrorManager? get manager => _manager;

  /// Zone-local scope, configured root scope, or an in-memory fallback scope.
  static ErrorScope get currentScope =>
      ErrorScope.zoneCurrent ?? _manager?.rootScope ?? _fallbackScope;

  /// Installs [manager] without shutting down a previously configured manager.
  static void configure(ErrorManager manager) => _manager = manager;

  /// Detaches the current manager without flushing or shutting it down.
  static void disable() => _manager = null;

  /// Captures [exception], returning its ID when processors accept the report.
  ///
  /// Returns `null` when reporting is disabled, shut down, queue-limited, or a
  /// processor drops or fails the report. A non-null ID does not guarantee
  /// delivery by the remote backend.
  static Future<ErrorId?> captureException(
    Object exception, {
    StackTrace? stackTrace,
    ErrorSeverity severity = ErrorSeverity.error,
    bool fatal = false,
    bool handled = true,
    ErrorMechanism mechanism = ErrorMechanism.manual,
    String? reason,
    Map<String, Object?> attributes = const {},
    Map<String, String> tags = const {},
    Map<String, Map<String, Object?>> contexts = const {},
    List<String>? fingerprint,
    List<ErrorAttachment> attachments = const [],
    ErrorUser? user,
  }) =>
      _manager?.captureException(
        exception,
        stackTrace: stackTrace,
        severity: severity,
        fatal: fatal,
        handled: handled,
        mechanism: mechanism,
        reason: reason,
        attributes: attributes,
        tags: tags,
        contexts: contexts,
        fingerprint: fingerprint,
        attachments: attachments,
        user: user,
      ) ??
      Future.value(null);

  /// Adds [breadcrumb] to the current zone-local scope.
  static void addBreadcrumb(ErrorBreadcrumb breadcrumb) =>
      currentScope.addBreadcrumb(breadcrumb);

  /// Runs [callback] in a child scope containing the supplied context.
  ///
  /// The parent scope is not mutated and is restored when the callback exits.
  static R withScope<R>(
    R Function() callback, {
    ErrorUser? user,
    Map<String, String> tags = const {},
    Map<String, Map<String, Object?>> contexts = const {},
    List<String>? fingerprint,
    List<ErrorAttachment> attachments = const [],
  }) => currentScope
      .fork(
        user: user,
        tags: tags,
        contexts: contexts,
        fingerprint: fingerprint,
        attachments: attachments,
      )
      .run(callback);

  /// Runs [callback], captures any error, then rethrows it with its stack trace.
  static Future<T> guard<T>(
    FutureOr<T> Function() callback, {
    bool fatal = true,
    bool handled = false,
    ErrorMechanism mechanism = ErrorMechanism.zone,
  }) async {
    try {
      return await callback();
    } catch (error, stackTrace) {
      await captureException(
        error,
        stackTrace: stackTrace,
        fatal: fatal,
        handled: handled,
        mechanism: mechanism,
      );
      Error.throwWithStackTrace(error, stackTrace);
    }
  }

  /// Runs [callback] in a guarded zone that captures uncaught async errors.
  ///
  /// Zone errors are swallowed after [onError] by default. Set [rethrowError]
  /// to rethrow them from the zone error handler.
  static R? runGuarded<R>(
    R Function() callback, {
    bool fatal = true,
    bool rethrowError = false,
    void Function(Object error, StackTrace stackTrace)? onError,
  }) => runZonedGuarded(callback, (error, stackTrace) {
    unawaited(
      captureException(
        error,
        stackTrace: stackTrace,
        fatal: fatal,
        handled: false,
        mechanism: ErrorMechanism.zone,
      ),
    );
    onError?.call(error, stackTrace);
    if (rethrowError) Error.throwWithStackTrace(error, stackTrace);
  });

  /// Registers an error listener for the current isolate.
  ///
  /// The caller owns the returned listener and must close it.
  static ErrorIsolateListener listenToIsolateErrors() =>
      ErrorIsolateListener.start();
}
