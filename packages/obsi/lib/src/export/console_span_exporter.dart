import 'dart:convert';
import 'dart:async';

import 'pretty_trace_options.dart';
import 'trace_console_renderer.dart';

import '../api/span.dart';
import '../common/console_formatting.dart';
import 'span_exporter.dart';

/// Represents console span exporter.
final class ConsoleSpanExporter implements SpanExporter {
  /// Creates an exporter that writes one JSON object per span.
  const ConsoleSpanExporter({this.writer})
    : _pretty = false,
      options = const PrettyConsoleOptions(),
      traceOptions = const PrettyTraceOptions(),
      _tree = null;

  /// Creates an exporter optimized for human-readable development output.
  const ConsoleSpanExporter.pretty({
    this.options = const PrettyConsoleOptions(),
    this.writer,
    this.traceOptions = const PrettyTraceOptions(),
  }) : _pretty = true,
       _tree = null;

  /// Groups local spans across batches into bounded, explicitly partial trees.
  /// Call [forceFlush] or [shutdown] to drain pending groups immediately.
  ConsoleSpanExporter.tree({
    this.options = const PrettyConsoleOptions(),
    this.traceOptions = const PrettyTraceOptions(),
    this.writer,
  }) : _pretty = true,
       _tree = _TraceBuffer() {
    if (traceOptions.maxBufferedSpans <= 0 ||
        traceOptions.groupWait.isNegative) {
      throw ArgumentError('Invalid tree buffer limits');
    }
  }

  /// Trace-specific detail and grouping controls.
  final PrettyTraceOptions traceOptions;
  final _TraceBuffer? _tree;

  final bool _pretty;

  /// Presentation settings used in pretty mode.
  final PrettyConsoleOptions options;

  /// Optional destination used instead of [print].
  final ConsoleWriter? writer;

  /// Performs export.
  @override
  Future<void> export(List<SpanData> spans) async {
    if (_pretty &&
        (traceOptions.slowThreshold.isNegative ||
            traceOptions.maxStackFrames <= 0 ||
            traceOptions.maxAttributes <= 0 ||
            options.maxValueLength <= 0)) {
      throw ArgumentError('Invalid trace presentation limits');
    }
    final tree = _tree;
    if (tree != null) {
      if (tree.closed) throw StateError('Exporter has shut down');
      tree.add(
        spans,
        traceOptions,
        (group) =>
            _write(TraceConsoleRenderer(options, traceOptions).tree(group)),
      );
      return;
    }
    for (final span in spans) {
      final message = _pretty
          ? TraceConsoleRenderer(options, traceOptions).render(span)
          : jsonEncode({
              'name': span.name,
              'traceId': span.context.traceId,
              'spanId': span.context.spanId,
              'parentSpanId': span.parentSpanId,
              'kind': span.kind.name,
              'status': span.status.name,
              'statusDescription': span.statusDescription,
              'startTime': span.startTime.toUtc().toIso8601String(),
              'endTime': span.endTime.toUtc().toIso8601String(),
              'durationMicros': span.duration.inMicroseconds,
              'attributes': span.attributes,
              'events': [
                for (final event in span.events)
                  {
                    'name': event.name,
                    'timestamp': event.timestamp.toUtc().toIso8601String(),
                    'attributes': event.attributes,
                  },
              ],
            });
      if (writer case final output?) {
        output(message);
      } else {
        // ignore: avoid_print
        print(message);
      }
    }
  }

  /// Performs shutdown.
  @override
  Future<void> shutdown() async {
    final tree = _tree;
    if (tree == null || tree.closed) return;
    tree.closed = true;
    await forceFlush();
  }

  /// Drains buffered trees; compact and JSON exporters have nothing buffered.
  Future<void> forceFlush() async => _tree?.flush();

  void _write(String message) {
    if (writer case final output?) {
      output(message);
    } else {
      // ignore: avoid_print
      print(message);
    }
  }
}

final class _TraceBuffer {
  final groups = <String, List<SpanData>>{};
  final timers = <String, Timer>{};
  bool closed = false;
  int count = 0;
  Object? failure;
  StackTrace? failureStack;
  void Function(List<SpanData>)? output;

  void add(
    List<SpanData> spans,
    PrettyTraceOptions options,
    void Function(List<SpanData>) write,
  ) {
    _checkFailure();
    output = write;
    for (final span in spans) {
      if (count >= options.maxBufferedSpans) _emit(groups.keys.first);
      final id = span.context.traceId;
      if (!groups.containsKey(id)) {
        groups[id] = [];
        timers[id] = Timer(options.groupWait, () {
          try {
            _emit(id);
          } catch (error, stack) {
            failure = error;
            failureStack = stack;
          }
        });
      }
      groups[id]!.add(span);
      count++;
    }
  }

  void _emit(String id) {
    timers.remove(id)?.cancel();
    final group = groups.remove(id);
    if (group == null) return;
    count -= group.length;
    output!(group);
  }

  void _checkFailure() {
    final error = failure;
    if (error == null) return;
    failure = null;
    Error.throwWithStackTrace(error, failureStack!);
  }

  void flush() {
    Object? error;
    StackTrace? stack;
    for (final id in groups.keys.toList()) {
      try {
        _emit(id);
      } catch (e, s) {
        error ??= e;
        stack ??= s;
      }
    }
    _checkFailure();
    if (error != null) Error.throwWithStackTrace(error, stack!);
  }
}
