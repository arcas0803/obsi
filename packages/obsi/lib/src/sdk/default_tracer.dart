import 'dart:async';

import '../api/span.dart';
import '../api/span_context.dart';
import '../api/tracer.dart';
import '../common/instrumentation_scope.dart';
import '../common/diagnostics.dart';
import '../common/resource.dart';
import '../common/redaction.dart';
import '../context/zone_trace_context.dart';
import '../errors/error_api.dart';
import '../errors/errors.dart';
import '../processing/span_processor.dart';
import 'default_span.dart';
import 'id_generator.dart';
import 'noop.dart';
import 'sampler.dart';
import 'span_limits.dart';

/// Represents default tracer.
final class DefaultTracer implements Tracer {
  /// Creates a instance.
  DefaultTracer({
    required this.processor,
    required this.sampler,
    required this.idGenerator,
    required this.resource,
    required this.instrumentationScope,
    required this.spanLimits,
    this.onInternalError,
    this.attributeRedactor,
  });

  /// The processor.
  final SpanProcessor processor;

  /// The sampler.
  final Sampler sampler;

  /// The id generator.
  final IdGenerator idGenerator;

  /// The resource.
  final Resource resource;

  /// The instrumentation scope.
  final InstrumentationScope instrumentationScope;

  /// The span limits.
  final SpanLimits spanLimits;

  /// The on internal error.
  final TelemetryErrorHandler? onInternalError;

  /// The attribute redactor.
  final AttributeRedactor? attributeRedactor;
  final RandomIdGenerator _fallbackIdGenerator = RandomIdGenerator();

  /// The current span.
  @override
  Span? get currentSpan => ZoneTraceContext.currentSpan;

  /// Performs start span.
  @override
  Span startSpan(
    String name, {
    SpanKind kind = SpanKind.internal,
    Map<String, Object?> attributes = const {},
    List<SpanLink> links = const [],
    SpanContext? parent,
  }) {
    if (name.isEmpty) throw ArgumentError.value(name, 'name');
    final candidateParent = parent ?? currentSpan?.context;
    final effectiveParent = candidateParent?.isValid == true
        ? candidateParent
        : null;
    final traceId = effectiveParent?.traceId ?? _traceId();
    var samplingResult = SamplingResult.drop;
    if (!ZoneTraceContext.suppressed) {
      try {
        samplingResult = sampler.sample(
          SamplingParameters(
            traceId: traceId,
            name: name,
            kind: kind,
            attributes: attributeRedactor?.call(attributes) ?? attributes,
            links: links,
            parent: effectiveParent,
          ),
        );
      } catch (error, stackTrace) {
        reportTelemetryError(onInternalError, error, stackTrace);
      }
    }
    final sampled = samplingResult.decision == SamplingDecision.recordAndSample;
    final context = SpanContext(
      traceId: traceId,
      spanId: _spanId(),
      sampled: sampled,
      traceState: samplingResult.traceState ?? effectiveParent?.traceState,
    );
    if (samplingResult.decision == SamplingDecision.drop) {
      return NoopSpan(context);
    }

    final span = DefaultSpan(
      name: name,
      context: context,
      parentSpanId: effectiveParent?.spanId,
      kind: kind,
      processor: processor,
      resource: resource,
      instrumentationScope: instrumentationScope,
      limits: spanLimits,
      attributes:
          attributeRedactor?.call({
            ...attributes,
            ...samplingResult.attributes,
          }) ??
          {...attributes, ...samplingResult.attributes},
      links: links,
      onInternalError: onInternalError,
      attributeRedactor: attributeRedactor,
    );
    try {
      processor.onStart(span);
    } catch (error, stackTrace) {
      reportTelemetryError(onInternalError, error, stackTrace);
    }
    return span;
  }

