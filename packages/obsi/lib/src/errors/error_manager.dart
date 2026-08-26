import 'dart:async';

import '../common/attributes.dart';
import '../common/instrumentation_scope.dart';
import '../common/diagnostics.dart';
import '../common/resource.dart';
import '../sdk/id_generator.dart';
import '../trace.dart';
import 'error_api.dart';
import 'error_exporter.dart';
import 'error_processor.dart';
import 'error_scope.dart';

/// Builds, processes and exports bounded error reports.
///
/// The manager owns [exporter]. Shutdown prevents new captures, drains pending
/// reports and shuts the exporter down exactly once.
final class ErrorManager {
  /// Creates an error manager with bounded attachments and pending reports.
  ///
  /// Throws [ArgumentError] for negative attachment limits, a non-positive
  /// [maxPendingReports], or a non-positive [operationTimeout].
  ErrorManager({
    required this.exporter,
    Resource? resource,
    InstrumentationScope? instrumentationScope,
    Iterable<ErrorProcessor>? processors,
    IdGenerator? idGenerator,
    this.onInternalError,
    int breadcrumbLimit = 100,
    this.maxAttachmentCount = 5,
    this.maxAttachmentSize = 20 * 1024 * 1024,
    this.maxTotalAttachmentSize = 20 * 1024 * 1024,
    this.maxPendingReports = 128,
    this.operationTimeout = const Duration(seconds: 30),
  }) : resource = resource ?? Resource.defaultResource,
       instrumentationScope =
           instrumentationScope ?? InstrumentationScope('obsi.errors'),
       processors = List.unmodifiable(
         processors ??
             [
               ErrorSanitizingProcessor(),
               ErrorDeduplicationProcessor(),
               ErrorRateLimitProcessor(),
             ],
       ),
       _idGenerator = idGenerator ?? RandomIdGenerator(),
       rootScope = ErrorScope(breadcrumbLimit: breadcrumbLimit) {
    if (maxAttachmentCount < 0) {
      throw ArgumentError.value(maxAttachmentCount, 'maxAttachmentCount');
    }
    if (maxAttachmentSize < 0) {
      throw ArgumentError.value(maxAttachmentSize, 'maxAttachmentSize');
    }
    if (maxTotalAttachmentSize < 0) {
      throw ArgumentError.value(
        maxTotalAttachmentSize,
        'maxTotalAttachmentSize',
      );
    }
    if (maxPendingReports <= 0) {
      throw ArgumentError.value(maxPendingReports, 'maxPendingReports');
    }
    validateTelemetryTimeout(operationTimeout, 'operationTimeout');
  }

  /// Exporter owned by this manager.
  final ErrorExporter exporter;

  /// Resource attributes included in every report.
  final Resource resource;

  /// Instrumentation scope included in every report.
  final InstrumentationScope instrumentationScope;

  /// Ordered, immutable processor pipeline applied before export.
  final List<ErrorProcessor> processors;

  /// Receives exporter, processor, timeout and invalid-ID failures.
  final TelemetryErrorHandler? onInternalError;

  /// Maximum number of attachments retained per report.
  final int maxAttachmentCount;

  /// Maximum size in bytes retained for one attachment.
  final int maxAttachmentSize;

  /// Maximum aggregate attachment bytes retained per report.
  final int maxTotalAttachmentSize;

  /// Maximum captures that may be processing concurrently.
  final int maxPendingReports;

  /// Timeout applied to processor and exporter operations, or `null` for none.
  final Duration? operationTimeout;
  final IdGenerator _idGenerator;

  /// Mutable process-level scope used outside a zone-local child scope.
  final ErrorScope rootScope;
  final Set<Future<ErrorId?>> _pending = {};
  bool _shutdown = false;
  int _acceptedReports = 0;
  int _exportedReports = 0;
  int _droppedReports = 0;
  int _exportFailures = 0;
  int _processorFailures = 0;
  int _droppedAttachments = 0;

  /// Number of reports accepted by every processor.
  int get acceptedReports => _acceptedReports;

  /// Number of reports whose exporter future completed successfully.
  int get exportedReports => _exportedReports;

  /// Number of reports rejected by lifecycle, limits or processing.
  int get droppedReports => _droppedReports;

  /// Number of exporter operations that failed or timed out.
  int get exportFailures => _exportFailures;

  /// Number of processor operations that failed or timed out.
  int get processorFailures => _processorFailures;

  /// Number of attachments removed by configured size or count limits.
  int get droppedAttachments => _droppedAttachments;

  /// Number of captures currently being processed or exported.
  int get pendingReports => _pending.length;

  /// Current zone-local scope, falling back to [rootScope].
  ErrorScope get currentScope => ErrorScope.zoneCurrent ?? rootScope;

