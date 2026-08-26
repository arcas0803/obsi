import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:obsi_error_crashlytics/obsi_error_crashlytics.dart';
import 'package:obsi/obsi.dart';

import 'package:obsi_crashlytics_example/main.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'loads the plugin and exports through the platform-safe boundary',
    (tester) async {
      await tester.pumpWidget(const ObsiCrashlyticsExample());
      expect(find.text('Obsi Crashlytics integration'), findsOneWidget);

      final client = _DeviceCrashlyticsClient();
      final exporter = CrashlyticsErrorExporter(client: client);
      await exporter.export(_report());
      await exporter.shutdown();

      expect(client.recordedErrors, 1);
      expect(client.customKeys['obsi.integration'], 'obsi_error_crashlytics');
      expect(client.userIdentifier, 'device-user');
      expect(exporter.exportedReports, 1);
    },
  );
}

ErrorReport _report() => ErrorReport(
  id: const ErrorId('device-error'),
  timestamp: DateTime.utc(2026),
  exception: StateError('device integration'),
  message: 'Bad state: device integration',
  stackTrace: StackTrace.current,
  severity: ErrorSeverity.error,
  fatal: false,
  handled: true,
  mechanism: ErrorMechanism.manual,
  attributes: const {'test.platform': 'flutter'},
  tags: const {'test.kind': 'integration'},
  contexts: const {},
  fingerprint: const [],
  breadcrumbs: const [],
  attachments: const [],
  user: ErrorUser(id: 'device-user'),
  resource: Resource(const {'service.name': 'obsi-device-test'}),
  instrumentationScope: InstrumentationScope('obsi.device.test'),
);

final class _DeviceCrashlyticsClient implements CrashlyticsClient {
  final Map<String, Object> customKeys = {};
  int recordedErrors = 0;
  String? userIdentifier;

  @override
  Future<void> log(String message) async {}

  @override
  Future<void> recordError(
    Object exception,
    StackTrace? stackTrace, {
    Object? reason,
    Iterable<Object> information = const [],
    bool fatal = false,
  }) async {
    recordedErrors++;
  }

  @override
  Future<void> sendUnsentReports() async {}

  @override
  Future<void> setCustomKey(String key, Object value) async {
    customKeys[key] = value;
  }

  @override
  Future<void> setUserIdentifier(String identifier) async {
    userIdentifier = identifier;
  }
}
