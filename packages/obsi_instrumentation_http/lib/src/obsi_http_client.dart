import 'dart:async';

import 'package:http/http.dart' as http;
import 'package:obsi/obsi.dart';

/// Defines the http request predicate type.
typedef HttpRequestPredicate = bool Function(http.BaseRequest request);

/// Defines the http client span name builder type.
typedef HttpClientSpanNameBuilder = String Function(http.BaseRequest request);

/// Defines the http request attribute builder type.
typedef HttpRequestAttributeBuilder =
    Map<String, Object?> Function(http.BaseRequest request);

/// Defines the http response attribute builder type.
typedef HttpResponseAttributeBuilder =
    Map<String, Object?> Function(
      http.BaseRequest request,
      http.StreamedResponse response,
    );

/// Defines the http url sanitizer type.
typedef HttpUrlSanitizer = Uri Function(Uri url);

/// Represents obsi http client options.
final class ObsiHttpClientOptions {
  /// Creates a instance.
  const ObsiHttpClientOptions({
    this.shouldInstrument,
    this.spanNameBuilder,
    this.requestAttributes,
    this.responseAttributes,
    this.urlSanitizer,
    this.closeInnerClient = true,
    this.onInstrumentationError,
  });

  /// The should instrument.
  final HttpRequestPredicate? shouldInstrument;

  /// The span name builder.
  final HttpClientSpanNameBuilder? spanNameBuilder;

  /// The request attributes.
  final HttpRequestAttributeBuilder? requestAttributes;

  /// The response attributes.
  final HttpResponseAttributeBuilder? responseAttributes;

  /// The url sanitizer.
  final HttpUrlSanitizer? urlSanitizer;

  /// The close inner client.
  final bool closeInnerClient;

  /// The on instrumentation error.
  final TelemetryErrorHandler? onInstrumentationError;
}

/// Represents obsi http client.
final class ObsiHttpClient extends http.BaseClient {
  /// Creates a instance.
  ObsiHttpClient(
    this.inner, {
    Tracer? tracer,
    Meter? meter,
    this.propagator = const W3CTraceContextPropagator(),
    this.baggagePropagator = const W3CBaggagePropagator(),
    this.options = const ObsiHttpClientOptions(),
  }) : tracer = tracer ?? Trace.tracer,
       _duration = meter?.createHistogram<double>(
         SemanticMetrics.httpClientRequestDuration,
         unit: 's',
         boundaries: SemanticMetrics.httpDurationBoundaries,
       );

  /// The inner.
  final http.Client inner;

  /// The tracer.
  final Tracer tracer;

  /// The propagator.
  final TracePropagator propagator;

  /// The baggage propagator.
  final BaggagePropagator baggagePropagator;

  /// The options.
  final ObsiHttpClientOptions options;
  final Histogram<double>? _duration;

  /// Performs send.
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    if (!_shouldInstrument(request)) return inner.send(request);
    final stopwatch = Stopwatch()..start();
    int? statusCode;
    String? errorType;
    final method = SemanticHttp.normalizedMethod(request.method);
    final serverPort = SemanticHttp.serverPort(request.url);
    final sanitizedUrl = _sanitizeUrl(request.url);
    final span = tracer.startSpan(
      _spanName(request),
      kind: SpanKind.client,
      attributes: {
        SemanticAttributes.httpRequestMethod: method,
        if (method != request.method)
          SemanticAttributes.httpRequestMethodOriginal: request.method,
        SemanticAttributes.urlFull: sanitizedUrl.toString(),
        SemanticAttributes.serverAddress: request.url.host,
        SemanticAttributes.serverPort: ?serverPort,
      },
    );
    _applyAttributes(span, _requestAttributes(request));

