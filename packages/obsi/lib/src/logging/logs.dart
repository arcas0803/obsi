import 'log_api.dart';
import 'logger_provider.dart';

/// Represents logs.
final class Logs {
  Logs._();

  static LoggerProvider? _provider;

  /// The provider.
  static LoggerProvider? get provider => _provider;

  /// Performs configure.
  static void configure(LoggerProvider provider) => _provider = provider;

  /// Performs disable.
  static void disable() => _provider = null;

  /// Performs get logger.
  static Logger getLogger(String name, {String? version}) =>
      _provider?.getLogger(name, version: version) ?? const _NoopLogger();
}

final class _NoopLogger implements Logger {
  const _NoopLogger();

  @override
  bool isEnabled(LogSeverity severity) => false;
  @override
  void log(
    LogSeverity severity,
    Object? body, {
    Map<String, Object?> attributes = const {},
    Object? error,
    StackTrace? stackTrace,
    DateTime? timestamp,
  }) {}
  @override
  void trace(Object? body, {Map<String, Object?> attributes = const {}}) {}
  @override
  void debug(Object? body, {Map<String, Object?> attributes = const {}}) {}
  @override
  void info(Object? body, {Map<String, Object?> attributes = const {}}) {}
  @override
  void warn(Object? body, {Map<String, Object?> attributes = const {}}) {}
  @override
  void error(
    Object? body, {
    Map<String, Object?> attributes = const {},
    Object? error,
    StackTrace? stackTrace,
  }) {}
  @override
  void fatal(
    Object? body, {
    Map<String, Object?> attributes = const {},
    Object? error,
    StackTrace? stackTrace,
  }) {}
}
