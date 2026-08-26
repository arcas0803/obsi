import 'dart:async';

import 'package:obsi/obsi.dart';
import 'package:shelf/shelf.dart';

/// Defines the shelf request predicate type.
typedef ShelfRequestPredicate = bool Function(Request request);

/// Defines the shelf attribute builder type.
typedef ShelfAttributeBuilder = Map<String, Object?> Function(Request request);

/// Defines the shelf response attribute builder type.
typedef ShelfResponseAttributeBuilder =
    Map<String, Object?> Function(Request request, Response response);

/// Represents obsi shelf options.
final class ObsiShelfOptions {
  /// Creates a instance.
  const ObsiShelfOptions({
    this.shouldInstrument,
    this.requestAttributes,
    this.responseAttributes,
    this.traceResponseBody = true,
    this.onInstrumentationError,
  });

  /// The should instrument.
  final ShelfRequestPredicate? shouldInstrument;

  /// The request attributes.
  final ShelfAttributeBuilder? requestAttributes;

  /// The response attributes.
  final ShelfResponseAttributeBuilder? responseAttributes;

  /// The trace response body.
  final bool traceResponseBody;

  /// The on instrumentation error.
  final TelemetryErrorHandler? onInstrumentationError;
}

/// Performs obsi middleware.
Middleware obsiMiddleware({
  Tracer? tracer,
  Meter? meter,
  String? Function(Request request)? routeResolver,
  TracePropagator propagator = const W3CTraceContextPropagator(),
  BaggagePropagator baggagePropagator = const W3CBaggagePropagator(),
  ObsiShelfOptions options = const ObsiShelfOptions(),
}) {
  final effectiveTracer = tracer ?? Trace.tracer;
  final duration = meter?.createHistogram<double>(
    SemanticMetrics.httpServerRequestDuration,
    unit: 's',
    boundaries: SemanticMetrics.httpDurationBoundaries,
  );
  return (Handler innerHandler) {
    return (Request request) async {
      if (!_shouldInstrument(request, options)) return innerHandler(request);
      final parent = _extractParent(request, propagator, options);
      final baggage = _extractBaggage(request, baggagePropagator, options);
      final route = _resolveRoute(request, routeResolver, options);
      final stopwatch = Stopwatch()..start();
      int? statusCode;
      String? errorType;
      var finished = false;
      final method = SemanticHttp.normalizedMethod(request.method);
      final scheme = request.requestedUri.scheme;
      final span = effectiveTracer.startSpan(
        route == null ? method : '$method $route',
        kind: SpanKind.server,
        parent: parent,
        attributes: {
          SemanticAttributes.httpRequestMethod: method,
          if (method != request.method)
            SemanticAttributes.httpRequestMethodOriginal: request.method,
          SemanticAttributes.urlPath: '/${request.url.path}',
          if (request.url.hasQuery) SemanticAttributes.urlQuery: 'redacted',
          if (scheme.isNotEmpty) SemanticAttributes.urlScheme: scheme,
          SemanticAttributes.httpRoute: ?route,
        },
      );
      _applyAttributes(span, _requestAttributes(request, options), options);

      /// Performs finish.
      void finish() {
        if (finished) return;
        finished = true;
        span.end();
        stopwatch.stop();
        duration?.record(
          stopwatch.elapsedMicroseconds / Duration.microsecondsPerSecond,
          attributes: {
            SemanticAttributes.httpRequestMethod: method,
            if (scheme.isNotEmpty) SemanticAttributes.urlScheme: scheme,
            SemanticAttributes.httpRoute: ?route,
            SemanticAttributes.httpResponseStatusCode: ?statusCode,
            SemanticAttributes.errorType: ?errorType,
          },
        );
      }

      return baggage.run(
        () => span.run(() async {
          try {
            final response = await innerHandler(request);
            statusCode = response.statusCode;
            span.setAttribute(
              SemanticAttributes.httpResponseStatusCode,
              response.statusCode,
            );
            _applyAttributes(
              span,
              _responseAttributes(request, response, options),
              options,
            );
            if (response.statusCode >= 500) {
              errorType = '${response.statusCode}';
              span
                ..setAttribute(
                  SemanticAttributes.errorType,
                  '${response.statusCode}',
                )
                ..setStatus(SpanStatus.error);
            }
            if (!options.traceResponseBody) {
              finish();
              return response;
            }
            return response.change(
              body: _traceBody(
                response.read(),
                baggage: baggage,
                span: span,
                onError: (error, stackTrace) {
                  errorType = error.runtimeType.toString();
                  _recordSpanError(span, error, stackTrace);
                },
                onDone: finish,
              ),
            );
          } catch (error, stackTrace) {
            errorType = error.runtimeType.toString();
            _recordSpanError(span, error, stackTrace);
            finish();
            rethrow;
          }
        }),
      );
    };
  };
}

