import 'dart:async';

/// Receives failures produced internally by telemetry components.
///
/// Obsi never lets exporter, processor, sampler, or observable callback
/// failures escape into application code. The handler should use a fallback
/// channel that does not call Obsi again.
typedef TelemetryErrorHandler =
    void Function(Object error, StackTrace stackTrace);

/// Performs report telemetry error.
void reportTelemetryError(
  TelemetryErrorHandler? handler,
  Object error,
  StackTrace stackTrace,
) {
  if (handler == null) return;
  try {
    handler(error, stackTrace);
  } catch (_) {
    // Diagnostics must never recursively fail the instrumented application.
  }
}

/// Performs run telemetry operation.
Future<T> runTelemetryOperation<T>(
  FutureOr<T> Function() operation, {
  Duration? timeout,
}) async {
  final future = Future.sync(operation);
  if (timeout == null) {
    return await future;
  } else {
    return await future.timeout(timeout);
  }
}

/// Performs validate telemetry timeout.
void validateTelemetryTimeout(Duration? timeout, String name) {
  if (timeout != null && timeout <= Duration.zero) {
    throw ArgumentError.value(timeout, name);
  }
}
