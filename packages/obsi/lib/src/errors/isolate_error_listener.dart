import 'dart:async';
import 'dart:isolate';

import 'error_api.dart';
import 'errors.dart';

/// Owns a receive port registered for uncaught errors in one Dart isolate.
final class ErrorIsolateListener {
  ErrorIsolateListener._(this._port);

  final RawReceivePort _port;
  bool _closed = false;

  /// Starts listening to uncaught errors from the current isolate.
  static ErrorIsolateListener start() {
    late final RawReceivePort port;
    port = RawReceivePort((Object? message) {
      if (message is! List || message.length < 2) return;
      final rawError = message[0];
      if (rawError == null) return;
      final error = rawError as Object;
      final rawStack = message[1];
      final stackTrace = rawStack is StackTrace
          ? rawStack
          : StackTrace.fromString(rawStack?.toString() ?? '');
      unawaited(
        Errors.captureException(
          error,
          stackTrace: stackTrace,
          fatal: true,
          handled: false,
          mechanism: ErrorMechanism.isolate,
        ),
      );
    });
    Isolate.current.addErrorListener(port.sendPort);
    return ErrorIsolateListener._(port);
  }

  /// Unregisters the listener and closes its port; repeated calls are no-ops.
  void close() {
    if (_closed) return;
    _closed = true;
    Isolate.current.removeErrorListener(_port.sendPort);
    _port.close();
  }
}
