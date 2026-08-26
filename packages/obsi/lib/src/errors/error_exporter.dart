import 'error_api.dart';

/// Represents error exporter.
abstract interface class ErrorExporter {
  /// Performs export.
  Future<void> export(ErrorReport report);

  /// Performs force flush.
  Future<void> forceFlush();

  /// Performs shutdown.
  Future<void> shutdown();
}

/// Represents multi error exporter.
final class MultiErrorExporter implements ErrorExporter {
  /// Creates a instance.
  MultiErrorExporter(Iterable<ErrorExporter> exporters)
    : exporters = List.unmodifiable(exporters);

  /// The exporters.
  final List<ErrorExporter> exporters;
  final Set<Future<void>> _pending = {};
  bool _shutdown = false;
  Future<void>? _shutdownFuture;

  /// Performs export.
  @override
  Future<void> export(ErrorReport report) {
    if (_shutdown) return Future.error(StateError('Exporter is shut down'));
    late final Future<void> operation;
    operation = Future.wait([
      for (final exporter in exporters) exporter.export(report),
    ]).whenComplete(() => _pending.remove(operation));
    _pending.add(operation);
    return operation;
  }

  /// Performs force flush.
  @override
  Future<void> forceFlush() => _shutdownFuture ?? _flushAll();

  Future<void> _flushAll() async {
    await _waitForPending();
    await Future.wait([
      for (final exporter in exporters) exporter.forceFlush(),
    ]);
  }

  Future<void> _waitForPending() async {
    while (_pending.isNotEmpty) {
      await Future.wait(_pending.toList(growable: false));
    }
  }

  /// Performs shutdown.
  @override
  Future<void> shutdown() => _shutdownFuture ??= _doShutdown();

  Future<void> _doShutdown() async {
    _shutdown = true;
    await _waitForPending();
    await Future.wait([for (final exporter in exporters) exporter.shutdown()]);
  }
}
