import 'dart:convert';
import 'dart:typed_data';

import 'package:obsi/obsi.dart';

/// Encodes an OTLP `ExportTraceServiceRequest` using Protocol Buffers.
Uint8List encodeSpanExportRequest(List<SpanData> spans) {
  final writer = _ProtoWriter();
  for (final resourceGroup in _groupByContext<SpanData>(
    spans,
    resourceOf: (span) => span.resource,
    scopeOf: (span) => span.instrumentationScope,
  )) {
    writer.message(1, (resourceSpans) {
      resourceSpans.message(1, (resource) {
        _writeAttributes(resource, 1, resourceGroup.resource.attributes);
      });
      for (final scopeGroup in resourceGroup.scopes) {
        resourceSpans.message(2, (scopeSpans) {
          _writeScope(scopeSpans, scopeGroup.scope);
          for (final span in scopeGroup.items) {
            scopeSpans.message(2, (value) => _writeSpan(value, span));
          }
          scopeSpans.string(3, scopeGroup.scope.schemaUrl);
        });
      }
    });
  }
  return writer.takeBytes();
}

/// Encodes an OTLP `ExportLogsServiceRequest` using Protocol Buffers.
Uint8List encodeLogExportRequest(List<LogRecord> records) {
  final writer = _ProtoWriter();
  for (final resourceGroup in _groupByContext<LogRecord>(
    records,
    resourceOf: (record) => record.resource,
    scopeOf: (record) => record.instrumentationScope,
  )) {
    writer.message(1, (resourceLogs) {
      resourceLogs.message(1, (resource) {
        _writeAttributes(resource, 1, resourceGroup.resource.attributes);
      });
      for (final scopeGroup in resourceGroup.scopes) {
        resourceLogs.message(2, (scopeLogs) {
          _writeScope(scopeLogs, scopeGroup.scope);
          for (final record in scopeGroup.items) {
            scopeLogs.message(2, (value) => _writeLog(value, record));
          }
          scopeLogs.string(3, scopeGroup.scope.schemaUrl);
        });
      }
    });
  }
  return writer.takeBytes();
}

/// Encodes an OTLP `ExportMetricsServiceRequest` using Protocol Buffers.
Uint8List encodeMetricExportRequest(List<MetricData> metrics) {
  final writer = _ProtoWriter();
  for (final resourceGroup in _groupByContext<MetricData>(
    metrics,
    resourceOf: (metric) => metric.resource,
    scopeOf: (metric) => metric.instrumentationScope,
  )) {
    writer.message(1, (resourceMetrics) {
      resourceMetrics.message(1, (resource) {
        _writeAttributes(resource, 1, resourceGroup.resource.attributes);
      });
      for (final scopeGroup in resourceGroup.scopes) {
        resourceMetrics.message(2, (scopeMetrics) {
          _writeScope(scopeMetrics, scopeGroup.scope);
          for (final metric in scopeGroup.items) {
            scopeMetrics.message(2, (value) => _writeMetric(value, metric));
          }
          scopeMetrics.string(3, scopeGroup.scope.schemaUrl);
        });
      }
    });
  }
  return writer.takeBytes();
}

void _writeScope(_ProtoWriter target, InstrumentationScope scope) {
  target.message(1, (value) {
    value
      ..string(1, scope.name)
      ..string(2, scope.version);
    _writeAttributes(value, 3, scope.attributes);
  });
}

void _writeSpan(_ProtoWriter target, SpanData span) {
  target
    ..bytes(1, _hexBytes(span.context.traceId))
    ..bytes(2, _hexBytes(span.context.spanId))
    ..string(3, span.context.traceState)
    ..bytes(4, _hexBytesOrNull(span.parentSpanId))
    ..string(5, span.name)
    ..varint(6, span.kind.index + 1)
    ..fixed64(7, _nanos(span.startTime))
    ..fixed64(8, _nanos(span.endTime));
  _writeAttributes(target, 9, span.attributes);
  target.varint(10, span.droppedAttributes);
  for (final event in span.events) {
    target.message(11, (value) {
      value
        ..fixed64(1, _nanos(event.timestamp))
        ..string(2, event.name);
      _writeAttributes(value, 3, event.attributes);
    });
  }
  target.varint(12, span.droppedEvents);
  for (final link in span.links) {
    target.message(13, (value) {
      value
        ..bytes(1, _hexBytes(link.context.traceId))
        ..bytes(2, _hexBytes(link.context.spanId))
        ..string(3, link.context.traceState);
      _writeAttributes(value, 4, link.attributes);
      value.fixed32(6, link.context.sampled ? 1 : 0);
    });
  }
  target
    ..varint(14, span.droppedLinks)
    ..message(15, (status) {
      status
        ..string(2, span.statusDescription)
        ..varint(3, span.status.index);
    })
    ..fixed32(16, span.context.sampled ? 1 : 0);
}

