import 'dart:async';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:obsi/obsi.dart';

/// Defines the dio request predicate type.
typedef DioRequestPredicate = bool Function(RequestOptions request);

/// Defines the dio client span name builder type.
typedef DioClientSpanNameBuilder = String Function(RequestOptions request);

/// Defines the dio request attribute builder type.
typedef DioRequestAttributeBuilder =
    Map<String, Object?> Function(RequestOptions request);

/// Defines the dio response attribute builder type.
typedef DioResponseAttributeBuilder =
    Map<String, Object?> Function(Response<dynamic> response);

/// Defines the dio url sanitizer type.
typedef DioUrlSanitizer = Uri Function(Uri url);

/// Stable package-owned attributes. Dio has no OpenTelemetry-specific keys.
abstract final class ObsiDioAttributes {
  /// The error type.
  static const errorType = 'dio.error.type';
}

/// Represents obsi dio options.
final class ObsiDioOptions {
  /// Creates a instance.
  const ObsiDioOptions({
    this.shouldInstrument,
    this.spanNameBuilder,
    this.requestAttributes,
    this.responseAttributes,
    this.urlSanitizer,
    this.traceResponseBody = true,
    this.onInstrumentationError,
  });

  /// The should instrument.
  final DioRequestPredicate? shouldInstrument;

  /// The span name builder.
  final DioClientSpanNameBuilder? spanNameBuilder;

  /// The request attributes.
  final DioRequestAttributeBuilder? requestAttributes;

  /// The response attributes.
  final DioResponseAttributeBuilder? responseAttributes;

  /// The url sanitizer.
  final DioUrlSanitizer? urlSanitizer;

  /// Keeps spans for [ResponseType.stream] open until consumption or cancel.
  final bool traceResponseBody;

  /// The on instrumentation error.
  final TelemetryErrorHandler? onInstrumentationError;
}

/// Concurrent-safe Dio interceptor. Add one instance to `dio.interceptors`.
final class ObsiDioInterceptor extends Interceptor {
  /// Creates a instance.
  ObsiDioInterceptor({
    Tracer? tracer,
    Meter? meter,
    this.propagator = const W3CTraceContextPropagator(),
    this.baggagePropagator = const W3CBaggagePropagator(),
    this.options = const ObsiDioOptions(),
  }) : tracer = tracer ?? Trace.tracer,
       _duration = meter?.createHistogram<double>(
         SemanticMetrics.httpClientRequestDuration,
         unit: 's',
         boundaries: SemanticMetrics.httpDurationBoundaries,
       );

  static const _stateKey = 'obsi.instrumentation.dio.state';

  /// The tracer.
  final Tracer tracer;

  /// The propagator.
  final TracePropagator propagator;

  /// The baggage propagator.
  final BaggagePropagator baggagePropagator;

  /// The options.
  final ObsiDioOptions options;
  final Histogram<double>? _duration;

  /// Performs on request.
  @override
  void onRequest(RequestOptions options, RequestInterceptorHandler handler) {
    if (!_shouldInstrument(options)) {
      handler.next(options);
      return;
    }

    final previous = options.extra[_stateKey];
    if (previous is _RequestState && !previous.finished) {
      // A second Obsi interceptor must not create a nested duplicate span.
      handler.next(options);
      return;
    }

    Span? span;
    try {
      final sanitizedUrl = _sanitizeUrl(options.uri);
      final method = SemanticHttp.normalizedMethod(options.method);
      final serverPort = SemanticHttp.serverPort(options.uri);
      span = tracer.startSpan(
        _spanName(options),
        kind: SpanKind.client,
        attributes: {
          SemanticAttributes.httpRequestMethod: method,
          if (method != options.method)
            SemanticAttributes.httpRequestMethodOriginal: options.method,
          SemanticAttributes.urlFull: sanitizedUrl.toString(),
          SemanticAttributes.serverAddress: options.uri.host,
          SemanticAttributes.serverPort: ?serverPort,
        },
      );
      _applyAttributes(span, _requestAttributes(options));
    } catch (error, stackTrace) {
      _report(error, stackTrace);
    }
    if (span == null) {
      handler.next(options);
      return;
    }

    final effectiveSpan = span;
    final state = _RequestState(
      this,
      effectiveSpan,
      SemanticHttp.normalizedMethod(options.method),
      options.uri.host,
      SemanticHttp.serverPort(options.uri),
    );
    options.extra[_stateKey] = state;
    effectiveSpan.run(() {
      _injectContext(options, effectiveSpan);
      handler.next(options);
    });
  }

  /// Performs on response.
  @override
  void onResponse(
    Response<dynamic> response,
    ResponseInterceptorHandler handler,
  ) {
    final state = _ownedState(response.requestOptions);
    if (state == null) {
      handler.next(response);
      return;
    }
    _recordResponse(state, response);
    final data = response.data;
    if (options.traceResponseBody && data is ResponseBody) {
      data.stream = _traceBody(data.stream, state);
    } else {
      _finish(state);
    }
    handler.next(response);
  }

  /// Performs on error.
  @override
  void onError(DioException err, ErrorInterceptorHandler handler) {
    final state = _ownedState(err.requestOptions);
    if (state != null) {
      final response = err.response;
      if (response != null) _recordResponse(state, response);
      if (err.type != DioExceptionType.cancel) {
        final cause = err.error ?? err;
        final isHttpFailure =
            err.type == DioExceptionType.badResponse && response != null;
        state.errorType = isHttpFailure
            ? '${response.statusCode}'
            : cause.runtimeType.toString();
        state.span
          ..setAttribute(SemanticAttributes.errorType, state.errorType)
          ..setStatus(SpanStatus.error);
        if (!isHttpFailure) {
          state.span
            ..setAttribute(ObsiDioAttributes.errorType, err.type.name)
            ..recordException(cause, stackTrace: err.stackTrace);
        }
      }
      _finish(state);
    }
    handler.next(err);
  }