  String _traceId() {
    try {
      final value = idGenerator.generateTraceId();
      if (_validId(value, 32)) return value;
      throw StateError('IdGenerator returned an invalid trace ID');
    } catch (error, stackTrace) {
      reportTelemetryError(onInternalError, error, stackTrace);
      return _fallbackIdGenerator.generateTraceId();
    }
  }

  String _spanId() {
    try {
      final value = idGenerator.generateSpanId();
      if (_validId(value, 16)) return value;
      throw StateError('IdGenerator returned an invalid span ID');
    } catch (error, stackTrace) {
      reportTelemetryError(onInternalError, error, stackTrace);
      return _fallbackIdGenerator.generateSpanId();
    }
  }

  static bool _validId(String value, int length) =>
      value.length == length &&
      value != '0' * length &&
      RegExp(r'^[0-9a-f]+$').hasMatch(value);

  /// Performs trace sync.
  @override
  T traceSync<T>(
    String name,
    T Function() callback, {
    SpanKind kind = SpanKind.internal,
    Map<String, Object?> attributes = const {},
  }) {
    final span = startSpan(name, kind: kind, attributes: attributes);
    return span.run(() {
      try {
        final result = callback();
        _markOk(span);
        return result;
      } catch (error, stackTrace) {
        _recordError(span, error, stackTrace);
        rethrow;
      } finally {
        span.end();
      }
    });
  }

  /// Performs trace.
  @override
  Future<T> trace<T>(
    String name,
    FutureOr<T> Function() callback, {
    SpanKind kind = SpanKind.internal,
    Map<String, Object?> attributes = const {},
  }) {
    final span = startSpan(name, kind: kind, attributes: attributes);
    return span.run(() async {
      try {
        final result = await callback();
        _markOk(span);
        return result;
      } catch (error, stackTrace) {
        _recordError(span, error, stackTrace);
        rethrow;
      } finally {
        span.end();
      }
    });
  }

  /// Performs trace stream.
  @override
  Stream<T> traceStream<T>(
    String name,
    Stream<T> Function() factory, {
    SpanKind kind = SpanKind.internal,
    Map<String, Object?> attributes = const {},
    bool isBroadcast = false,
  }) {
    final capturedParent = currentSpan?.context;
    return Stream.multi((controller) {
      final span = startSpan(
        name,
        kind: kind,
        attributes: attributes,
        parent: capturedParent,
      );
      StreamSubscription<T>? subscription;
      var failed = false;

      /// Performs finish.
      void finish() {
        if (!failed) _markOk(span);
        span.end();
      }

      span.run(() {
        try {
          subscription = factory().listen(
            controller.add,
            onError: (Object error, StackTrace stackTrace) {
              failed = true;
              _recordError(span, error, stackTrace);
              controller.addError(error, stackTrace);
            },
            onDone: () {
              finish();
              unawaited(controller.close());
            },
          );
        } catch (error, stackTrace) {
          failed = true;
          _recordError(span, error, stackTrace);
          span.end();
          controller.addError(error, stackTrace);
          unawaited(controller.close());
        }
      });

      controller
        ..onPause = () {
          subscription?.pause();
        }
        ..onResume = () {
          subscription?.resume();
        }
        ..onCancel = () async {
          try {
            await subscription?.cancel();
          } finally {
            finish();
          }
        };
    }, isBroadcast: isBroadcast);
  }

  static void _recordError(Span span, Object error, StackTrace stackTrace) {
    span
      ..recordException(error, stackTrace: stackTrace)
      ..setStatus(SpanStatus.error, description: error.toString());
    Errors.addBreadcrumb(
      ErrorBreadcrumb(
        timestamp: DateTime.now(),
        category: 'trace.exception',
        message: error.toString(),
        level: ErrorSeverity.error,
        data: {
          'span.name': span.name,
          'exception.type': error.runtimeType.toString(),
        },
      ),
    );
  }

  static void _markOk(Span span) {
    if (span is DefaultSpan) {
      span.setOkIfUnset();
    } else {
      span.setStatus(SpanStatus.ok);
    }
  }
}