void _writeLog(_ProtoWriter target, LogRecord record) {
  target
    ..fixed64(1, _nanos(record.timestamp))
    ..varint(2, switch (record.severity) {
      LogSeverity.trace => 1,
      LogSeverity.debug => 5,
      LogSeverity.info => 9,
      LogSeverity.warn => 13,
      LogSeverity.error => 17,
      LogSeverity.fatal => 21,
    })
    ..string(3, record.severity.name.toUpperCase())
    ..message(5, (body) => _writeAnyValue(body, record.body));
  _writeAttributes(target, 6, {
    ...record.attributes,
    if (record.error != null) 'exception.message': record.error.toString(),
    if (record.stackTrace != null)
      'exception.stacktrace': record.stackTrace.toString(),
  });
  final context = record.spanContext;
  if (context != null) {
    target
      ..fixed32(8, context.sampled ? 1 : 0)
      ..bytes(9, _hexBytes(context.traceId))
      ..bytes(10, _hexBytes(context.spanId));
  }
  target.fixed64(11, _nanos(record.observedTimestamp));
}

void _writeMetric(_ProtoWriter target, MetricData metric) {
  target
    ..string(1, metric.name)
    ..string(2, metric.description)
    ..string(3, metric.unit);
  if (metric.kind == InstrumentKind.histogram) {
    target.message(9, (histogram) {
      for (final point in metric.points) {
        histogram.message(1, (value) => _writeHistogramPoint(value, point));
      }
      histogram.varint(2, _temporality(metric.temporality));
    });
    return;
  }
  if (metric.kind == InstrumentKind.gauge ||
      metric.kind == InstrumentKind.observableGauge) {
    target.message(5, (gauge) {
      for (final point in metric.points) {
        gauge.message(1, (value) => _writeNumberPoint(value, point));
      }
    });
    return;
  }
  target.message(7, (sum) {
    for (final point in metric.points) {
      sum.message(1, (value) => _writeNumberPoint(value, point));
    }
    sum
      ..varint(2, _temporality(metric.temporality))
      ..boolean(3, metric.isMonotonic ?? false);
  });
}

void _writeNumberPoint(_ProtoWriter target, MetricPoint point) {
  target
    ..fixed64(2, _nanosOrZero(point.startTime))
    ..fixed64(3, _nanos(point.timestamp));
  final value = point.value ?? 0;
  if (value is int) {
    target.sfixed64(6, value);
  } else {
    target.doubleValue(4, value.toDouble());
  }
  _writeAttributes(target, 7, point.attributes);
}

void _writeHistogramPoint(_ProtoWriter target, MetricPoint point) {
  _writeAttributes(target, 9, point.attributes);
  target
    ..fixed64(2, _nanosOrZero(point.startTime))
    ..fixed64(3, _nanos(point.timestamp))
    ..fixed64(4, point.count ?? 0);
  if (point.sum != null) target.doubleValue(5, point.sum!.toDouble());
  target.packedFixed64(6, point.bucketCounts);
  target.packedDoubles(7, point.boundaries);
  if (point.min != null) target.doubleValue(11, point.min!.toDouble());
  if (point.max != null) target.doubleValue(12, point.max!.toDouble());
}

void _writeAttributes(
  _ProtoWriter target,
  int field,
  Map<String, Object?> attributes,
) {
  for (final entry in attributes.entries) {
    target.message(field, (keyValue) {
      keyValue
        ..string(1, entry.key)
        ..message(2, (value) => _writeAnyValue(value, entry.value));
    });
  }
}

