import 'dart:async';
import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:obsi/obsi.dart';

/// Captures uncaught Flutter framework and root-isolate errors through Obsi.
final class ObsiFlutterErrorIntegration {
  static ObsiFlutterErrorIntegration? _active;

  FlutterExceptionHandler? _previousFlutterHandler;
  ErrorCallback? _previousPlatformHandler;
  bool _installed = false;

  /// Whether this instance currently owns Flutter's global error handlers.
  bool get isInstalled => _installed;

  /// Installs handlers for framework and root-isolate errors.
  ///
  /// Throws [StateError] if another instance owns the handlers, or when
  /// [requireConfiguredManager] is true and no Obsi error manager exists.
  /// When [preserveExistingHandlers] is true, captured errors are also passed
  /// to the handlers that were installed previously.
  void install({
    bool fatal = true,
    bool preserveExistingHandlers = true,
    bool requireConfiguredManager = true,
  }) {
    if (_installed) return;
    if (_active != null) {
      throw StateError('Another ObsiFlutterErrorIntegration is installed');
    }
    if (requireConfiguredManager && Errors.manager == null) {
      throw StateError('Configure Errors before installing the integration');
    }
    _installed = true;
    _active = this;
    _previousFlutterHandler = FlutterError.onError;
    _previousPlatformHandler = PlatformDispatcher.instance.onError;

    FlutterError.onError = (details) {
      unawaited(
        Errors.captureException(
          details.exception,
          stackTrace: details.stack,
          fatal: fatal,
          handled: false,
          mechanism: ErrorMechanism.flutterFramework,
          reason: details.context?.toDescription(),
          contexts: _flutterContexts(details),
        ),
      );
      if (preserveExistingHandlers) _previousFlutterHandler?.call(details);
    };
    PlatformDispatcher.instance.onError = (error, stackTrace) {
      unawaited(
        Errors.captureException(
          error,
          stackTrace: stackTrace,
          fatal: fatal,
          handled: false,
          mechanism: ErrorMechanism.platformDispatcher,
        ),
      );
      if (preserveExistingHandlers && _previousPlatformHandler != null) {
        return _previousPlatformHandler!(error, stackTrace);
      }
      return true;
    };
  }

  /// Restores the handlers that existed before [install].
  ///
  /// Repeated calls are no-ops. Throws [StateError] if handler ownership was
  /// transferred or corrupted while this integration was installed.
  void uninstall() {
    if (!_installed) return;
    if (!identical(_active, this)) {
      throw StateError('Integration ownership was lost');
    }
    FlutterError.onError = _previousFlutterHandler;
    PlatformDispatcher.instance.onError = _previousPlatformHandler;
    _previousFlutterHandler = null;
    _previousPlatformHandler = null;
    _installed = false;
    _active = null;
  }
}

Map<String, Map<String, Object?>> _flutterContexts(
  FlutterErrorDetails details,
) {
  try {
    return {
      'flutter': {
        if (details.library != null) 'library': details.library,
        if (details.context != null)
          'context': details.context!.toDescription(),
        if (details.informationCollector != null)
          'information': [
            for (final node in details.informationCollector!())
              node.toDescription(),
          ],
      },
    };
  } catch (_) {
    return const {};
  }
}
