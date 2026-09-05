import '../api/span.dart';
import '../common/console_formatting.dart';
import 'pretty_trace_options.dart';

/// Shared renderer for compact spans and buffered trees.
final class TraceConsoleRenderer {
  /// Creates a renderer without retaining telemetry.
  const TraceConsoleRenderer(this.options, this.traceOptions);

  /// Common console controls.
  final PrettyConsoleOptions options;

  /// Trace-specific controls.
  final PrettyTraceOptions traceOptions;

  /// Renders a completed span.
  String render(SpanData span) {
    final printer = ConsolePrettyPrinter(options);
    final buffer = StringBuffer(
      printer.heading(
        timestamp: span.endTime,
        label: kind(span),
        message: summary(span),
        scope: span.instrumentationScope.name,
        scopeVersion: span.instrumentationScope.version,
        color: span.status == SpanStatus.error
            ? consoleErrorColor
            : span.duration >= traceOptions.slowThreshold
            ? consoleWarningColor
            : consoleDebugColor,
      ),
    );
    buffer.write(details(span));
    return buffer.toString();
  }

  /// Identifies the operation using only recorded semantic attributes.
  String kind(SpanData span) =>
      span.attributes.containsKey('http.request.method')
      ? 'HTTP'
      : span.attributes.containsKey('navigation.operation')
      ? 'NAV'
      : 'SPAN';

  /// Formats the operation and its outcome without inferring success.
  String summary(SpanData span) {
    final a = span.attributes;
    var name = span.name;
    if (kind(span) == 'HTTP') {
      final uri = Uri.tryParse(a['url.full']?.toString() ?? '');
      final host = a['server.address'] ?? uri?.host ?? '';
      final path = a['http.route'] ?? uri?.path ?? '';
      name = '${a['http.request.method']} $host$path';
      if (a['http.response.status_code'] != null) {
        name += ' → ${a['http.response.status_code']}';
      }
    } else if (kind(span) == 'NAV') {
      name =
          '${a['navigation.operation']} ${a['app.screen.name'] ?? span.name}';
    }
    final status = span.status == SpanStatus.error
        ? '  ERROR'
        : span.status == SpanStatus.ok
        ? '  OK'
        : '';
    final slow = span.duration >= traceOptions.slowThreshold ? '  SLOW' : '';
    return '${_text(name)} · ${duration(span.duration)}$status$slow';
  }

  /// Diagnostic block; preserves full correlation IDs and stack newlines.
  String details(SpanData span) {
    final p = ConsolePrettyPrinter(options);
    final b = StringBuffer();
    final verbose = traceOptions.detail == TraceConsoleDetail.verbose;
    final expanded =
        traceOptions.expandErrors && span.status == SpanStatus.error;
    if (traceOptions.detail == TraceConsoleDetail.minimal && !expanded) {
      return '';
    }
    if (span.statusDescription != null) {
      p.detail(b, 'status', span.statusDescription);
    }
    final promoted = kind(span) == 'HTTP'
        ? {
            'http.request.method',
            'url.full',
            'server.address',
            'http.route',
            'http.response.status_code',
          }
        : kind(span) == 'NAV'
        ? {'navigation.operation', 'app.screen.name'}
        : <String>{};
    final entries = span.attributes.entries
        .where((e) => verbose || !promoted.contains(e.key))
        .toList();
    final visible = verbose
        ? entries
        : entries.take(traceOptions.maxAttributes).toList();
    for (final e in visible) {
      final formatted = p.formatValue(e.value);
      b.write('\n  ${_text(e.key).padRight(12)}${_text(formatted)}');
      if (formatted.endsWith('…')) b.write(' [truncated]');
    }
    if (visible.length < entries.length) {
      b.write(
        '\n  … ${entries.length - visible.length} additional attributes (verbose to show)',
      );
    }
    if (verbose || expanded) {
      for (final event in span.events) {
        final exception = event.attributes['exception.message'];
        final stack = event.attributes['exception.stacktrace'];
        if (event.name == 'exception') {
          p.detail(
            b,
            'exception',
            '${event.attributes['exception.type'] ?? 'Exception'}: ${exception ?? event.name}',
          );
          if (options.includeStackTrace && stack != null) {
            final lines = stack
                .toString()
                .split('\n')
                .where((s) => s.trim().isNotEmpty)
                .toList();
            final shown = verbose
                ? lines
                : lines.take(traceOptions.maxStackFrames).toList();
            p.block(b, 'stack', shown.map(_text));
            if (shown.length < lines.length) {
              b.write(
                '\n    … ${lines.length - shown.length} additional frames (verbose to show)',
              );
            }
          }
        } else {
          p.block(b, 'events', [
            '${offset(event.timestamp.difference(span.startTime))} ${_text(event.name)}',
          ]);
          p.attributes(b, event.attributes);
        }
      }
      if (span.links.isNotEmpty && options.includeTraceContext) {
        p.block(
          b,
          'links',
          span.links.map((l) => '${l.context.traceId} / ${l.context.spanId}'),
        );
      }
    }
    if (options.includeTraceContext && (expanded || verbose)) {
      b.write(
        '\n  trace       ${span.context.traceId}\n  span        ${span.context.spanId}',
      );
      if (span.parentSpanId != null) {
        b.write('\n  parent      ${span.parentSpanId}');
      }
    }
    final dropped = [
      if (span.droppedAttributes > 0) 'attributes=${span.droppedAttributes}',
      if (span.droppedEvents > 0) 'events=${span.droppedEvents}',
      if (span.droppedLinks > 0) 'links=${span.droppedLinks}',
    ];
    if (dropped.isNotEmpty) p.detail(b, 'dropped', dropped.join(' '));
    p.resource(b, span.resource.attributes);
    return b.toString();
  }

