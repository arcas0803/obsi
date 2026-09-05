/// Amount of diagnostic context printed below a span.
enum TraceConsoleDetail {
  /// Only the operation summary, plus errors when expansion is enabled.
  minimal,

  /// A bounded selection of attributes and diagnostic context.
  standard,

  /// All attributes, events and links.
  verbose,
}

/// Presentation and buffering controls for console traces.
final class PrettyTraceOptions {
  /// Creates trace settings. Buffers use a fixed window, not a sliding timeout.
  const PrettyTraceOptions({
    this.detail = TraceConsoleDetail.standard,
    this.expandErrors = true,
    this.slowThreshold = const Duration(milliseconds: 500),
    this.maxStackFrames = 8,
    this.maxAttributes = 6,
    this.groupWait = const Duration(milliseconds: 200),
    this.maxBufferedSpans = 1000,
  }) : assert(maxStackFrames > 0),
       assert(maxAttributes > 0),
       assert(maxBufferedSpans > 0);

  /// Controls how much context is printed.
  final TraceConsoleDetail detail;

  /// Expands recorded exceptions and events on failed spans.
  final bool expandErrors;

  /// Durations at or above this threshold are labelled SLOW, not ERROR.
  final Duration slowThreshold;

  /// Stack frames shown outside verbose mode, in original execution order.
  final int maxStackFrames;

  /// Attributes shown per span outside verbose mode.
  final int maxAttributes;

  /// Maximum time a tree group waits after its first received span.
  final Duration groupWait;

  /// Maximum number of buffered spans across all tree groups.
  final int maxBufferedSpans;
}