void _writeAnyValue(_ProtoWriter target, Object? value) {
  if (value == null) {
    target.string(1, '');
  } else if (value is String) {
    target.string(1, value);
  } else if (value is bool) {
    target.boolean(2, value);
  } else if (value is int) {
    target.varint(3, value);
  } else if (value is double) {
    target.doubleValue(4, value);
  } else if (value is List) {
    target.message(5, (array) {
      for (final item in value) {
        array.message(1, (element) => _writeAnyValue(element, item));
      }
    });
  } else {
    target.string(1, value.toString());
  }
}

int _temporality(AggregationTemporality? temporality) => switch (temporality) {
  AggregationTemporality.delta => 1,
  AggregationTemporality.cumulative || null => 2,
};

int _nanos(DateTime value) => value.toUtc().microsecondsSinceEpoch * 1000;

int _nanosOrZero(DateTime? value) => value == null ? 0 : _nanos(value);

Uint8List _hexBytes(String value) {
  final result = Uint8List(value.length ~/ 2);
  for (var index = 0; index < result.length; index++) {
    result[index] = int.parse(
      value.substring(index * 2, index * 2 + 2),
      radix: 16,
    );
  }
  return result;
}

Uint8List? _hexBytesOrNull(String? value) =>
    value == null ? null : _hexBytes(value);

List<_ResourceGroup<T>> _groupByContext<T>(
  List<T> values, {
  required Resource Function(T value) resourceOf,
  required InstrumentationScope Function(T value) scopeOf,
}) {
  final groups = <String, _ResourceGroup<T>>{};
  for (final value in values) {
    final resource = resourceOf(value);
    final scope = scopeOf(value);
    final resourceKey = _attributeKey(resource.attributes);
    final resourceGroup = groups.putIfAbsent(
      resourceKey,
      () => _ResourceGroup<T>(resource),
    );
    final scopeKey = [
      scope.name,
      scope.version ?? '',
      scope.schemaUrl ?? '',
      _attributeKey(scope.attributes),
    ].join('\u0000');
    resourceGroup.scopeGroups
        .putIfAbsent(scopeKey, () => _ScopeGroup<T>(scope))
        .items
        .add(value);
  }
  return groups.values.toList(growable: false);
}

String _attributeKey(Map<String, Object?> attributes) {
  final keys = attributes.keys.toList()..sort();
  return jsonEncode({for (final key in keys) key: attributes[key]});
}

final class _ResourceGroup<T> {
  _ResourceGroup(this.resource);

  final Resource resource;
  final Map<String, _ScopeGroup<T>> scopeGroups = {};

  List<_ScopeGroup<T>> get scopes => scopeGroups.values.toList(growable: false);
}

final class _ScopeGroup<T> {
  _ScopeGroup(this.scope);

  final InstrumentationScope scope;
  final List<T> items = [];
}

/// Parsed signal-agnostic fields from an OTLP partial-success response.
final class OtlpProtobufPartialSuccess {
  /// Creates a parsed partial-success response.
  const OtlpProtobufPartialSuccess(this.rejectedItems, this.message);

  /// Number of telemetry items rejected by the collector.
  final int rejectedItems;

  /// Collector-provided diagnostic message.
  final String message;
}

/// Decodes the optional partial-success field from an OTLP response.
OtlpProtobufPartialSuccess? decodePartialSuccess(Uint8List bytes) {
  final response = _ProtoReader(bytes);
  while (!response.isDone) {
    final tag = response.varint();
    final field = tag >> 3;
    final wireType = tag & 7;
    if (field == 1 && wireType == 2) {
      final partial = _ProtoReader(response.lengthDelimited());
      var rejected = 0;
      var message = '';
      while (!partial.isDone) {
        final partialTag = partial.varint();
        final partialField = partialTag >> 3;
        final partialWireType = partialTag & 7;
        if (partialField == 1 && partialWireType == 0) {
          rejected = partial.varint();
        } else if (partialField == 2 && partialWireType == 2) {
          message = utf8.decode(
            partial.lengthDelimited(),
            allowMalformed: true,
          );
        } else {
          partial.skip(partialWireType);
        }
      }
      return OtlpProtobufPartialSuccess(rejected, message);
    }
    response.skip(wireType);
  }
  return null;
}