    try {
      return await span.run(() async {
        try {
          propagator.inject(span.context, request.headers);
        } catch (error, stackTrace) {
          _reportInstrumentationError(error, stackTrace);
        }
        try {
          baggagePropagator.inject(Baggage.current, request.headers);
        } catch (error, stackTrace) {
          _reportInstrumentationError(error, stackTrace);
        }
        final response = await inner.send(request);
        statusCode = response.statusCode;
        span.setAttribute(
          SemanticAttributes.httpResponseStatusCode,
          response.statusCode,
        );
        _applyAttributes(span, _responseAttributes(request, response));
        var finished = false;
        if (response.statusCode >= 400) {
          errorType = '${response.statusCode}';
          span
            ..setAttribute(
              SemanticAttributes.errorType,
              '${response.statusCode}',
            )
            ..setStatus(SpanStatus.error);
        }

        void finish() {
          if (finished) return;
          finished = true;
          span.end();
          stopwatch.stop();
          _duration?.record(
            stopwatch.elapsedMicroseconds / Duration.microsecondsPerSecond,
            attributes: {
              SemanticAttributes.httpRequestMethod: method,
              SemanticAttributes.serverAddress: request.url.host,
              SemanticAttributes.serverPort: ?serverPort,
              SemanticAttributes.httpResponseStatusCode: ?statusCode,
              SemanticAttributes.errorType: ?errorType,
            },
          );
        }

        final body = Stream<List<int>>.multi((controller) {
          StreamSubscription<List<int>>? subscription;
          span.run(() {
            try {
              subscription = response.stream.listen(
                controller.add,
                onError: (Object error, StackTrace stackTrace) {
                  errorType = error.runtimeType.toString();
                  _recordSpanError(span, error, stackTrace);
                  controller.addError(error, stackTrace);
                },
                onDone: () {
                  finish();
                  controller.close();
                },
              );
            } catch (error, stackTrace) {
              errorType = error.runtimeType.toString();
              _recordSpanError(span, error, stackTrace);
              finish();
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
              finish();
            }
          };
        });

        return http.StreamedResponse(
          body,
          response.statusCode,
          contentLength: response.contentLength,
          request: response.request,
          headers: response.headers,
          isRedirect: response.isRedirect,
          persistentConnection: response.persistentConnection,
          reasonPhrase: response.reasonPhrase,
        );
      });
    } catch (error, stackTrace) {
      errorType = error.runtimeType.toString();
      _recordSpanError(span, error, stackTrace);
      span.end();
      stopwatch.stop();
      _duration?.record(
        stopwatch.elapsedMicroseconds / Duration.microsecondsPerSecond,
        attributes: {
          SemanticAttributes.httpRequestMethod: method,
          SemanticAttributes.serverAddress: request.url.host,
          SemanticAttributes.serverPort: ?serverPort,
          SemanticAttributes.errorType: errorType,
        },
      );
      rethrow;
    }
  }

  /// Performs close.
  @override
  void close() {
    if (options.closeInnerClient) inner.close();
  }

  bool _shouldInstrument(http.BaseRequest request) {
    try {
      return options.shouldInstrument?.call(request) ?? true;
    } catch (error, stackTrace) {
      _reportInstrumentationError(error, stackTrace);
      return true;
    }
  }

  String _spanName(http.BaseRequest request) {
    try {
      final name = options.spanNameBuilder?.call(request) ?? request.method;
      return name.isEmpty ? request.method : name;
    } catch (error, stackTrace) {
      _reportInstrumentationError(error, stackTrace);
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
      _reportInstrumentationError(error, stackTrace);
      return url.replace(userInfo: '', query: '').removeFragment();
    }
  }

  Map<String, Object?> _requestAttributes(http.BaseRequest request) {
    try {
      return options.requestAttributes?.call(request) ?? const {};
    } catch (error, stackTrace) {
      _reportInstrumentationError(error, stackTrace);
      return const {};
    }
  }

  Map<String, Object?> _responseAttributes(
    http.BaseRequest request,
    http.StreamedResponse response,
  ) {
    try {
      return options.responseAttributes?.call(request, response) ?? const {};
    } catch (error, stackTrace) {
      _reportInstrumentationError(error, stackTrace);
      return const {};
    }
  }

  void _recordSpanError(Span span, Object error, StackTrace stackTrace) {
    span
      ..setAttribute(SemanticAttributes.errorType, error.runtimeType.toString())
      ..recordException(error, stackTrace: stackTrace)
      ..setStatus(SpanStatus.error);
  }

  void _applyAttributes(Span span, Map<String, Object?> attributes) {
    for (final entry in attributes.entries) {
      try {
        span.setAttribute(entry.key, entry.value);
      } catch (error, stackTrace) {
        _reportInstrumentationError(error, stackTrace);
      }
    }
  }

  void _reportInstrumentationError(Object error, StackTrace stackTrace) {
    try {
      options.onInstrumentationError?.call(error, stackTrace);
    } catch (_) {
      // Instrumentation diagnostics must never break the HTTP request.
    }
  }
}
