import '../api/span_context.dart';
import 'trace_propagator.dart';

/// Injects and extracts the W3C Trace Context HTTP headers.
final class W3CTraceContextPropagator implements TracePropagator {
  /// Creates a instance.
  const W3CTraceContextPropagator();

  static final RegExp _traceParent = RegExp(
    r'^([0-9a-f]{2})-([0-9a-f]{32})-([0-9a-f]{16})-([0-9a-f]{2})(.*)$',
  );

  /// Performs inject.
  @override
  void inject(SpanContext context, Map<String, String> carrier) {
    if (!context.isValid) return;
    carrier['traceparent'] =
        '00-${context.traceId}-${context.spanId}-${context.sampled ? '01' : '00'}';
    final traceState = context.traceState;
    final validatedTraceState = _validTraceState(traceState);
    if (validatedTraceState != null) {
      carrier['tracestate'] = validatedTraceState;
    }
  }

  /// Performs extract.
  @override
  SpanContext? extract(Map<String, String> carrier) {
    final value = _header(carrier, 'traceparent')?.trim();
    if (value == null) return null;
    final match = _traceParent.firstMatch(value);
    if (match == null || match[1] == 'ff') return null;
    final version = match[1]!;
    final suffix = match[5]!;
    if (version == '00' && suffix.isNotEmpty) return null;
    if (suffix.isNotEmpty &&
        (!suffix.startsWith('-') || suffix.endsWith('-'))) {
      return null;
    }

    final context = SpanContext(
      traceId: match[2]!,
      spanId: match[3]!,
      sampled: (int.parse(match[4]!, radix: 16) & 1) == 1,
      traceState: _validTraceState(_header(carrier, 'tracestate')),
      isRemote: true,
    );
    return context.isValid ? context : null;
  }

  static String? _header(Map<String, String> carrier, String name) {
    for (final entry in carrier.entries) {
      if (entry.key.toLowerCase() == name) return entry.value;
    }
    return null;
  }

  static String? _validTraceState(String? value) {
    if (value == null || value.isEmpty || value.length > 8192) return null;
    final seen = <String>{};
    final members = value.split(',');
    if (members.length > 32) return null;
    for (final rawMember in members) {
      final member = rawMember.trim();
      final separator = member.indexOf('=');
      if (separator <= 0) return null;
      final key = member.substring(0, separator);
      final memberValue = member.substring(separator + 1);
      if (!_traceStateKey.hasMatch(key) ||
          !seen.add(key) ||
          memberValue.isEmpty ||
          memberValue.codeUnits.any(
            (unit) =>
                unit < 0x20 || unit > 0x7e || unit == 0x2c || unit == 0x3d,
          ) ||
          memberValue.endsWith(' ')) {
        return null;
      }
    }
    return value;
  }

  static final RegExp _traceStateKey = RegExp(
    r'^(?:[a-z][a-z0-9_*/-]{0,255}|[a-z0-9][a-z0-9_*/-]{0,240}@[a-z][a-z0-9_*/-]{0,13})$',
  );
}
