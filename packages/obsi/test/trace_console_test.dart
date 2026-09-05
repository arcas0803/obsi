import 'dart:async';
import 'dart:convert';

import 'package:obsi/obsi.dart';
import 'package:test/test.dart';

const plain = PrettyConsoleOptions(colors: false, includeTimestamp: false);

void main() {
  test(
    'HTTP summary promotes fields, strips credentials and keeps unset neutral',
    () async {
      final out = <String>[];
      await ConsoleSpanExporter.pretty(options: plain, writer: out.add).export([
        span(
          attributes: {
            'http.request.method': 'GET',
            'url.full':
                'https://user:secret@api.test/products?token=secret#private',
            'http.response.status_code': 200,
          },
        ),
      ]);
      expect(out.single, contains('HTTP'));
      expect(out.single, contains('GET api.test/products → 200'));
      expect(out.single, isNot(contains('secret')));
      expect(out.single, isNot(contains('OK')));
      expect(out.single, isNot(contains('http.request.method')));
      expect(out.single.split('\n'), hasLength(1));
    },
  );

  test(
    'slow spans and navigation are readable without inventing an error',
    () async {
      final out = <String>[];
      await ConsoleSpanExporter.pretty(options: plain, writer: out.add).export([
        span(
          attributes: {
            'navigation.operation': 'push',
            'app.screen.name': '/cart',
          },
          ms: 600,
        ),
      ]);
      expect(out.single, contains('NAV'));
      expect(out.single, contains('push /cart'));
      expect(out.single, contains('SLOW'));
      expect(out.single, isNot(contains('ERROR')));
    },
  );

  test(
    'exceptions expand with real stack frames, full IDs and explicit limits',
    () async {
      final out = <String>[];
      await ConsoleSpanExporter.pretty(
        options: plain,
        writer: out.add,
        traceOptions: const PrettyTraceOptions(
          maxStackFrames: 1,
          maxAttributes: 1,
        ),
      ).export([
        span(
          status: SpanStatus.error,
          attributes: {'attempt': 2, 'order.id': '42'},
          events: [
            SpanEvent(
              name: 'exception',
              timestamp: DateTime.utc(2026),
              attributes: {
                'exception.type': 'StateError',
                'exception.message': 'declined',
                'exception.stacktrace': '#0 app.dart:10\n#1 app.dart:20',
              },
            ),
          ],
        ),
      ]);
      expect(out.single, contains('StateError: declined'));
      expect(out.single, contains('#0 app.dart:10'));
      expect(out.single, isNot(contains('#1 app.dart:20')));
      expect(out.single, contains('1 additional frames'));
      expect(out.single, contains('1 additional attributes'));
      expect(out.single, contains('11111111111111111111111111111111'));
    },
  );

  test('minimal and verbose are explicit detail policies', () async {
    final out = <String>[];
    final record = span(
      status: SpanStatus.error,
      events: [
        SpanEvent(
          name: 'exception',
          timestamp: DateTime.utc(2026),
          attributes: {
            'exception.stacktrace': '#0 app.dart:10\n#1 app.dart:20',
          },
        ),
      ],
    );
    await ConsoleSpanExporter.pretty(
      options: plain,
      writer: out.add,
      traceOptions: const PrettyTraceOptions(
        detail: TraceConsoleDetail.minimal,
        expandErrors: false,
      ),
    ).export([record]);
    expect(out.single.split('\n'), hasLength(1));
    out.clear();
    await ConsoleSpanExporter.pretty(
      options: plain,
      writer: out.add,
      traceOptions: const PrettyTraceOptions(
        detail: TraceConsoleDetail.verbose,
        maxStackFrames: 1,
      ),
    ).export([record]);
    expect(out.single, contains('#1 app.dart:20'));
  });

  test('JSON remains structurally unchanged', () async {
    final out = <String>[];
    await ConsoleSpanExporter(writer: out.add).export([span()]);
    expect((jsonDecode(out.single) as Map)['durationMicros'], 20000);
    expect(out.single, isNot(contains('LOCAL')));
  });

  test('tree groups across batches and sorts child after its parent', () async {
    final out = <String>[];
    final exporter = ConsoleSpanExporter.tree(
      options: plain,
      writer: out.add,
      traceOptions: const PrettyTraceOptions(groupWait: Duration(days: 1)),
    );
    await exporter.export([
      span(id: '2222222222222222', parent: '3333333333333333', name: 'child'),
    ]);
    await exporter.export([span(id: '3333333333333333', name: 'parent')]);
    expect(out, isEmpty);
    await exporter.forceFlush();
    expect(out, hasLength(1));
    expect(out.single, contains('LOCAL / PARTIAL'));
    expect(
      out.single.indexOf('SPAN parent'),
      lessThan(out.single.indexOf('SPAN child')),
    );
    expect(out.single, contains('2 local spans'));
    await exporter.shutdown();
    await exporter.shutdown();
    await expectLater(exporter.export([span()]), throwsStateError);
  });

  test(
    'fixed window emits without a root, and late groups remain partial',
    () async {
      final out = <String>[];
      final emitted = Completer<void>();
      final exporter = ConsoleSpanExporter.tree(
        options: plain,
        writer: (s) {
          out.add(s);
          if (!emitted.isCompleted) emitted.complete();
        },
        traceOptions: const PrettyTraceOptions(groupWait: Duration.zero),
      );
      await exporter.export([span(parent: '3333333333333333')]);
      await emitted.future.timeout(const Duration(seconds: 2));
      await exporter.export([span(id: '3333333333333333')]);
      await exporter.shutdown();
      expect(out, hasLength(2));
      expect(out.every((s) => s.contains('PARTIAL')), isTrue);
    },
  );

  test(
    'capacity drains old groups, shutdown drains rest, cycles terminate',
    () async {
      final out = <String>[];
      final exporter = ConsoleSpanExporter.tree(
        options: plain,
        writer: out.add,
        traceOptions: const PrettyTraceOptions(
          maxBufferedSpans: 1,
          groupWait: Duration(days: 1),
        ),
      );
      await exporter.export([
        span(),
        span(id: '3333333333333333', parent: '3333333333333333'),
      ]);
      expect(out, hasLength(1));
      await exporter.shutdown();
      expect(out, hasLength(2));
    },
  );

  test(
    'timer writer failures surface on flush without uncaught async errors',
    () async {
      final called = Completer<void>();
      final exporter = ConsoleSpanExporter.tree(
        options: plain,
        writer: (_) {
          called.complete();
          throw StateError('writer');
        },
        traceOptions: const PrettyTraceOptions(groupWait: Duration.zero),
      );
      await exporter.export([span()]);
      await called.future;
      await expectLater(exporter.forceFlush(), throwsStateError);
      await exporter.shutdown();
    },
  );

  test('flush drains all groups even when writer fails', () async {
    var calls = 0;
    final exporter = ConsoleSpanExporter.tree(
      writer: (_) {
        calls++;
        throw StateError('writer');
      },
      traceOptions: const PrettyTraceOptions(groupWait: Duration(days: 1)),
    );
    await exporter.export([
      span(),
      span(trace: '44444444444444444444444444444444'),
    ]);
    await expectLater(exporter.shutdown(), throwsStateError);
    expect(calls, 2);
    await exporter.shutdown();
  });
}

SpanData span({
  String id = '2222222222222222',
  String? parent,
  String trace = '11111111111111111111111111111111',
  String name = 'operation',
  int ms = 20,
  SpanStatus status = SpanStatus.unset,
  Map<String, Object?> attributes = const {},
  List<SpanEvent> events = const [],
}) => SpanData(
  name: name,
  context: SpanContext(traceId: trace, spanId: id, sampled: true),
  parentSpanId: parent,
  kind: SpanKind.internal,
  startTime: DateTime.utc(2026),
  endTime: DateTime.utc(2026).add(Duration(milliseconds: ms)),
  status: status,
  statusDescription: null,
  resource: Resource.empty,
  instrumentationScope: InstrumentationScope('test'),
  attributes: attributes,
  events: events,
  links: const [],
);
