import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:obsi/obsi.dart';
import 'package:obsi_flutter/obsi_flutter.dart';

import 'package:obsi_flutter_example/main.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('captures a real Navigator push and pop on device', (
    tester,
  ) async {
    final exporter = _MemorySpanExporter();
    final provider = TracerProvider(processor: SimpleSpanProcessor(exporter));
    final observer = ObsiNavigatorObserver(tracer: provider.tracer);

    await ErrorScope().run(() async {
      await tester.pumpWidget(ObsiNavigationExample(observer: observer));
      expect(find.text('Obsi navigation'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('open-details')));
      await tester.pumpAndSettle();
      expect(find.text('Details'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('go-back')));
      await tester.pumpAndSettle();
      expect(find.text('Obsi navigation'), findsOneWidget);
      expect(
        Errors.currentScope.breadcrumbs.map((item) => item.message),
        containsAll(<String>['push /details', 'pop /']),
      );
    });
    await provider.shutdown();

    expect(
      exporter.spans.map((span) => span.attributes['navigation.operation']),
      containsAllInOrder(<String>['push', 'push', 'pop']),
    );
    expect(
      exporter.spans.map((span) => span.attributes['app.screen.name']),
      contains('/details'),
    );
  });
}

final class _MemorySpanExporter implements SpanExporter {
  final List<SpanData> spans = [];

  @override
  Future<void> export(List<SpanData> batch) async => spans.addAll(batch);

  @override
  Future<void> shutdown() async {}
}