  /// Processes and exports [exception], returning its ID when accepted.
  ///
  /// Returns `null` after shutdown, at queue capacity, or if a processor drops
  /// or fails the report. Export failures are diagnosed but still return the
  /// accepted report ID; inspect [exportFailures] for delivery failures.
  Future<ErrorId?> captureException(
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
  }) {
    if (_shutdown) {
      _droppedReports++;
      return Future.value(null);
    }
    if (_pending.length >= maxPendingReports) {
      _droppedReports++;
      return Future.value(null);
    }
    late final Future<ErrorId?> operation;
    operation = _captureException(
      exception,
      stackTrace: stackTrace,
      severity: fatal ? ErrorSeverity.fatal : severity,
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
    ).whenComplete(() => _pending.remove(operation));
    _pending.add(operation);
    return operation;
  }

  Future<ErrorId?> _captureException(
    Object exception, {
    required StackTrace? stackTrace,
    required ErrorSeverity severity,
    required bool fatal,
    required bool handled,
    required ErrorMechanism mechanism,
    required String? reason,
    required Map<String, Object?> attributes,
    required Map<String, String> tags,
    required Map<String, Map<String, Object?>> contexts,
    required List<String>? fingerprint,
    required List<ErrorAttachment> attachments,
    required ErrorUser? user,
  }) async {
    final scope = currentScope;
    final activeSpanContext = Trace.tracer.currentSpan?.context;
    ErrorReport? report = ErrorReport(
      id: ErrorId(_errorId()),
      timestamp: DateTime.now(),
      exception: exception,
      message: exception.toString(),
      stackTrace: stackTrace,
      severity: severity,
      fatal: fatal,
      handled: handled,
      mechanism: mechanism,
      reason: reason,
      attributes: validatedAttributes(attributes),
      tags: {...scope.tags, ...tags},
      contexts: {...scope.contexts, ...contexts},
      fingerprint: fingerprint ?? scope.fingerprint,
      breadcrumbs: scope.breadcrumbs,
      attachments: _boundedAttachments([...scope.attachments, ...attachments]),
      user: user ?? scope.user,
      spanContext: activeSpanContext?.isValid == true
          ? activeSpanContext
          : null,
      resource: resource,
      instrumentationScope: instrumentationScope,
    );
    for (final processor in processors) {
      try {
        report = await runTelemetryOperation<ErrorReport?>(
          () => processor.process(report!),
          timeout: operationTimeout,
        );
      } catch (error, stackTrace) {
        _processorFailures++;
        _droppedReports++;
        reportTelemetryError(onInternalError, error, stackTrace);
        return null;
      }
      if (report == null) {
        _droppedReports++;
        return null;
      }
    }
    final processedReport = report!;
    _acceptedReports++;
    try {
      await runTelemetryOperation(
        () => exporter.export(processedReport),
        timeout: operationTimeout,
      );
      _exportedReports++;
    } catch (error, stackTrace) {
      _exportFailures++;
      reportTelemetryError(onInternalError, error, stackTrace);
    }
    return processedReport.id;
  }

  /// Waits for pending captures and asks the exporter to flush.
  ///
  /// Internal failures are sent to [onInternalError] and do not escape.
  Future<void> forceFlush() async {
    while (_pending.isNotEmpty) {
      try {
        await Future.wait(_pending.toList(growable: false));
      } catch (error, stackTrace) {
        reportTelemetryError(onInternalError, error, stackTrace);
      }
    }
    try {
      await runTelemetryOperation(
        exporter.forceFlush,
        timeout: operationTimeout,
      );
    } catch (error, stackTrace) {
      reportTelemetryError(onInternalError, error, stackTrace);
    }
  }

  Future<void>? _shutdownFuture;

  /// Stops new captures, drains pending work and shuts down [exporter].
  ///
  /// Concurrent and repeated calls await the same future.
  Future<void> shutdown() => _shutdownFuture ??= _doShutdown();

  Future<void> _doShutdown() async {
    _shutdown = true;
    await forceFlush();
    try {
      await runTelemetryOperation(exporter.shutdown, timeout: operationTimeout);
    } catch (error, stackTrace) {
      reportTelemetryError(onInternalError, error, stackTrace);
    }
  }

  String _errorId() {
    try {
      final id = _idGenerator.generateTraceId();
      if (id.length == 32 &&
          id != '0' * 32 &&
          RegExp(r'^[0-9a-f]+$').hasMatch(id)) {
        return id;
      }
      throw StateError('IdGenerator returned an invalid error ID');
    } catch (error, stackTrace) {
      reportTelemetryError(onInternalError, error, stackTrace);
      return RandomIdGenerator().generateTraceId();
    }
  }

  List<ErrorAttachment> _boundedAttachments(List<ErrorAttachment> attachments) {
    final accepted = <ErrorAttachment>[];
    var totalSize = 0;
    for (final attachment in attachments) {
      final size = attachment.bytes.length;
      if (accepted.length >= maxAttachmentCount ||
          size > maxAttachmentSize ||
          totalSize + size > maxTotalAttachmentSize) {
        _droppedAttachments++;
        continue;
      }
      accepted.add(attachment);
      totalSize += size;
    }
    return accepted;
  }
}