  /// Renders the local spans received during one bounded window.
  String tree(List<SpanData> spans) {
    final ordered = [...spans]
      ..sort((a, b) => a.startTime.compareTo(b.startTime));
    final ids = ordered.map((s) => s.context.spanId).toSet();
    final roots = ordered.where((s) => !ids.contains(s.parentSpanId)).toList();
    final first = roots.isEmpty ? ordered.first : roots.first;
    final b = StringBuffer(
      ConsolePrettyPrinter(options).heading(
        timestamp: first.startTime,
        label: 'TRACE',
        message: '${_text(first.name)} · LOCAL / PARTIAL',
        scope: first.instrumentationScope.name,
        scopeVersion: first.instrumentationScope.version,
        color: consoleDebugColor,
      ),
    );
    final children = <String, List<SpanData>>{};
    for (final s in ordered) {
      children.putIfAbsent(s.parentSpanId ?? '', () => []).add(s);
    }
    final seen = <String>{};
    // Iterative traversal also handles malformed cyclic or very deep input.
    final pending = <(SpanData, int)>[for (final s in roots.reversed) (s, 0)];
    void drain() {
      while (pending.isNotEmpty) {
        final (s, depth) = pending.removeLast();
        if (!seen.add(s.context.spanId)) continue;
        final indent = '  ' * depth.clamp(0, 20);
        b.write(
          '\n$indent└─ ${kind(s)} ${summary(s)}  ${offset(s.startTime.difference(first.startTime))}',
        );
        final block = details(s);
        if (block.isNotEmpty) b.write(block.replaceAll('\n', '\n$indent   '));
        for (final child
            in (children[s.context.spanId] ?? <SpanData>[]).reversed) {
          pending.add((child, depth + 1));
        }
      }
    }

    drain();
    for (final s in ordered) {
      if (!seen.contains(s.context.spanId)) {
        pending.add((s, 0));
        drain();
      }
    }
    b.write('\n${seen.length} local spans · offsets from first displayed root');
    if (options.includeTraceContext) {
      b.write('\nTrace ${first.context.traceId}');
    }
    return b.toString();
  }
}

String _text(String value) => value.replaceAll(RegExp(r'[\x00-\x1f\x7f]'), ' ');

/// Human duration with units, including negative offsets.
String duration(Duration value) {
  final us = value.inMicroseconds;
  if (us.abs() < 1000) return '$us µs';
  if (us.abs() < 1000000) return '${(us / 1000).toStringAsFixed(2)} ms';
  return '${(us / 1000000).toStringAsFixed(2)} s';
}

/// Explicitly signed offset.
String offset(Duration value) =>
    '${value.isNegative ? '' : '+'}${duration(value)}';