final class _ProtoWriter {
  final BytesBuilder _bytes = BytesBuilder(copy: false);

  Uint8List takeBytes() => _bytes.takeBytes();

  void varint(int field, int? value) {
    if (value == null || value == 0) return;
    _tag(field, 0);
    _rawVarint(value);
  }

  void boolean(int field, bool value) {
    if (!value) return;
    varint(field, 1);
  }

  void fixed32(int field, int value) {
    if (value == 0) return;
    _tag(field, 5);
    final data = ByteData(4)..setUint32(0, value, Endian.little);
    _bytes.add(data.buffer.asUint8List());
  }

  void fixed64(int field, int value) {
    if (value == 0) return;
    _tag(field, 1);
    _rawFixed64(value);
  }

  void sfixed64(int field, int value) {
    if (value == 0) return;
    _tag(field, 1);
    final data = ByteData(8)..setInt64(0, value, Endian.little);
    _bytes.add(data.buffer.asUint8List());
  }

  void doubleValue(int field, double value) {
    if (value == 0) return;
    _tag(field, 1);
    final data = ByteData(8)..setFloat64(0, value, Endian.little);
    _bytes.add(data.buffer.asUint8List());
  }

  void string(int field, String? value) {
    if (value == null || value.isEmpty) return;
    bytes(field, utf8.encode(value));
  }

  void bytes(int field, List<int>? value) {
    if (value == null || value.isEmpty) return;
    _tag(field, 2);
    _rawVarint(value.length);
    _bytes.add(value);
  }

  void message(int field, void Function(_ProtoWriter writer) write) {
    final nested = _ProtoWriter();
    write(nested);
    final value = nested.takeBytes();
    _tag(field, 2);
    _rawVarint(value.length);
    _bytes.add(value);
  }

  void packedFixed64(int field, Iterable<int> values) {
    final nested = _ProtoWriter();
    for (final value in values) {
      nested._rawFixed64(value);
    }
    bytes(field, nested.takeBytes());
  }

  void packedDoubles(int field, Iterable<double> values) {
    final builder = BytesBuilder(copy: false);
    for (final value in values) {
      final data = ByteData(8)..setFloat64(0, value, Endian.little);
      builder.add(data.buffer.asUint8List());
    }
    bytes(field, builder.takeBytes());
  }

  void _tag(int field, int wireType) => _rawVarint((field << 3) | wireType);

  void _rawVarint(int value) {
    var remaining = value.toUnsigned(64);
    while (remaining >= 0x80) {
      _bytes.addByte((remaining & 0x7f) | 0x80);
      remaining >>= 7;
    }
    _bytes.addByte(remaining);
  }

  void _rawFixed64(int value) {
    final data = ByteData(8)..setUint64(0, value.toUnsigned(64), Endian.little);
    _bytes.add(data.buffer.asUint8List());
  }
}

final class _ProtoReader {
  _ProtoReader(this.bytes);

  final Uint8List bytes;
  var _offset = 0;

  bool get isDone => _offset >= bytes.length;

  int varint() {
    var value = 0;
    var shift = 0;
    while (_offset < bytes.length && shift < 70) {
      final byte = bytes[_offset++];
      value |= (byte & 0x7f) << shift;
      if (byte & 0x80 == 0) return value;
      shift += 7;
    }
    throw const FormatException('Invalid OTLP Protobuf varint');
  }

  Uint8List lengthDelimited() {
    final length = varint();
    final end = _offset + length;
    if (length < 0 || end > bytes.length) {
      throw const FormatException('Invalid OTLP Protobuf field length');
    }
    final result = Uint8List.sublistView(bytes, _offset, end);
    _offset = end;
    return result;
  }

  void skip(int wireType) {
    switch (wireType) {
      case 0:
        varint();
        return;
      case 1:
        _offset += 8;
        break;
      case 2:
        lengthDelimited();
        return;
      case 5:
        _offset += 4;
        break;
      default:
        throw FormatException('Unsupported OTLP Protobuf wire type $wireType');
    }
    if (_offset > bytes.length) {
      throw const FormatException('Truncated OTLP Protobuf response');
    }
  }
}