  _RequestState? _ownedState(RequestOptions request) {
    final state = request.extra[_stateKey];
    return state is _RequestState && identical(state.owner, this)
        ? state
        : null;
  }

  void _recordResponse(_RequestState state, Response<dynamic> response) {
    final statusCode = response.statusCode;
    state.statusCode = statusCode;
    if (statusCode != null) {
      state.span.setAttribute(
        SemanticAttributes.httpResponseStatusCode,
        statusCode,
      );
      if (statusCode >= 400) {
        state.errorType = '$statusCode';
        state.span
          ..setAttribute(SemanticAttributes.errorType, '$statusCode')
          ..setStatus(SpanStatus.error);
      }
    }
    _applyAttributes(state.span, _responseAttributes(response));
  }

  Stream<Uint8List> _traceBody(Stream<Uint8List> source, _RequestState state) =>
      Stream<Uint8List>.multi((controller) {
        StreamSubscription<Uint8List>? subscription;
        state.span.run(() {
          try {
            subscription = source.listen(
              controller.add,
              onError: (Object error, StackTrace stackTrace) {
                state.errorType = error.runtimeType.toString();
                state.span
                  ..setAttribute(SemanticAttributes.errorType, state.errorType)
                  ..recordException(error, stackTrace: stackTrace)
                  ..setStatus(SpanStatus.error);
                controller.addError(error, stackTrace);
              },
              onDone: () {
                _finish(state);
                controller.close();
              },
            );
          } catch (error, stackTrace) {
            state.errorType = error.runtimeType.toString();
            state.span
              ..setAttribute(SemanticAttributes.errorType, state.errorType)
              ..recordException(error, stackTrace: stackTrace)
              ..setStatus(SpanStatus.error);
            _finish(state);
            controller
              ..addError(error, stackTrace)
              ..close();
          }
        });
        controller.onPause = () => subscription?.pause();
        controller.onResume = () => subscription?.resume();
        controller.onCancel = () async {
          try {
            await subscription?.cancel();
          } finally {
            _finish(state);
          }
        };
      });

  void _finish(_RequestState state) {
    if (state.finished) return;
    state.finished = true;
    state.stopwatch.stop();
    state.span.end();
    _duration?.record(
      state.stopwatch.elapsedMicroseconds / Duration.microsecondsPerSecond,
      attributes: {
        SemanticAttributes.httpRequestMethod: state.method,
        SemanticAttributes.serverAddress: state.serverAddress,
        SemanticAttributes.serverPort: ?state.serverPort,
        SemanticAttributes.httpResponseStatusCode: ?state.statusCode,
        SemanticAttributes.errorType: ?state.errorType,
      },
    );
  }

  void _injectContext(RequestOptions request, Span span) {
    final carrier = <String, String>{};
    try {
      propagator.inject(span.context, carrier);
    } catch (error, stackTrace) {
      _report(error, stackTrace);
    }
    try {
      baggagePropagator.inject(Baggage.current, carrier);
    } catch (error, stackTrace) {
      _report(error, stackTrace);
    }
    request.headers.addAll(carrier);
  }

  bool _shouldInstrument(RequestOptions request) {
    try {
      return options.shouldInstrument?.call(request) ?? true;
    } catch (error, stackTrace) {
      _report(error, stackTrace);
      return true;
    }
  }

  String _spanName(RequestOptions request) {
    try {
      final name = options.spanNameBuilder?.call(request) ?? request.method;
      return name.isEmpty ? request.method : name;
    } catch (error, stackTrace) {
      _report(error, stackTrace);
      return request.method;
    }
  }

  Uri _sanitizeUrl(Uri url) {
    try {
      return options.urlSanitizer?.call(url) ??
          url
              .replace(userInfo: '', query: url.hasQuery ? 'redacted' : null)
              .removeFragment();
    } catch (error, stackTrace) {
      _report(error, stackTrace);
      return url.replace(userInfo: '', query: '').removeFragment();
    }
  }

  Map<String, Object?> _requestAttributes(RequestOptions request) {
    try {
      return options.requestAttributes?.call(request) ?? const {};
    } catch (error, stackTrace) {
      _report(error, stackTrace);
      return const {};
    }
  }

  Map<String, Object?> _responseAttributes(Response<dynamic> response) {
    try {
      return options.responseAttributes?.call(response) ?? const {};
    } catch (error, stackTrace) {
      _report(error, stackTrace);
      return const {};
    }
  }

  void _applyAttributes(Span span, Map<String, Object?> attributes) {
    for (final entry in attributes.entries) {
      try {
        span.setAttribute(entry.key, entry.value);
      } catch (error, stackTrace) {
        _report(error, stackTrace);
      }
    }
  }

  void _report(Object error, StackTrace stackTrace) {
    try {
      options.onInstrumentationError?.call(error, stackTrace);
    } catch (_) {
      // Telemetry failures must never alter the request lifecycle.
    }
  }
}

final class _RequestState {
  _RequestState(
    this.owner,
    this.span,
    this.method,
    this.serverAddress,
    this.serverPort,
  ) : stopwatch = Stopwatch()..start();

  final ObsiDioInterceptor owner;
  final Span span;
  final Stopwatch stopwatch;
  final String method;
  final String serverAddress;
  final int? serverPort;
  int? statusCode;
  String? errorType;
  bool finished = false;
}