Stream<List<int>> _traceBody(
  Stream<List<int>> source, {
  required Baggage baggage,
  required Span span,
  required void Function(Object error, StackTrace stackTrace) onError,
  required void Function() onDone,
}) => Stream<List<int>>.multi((controller) {
  StreamSubscription<List<int>>? subscription;
  baggage.run(
    () => span.run(() {
      try {
        subscription = source.listen(
          controller.add,
          onError: (Object error, StackTrace stackTrace) {
            onError(error, stackTrace);
            controller.addError(error, stackTrace);
          },
          onDone: () {
            onDone();
            controller.close();
          },
        );
      } catch (error, stackTrace) {
        onError(error, stackTrace);
        onDone();
        controller
          ..addError(error, stackTrace)
          ..close();
      }
    }),
  );
  controller.onPause = () => subscription?.pause();
  controller.onResume = () => subscription?.resume();
  controller.onCancel = () async {
    try {
      await subscription?.cancel();
    } finally {
      onDone();
    }
  };
});

bool _shouldInstrument(Request request, ObsiShelfOptions options) {
  try {
    return options.shouldInstrument?.call(request) ?? true;
  } catch (error, stackTrace) {
    _report(options, error, stackTrace);
    return true;
  }
}

String? _resolveRoute(
  Request request,
  String? Function(Request request)? resolver,
  ObsiShelfOptions options,
) {
  try {
    final route = resolver?.call(request);
    return route == null || route.isEmpty ? null : route;
  } catch (error, stackTrace) {
    _report(options, error, stackTrace);
    return null;
  }
}

Map<String, Object?> _requestAttributes(
  Request request,
  ObsiShelfOptions options,
) {
  try {
    return options.requestAttributes?.call(request) ?? const {};
  } catch (error, stackTrace) {
    _report(options, error, stackTrace);
    return const {};
  }
}

Map<String, Object?> _responseAttributes(
  Request request,
  Response response,
  ObsiShelfOptions options,
) {
  try {
    return options.responseAttributes?.call(request, response) ?? const {};
  } catch (error, stackTrace) {
    _report(options, error, stackTrace);
    return const {};
  }
}

void _applyAttributes(
  Span span,
  Map<String, Object?> attributes,
  ObsiShelfOptions options,
) {
  for (final entry in attributes.entries) {
    try {
      span.setAttribute(entry.key, entry.value);
    } catch (error, stackTrace) {
      _report(options, error, stackTrace);
    }
  }
}

void _recordSpanError(Span span, Object error, StackTrace stackTrace) {
  span
    ..setAttribute(SemanticAttributes.errorType, error.runtimeType.toString())
    ..recordException(error, stackTrace: stackTrace)
    ..setStatus(SpanStatus.error);
}

SpanContext? _extractParent(
  Request request,
  TracePropagator propagator,
  ObsiShelfOptions options,
) {
  try {
    return propagator.extract(request.headers);
  } catch (error, stackTrace) {
    _report(options, error, stackTrace);
    return null;
  }
}

Baggage _extractBaggage(
  Request request,
  BaggagePropagator propagator,
  ObsiShelfOptions options,
) {
  try {
    return propagator.extract(request.headers);
  } catch (error, stackTrace) {
    _report(options, error, stackTrace);
    return Baggage.empty;
  }
}

void _report(ObsiShelfOptions options, Object error, StackTrace stackTrace) {
  try {
    options.onInstrumentationError?.call(error, stackTrace);
  } catch (_) {
    // Instrumentation diagnostics must never break the Shelf request.
  }
}
