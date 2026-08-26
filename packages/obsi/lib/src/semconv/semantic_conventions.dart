/// Represents semantic attributes.
abstract final class SemanticAttributes {
  /// The service name.
  static const serviceName = 'service.name';

  /// The service version.
  static const serviceVersion = 'service.version';

  /// The telemetry sdk name.
  static const telemetrySdkName = 'telemetry.sdk.name';

  /// The telemetry sdk language.
  static const telemetrySdkLanguage = 'telemetry.sdk.language';

  /// The telemetry sdk version.
  static const telemetrySdkVersion = 'telemetry.sdk.version';

  /// The deployment environment name.
  static const deploymentEnvironmentName = 'deployment.environment.name';

  /// The http request method.
  static const httpRequestMethod = 'http.request.method';

  /// Original HTTP method when [httpRequestMethod] is normalized to `_OTHER`.
  static const httpRequestMethodOriginal = 'http.request.method_original';

  /// The http response status code.
  static const httpResponseStatusCode = 'http.response.status_code';

  /// The http route.
  static const httpRoute = 'http.route';

  /// The url full.
  static const urlFull = 'url.full';

  /// The url path.
  static const urlPath = 'url.path';

  /// The url query.
  static const urlQuery = 'url.query';

  /// The url scheme.
  static const urlScheme = 'url.scheme';

  /// The server address.
  static const serverAddress = 'server.address';

  /// The server port.
  static const serverPort = 'server.port';

  /// The network protocol version.
  static const networkProtocolVersion = 'network.protocol.version';

  /// The negotiated application protocol name.
  static const networkProtocolName = 'network.protocol.name';

  /// The error type.
  static const errorType = 'error.type';

  /// The exception type.
  static const exceptionType = 'exception.type';

  /// The exception message.
  static const exceptionMessage = 'exception.message';

  /// The exception stacktrace.
  static const exceptionStacktrace = 'exception.stacktrace';
}

/// Represents semantic metrics.
abstract final class SemanticMetrics {
  /// The http client request duration.
  static const httpClientRequestDuration = 'http.client.request.duration';

  /// The http server request duration.
  static const httpServerRequestDuration = 'http.server.request.duration';

  /// Recommended explicit histogram boundaries for HTTP durations in seconds.
  static const httpDurationBoundaries = <double>[
    0.005,
    0.01,
    0.025,
    0.05,
    0.075,
    0.1,
    0.25,
    0.5,
    0.75,
    1,
    2.5,
    5,
    7.5,
    10,
  ];
}

/// Stable OpenTelemetry HTTP semantic-convention helpers.
abstract final class SemanticHttp {
  static const _knownMethods = {
    'CONNECT',
    'DELETE',
    'GET',
    'HEAD',
    'OPTIONS',
    'PATCH',
    'POST',
    'PUT',
    'QUERY',
    'TRACE',
  };

  /// Returns [method] when known, otherwise the stable `_OTHER` value.
  static String normalizedMethod(String method) =>
      _knownMethods.contains(method) ? method : '_OTHER';

  /// Returns the explicit or scheme-default server port, when known.
  static int? serverPort(Uri uri) {
    if (uri.hasPort) return uri.port;
    return switch (uri.scheme.toLowerCase()) {
      'http' => 80,
      'https' => 443,
      _ => null,
    };
  }
}

/// Represents semantic events.
abstract final class SemanticEvents {
  /// The exception.
  static const exception = 'exception';

  /// The http client request exception.
  static const httpClientRequestException = 'http.client.request.exception';

  /// The http server request exception.
  static const httpServerRequestException = 'http.server.request.exception';
}
