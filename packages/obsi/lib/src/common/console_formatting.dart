/// Receives one fully formatted console record.
typedef ConsoleWriter = void Function(String message);

/// Shared presentation settings for human-friendly console exporters.
final class PrettyConsoleOptions {
  /// Creates presentation settings for a pretty console exporter.
  const PrettyConsoleOptions({
    this.colors = true,
    this.includeTimestamp = true,
    this.includeResource = false,
    this.includeScope = true,
    this.includeScopeVersion = false,
    this.includeTraceContext = true,
    this.includeStackTrace = true,
    this.multilineAttributes = false,
    this.maxValueLength = 160,
  }) : assert(maxValueLength > 0);

  /// Whether ANSI colors are included in the output.
  final bool colors;

  /// Whether the local timestamp is included in each heading.
  final bool includeTimestamp;

  /// Whether resource attributes are included in the detail block.
  final bool includeResource;

  /// Whether the instrumentation scope is included in each heading.
  final bool includeScope;

  /// Whether the instrumentation scope version is included when available.
  final bool includeScopeVersion;

  /// Whether trace and span identifiers are included when available.
  final bool includeTraceContext;

  /// Whether stack traces are included with errors.
  final bool includeStackTrace;

  /// Whether attributes are printed one per line instead of compactly.
  final bool multilineAttributes;

  /// Maximum displayed length of an individual value.
  final int maxValueLength;
}

/// Internal renderer shared by the pretty console exporters.
final class ConsolePrettyPrinter {
  /// Creates a renderer using [options].
  const ConsolePrettyPrinter(this.options);

  /// Presentation settings used by this renderer.
  final PrettyConsoleOptions options;

  /// Builds the first line of a console record.
  String heading({
    required DateTime timestamp,
    required String label,
    required String message,
    required String scope,
    String? scopeVersion,
    String? color,
  }) {
    final parts = <String>[
      if (options.includeTimestamp) formatTimestamp(timestamp),
      colorize(label.padRight(6), color),
      if (options.includeScope)
        '[${scopeVersion != null && options.includeScopeVersion ? '$scope@$scopeVersion' : scope}]',
      message,
    ];
    return parts.join(' ');
  }

  /// Formats a timestamp for quick scanning in a terminal.
  String formatTimestamp(DateTime timestamp) {
    final local = timestamp.toLocal();
    String two(int value) => value.toString().padLeft(2, '0');
    String three(int value) => value.toString().padLeft(3, '0');
    return '${two(local.hour)}:${two(local.minute)}:${two(local.second)}.'
        '${three(local.millisecond)}';
  }

  /// Applies an ANSI [color] when colors are enabled.
  String colorize(String value, String? color) =>
      options.colors && color != null ? '\x1B[${color}m$value\x1B[0m' : value;

  /// Formats an identifier compactly while retaining both ends.
  String identifier(String value) {
    if (value.length <= 12) return value;
    return '${value.substring(0, 8)}…${value.substring(value.length - 4)}';
  }

  /// Adds a labelled detail line to [buffer].
  void detail(StringBuffer buffer, String label, Object? value) {
    if (value == null) return;
    buffer
      ..write('\n  ')
      ..write(colorize(label.padRight(12), '2'))
      ..write(formatValue(value));
  }

  /// Adds structured attributes to [buffer].
  void attributes(
    StringBuffer buffer,
    Map<String, Object?> values, {
    String label = 'attributes',
  }) {
    if (values.isEmpty) return;
    if (!options.multilineAttributes) {
      detail(buffer, label, compactMap(values));
      return;
    }
    buffer
      ..write('\n  ')
      ..write(colorize(label, '2'));
    for (final entry in values.entries) {
      buffer
        ..write('\n    ')
        ..write(entry.key.padRight(20))
        ..write(formatValue(entry.value));
    }
  }

  /// Adds resource attributes when configured.
  void resource(StringBuffer buffer, Map<String, Object?> values) {
    if (options.includeResource) attributes(buffer, values, label: 'resource');
  }

  /// Formats a map as key/value pairs.
  String compactMap(Map<Object?, Object?> values) => values.entries
      .map((entry) => '${entry.key}=${formatValue(entry.value)}')
      .join(' ');

  /// Formats and bounds a value for terminal display.
  String formatValue(Object? value) {
    final rendered = switch (value) {
      null => 'null',
      Map<Object?, Object?> map =>
        '{${map.entries.map((entry) => '${entry.key}: ${formatValue(entry.value)}').join(', ')}}',
      Iterable<Object?> values => '[${values.map(formatValue).join(', ')}]',
      _ => value.toString().replaceAll('\n', r'\n'),
    };
    if (rendered.length <= options.maxValueLength) return rendered;
    return '${rendered.substring(0, options.maxValueLength - 1)}…';
  }

  /// Appends a multi-line indented block.
  void block(StringBuffer buffer, String label, Iterable<String> lines) {
    final materialized = lines.where((line) => line.isNotEmpty).toList();
    if (materialized.isEmpty) return;
    buffer
      ..write('\n  ')
      ..write(colorize(label, '2'));
    for (final line in materialized) {
      buffer
        ..write('\n    ')
        ..write(line);
    }
  }
}

/// ANSI foreground color used for trace-level output.
const consoleTraceColor = '2';

/// ANSI foreground color used for debug-level output.
const consoleDebugColor = '36';

/// ANSI foreground color used for informational output.
const consoleInfoColor = '32';

/// ANSI foreground color used for warning output.
const consoleWarningColor = '33';

/// ANSI foreground color used for error output.
const consoleErrorColor = '31';

/// ANSI foreground color used for fatal output.
const consoleFatalColor = '1;31';
