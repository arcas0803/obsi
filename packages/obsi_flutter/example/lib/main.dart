import 'dart:async';

import 'package:flutter/material.dart';
import 'package:obsi/obsi.dart';
import 'package:obsi_flutter/obsi_flutter.dart';

/// Configures every Obsi signal before installing Flutter's global handlers.
void main() {
  WidgetsFlutterBinding.ensureInitialized();
  final resource = Resource({
    'service.name': 'obsi-flutter-example',
    'service.version': '1.0.0',
    'deployment.environment.name': 'development',
  });
  final provider = ObsiProvider(
    traces: TracerProvider(
      resource: resource,
      processor: BatchSpanProcessor(const ConsoleSpanExporter()),
      attributeRedactor: SensitiveAttributeRedactor().call,
    ),
    logs: LoggerProvider(
      resource: resource,
      processor: BatchLogProcessor(const ConsoleLogExporter()),
      attributeRedactor: SensitiveAttributeRedactor().call,
    ),
    metrics: MeterProvider(
      resource: resource,
      readers: [
        PeriodicMetricReader(
          const ConsoleMetricExporter(),
          interval: const Duration(seconds: 30),
        ),
      ],
      attributeRedactor: SensitiveAttributeRedactor().call,
    ),
    errors: ErrorManager(
      resource: resource,
      exporter: const ConsoleErrorExporter(),
    ),
  );
  Obsi.configure(provider);
  final errorIntegration = ObsiFlutterErrorIntegration()..install();
  final observer = ObsiNavigatorObserver(
    tracer: Obsi.tracer,
    logger: Obsi.logger('example.navigation'),
    meter: Obsi.meter('example.navigation'),
    navigatorName: 'root',
  );

  runApp(
    ObsiLifecycle(
      provider: provider,
      errorIntegration: errorIntegration,
      child: ObsiNavigationExample(observer: observer),
    ),
  );
}

/// Owns Flutter handlers and drains Obsi when the application detaches.
final class ObsiLifecycle extends StatefulWidget {
  /// Creates a lifecycle boundary for a configured [provider].
  const ObsiLifecycle({
    required this.provider,
    required this.errorIntegration,
    required this.child,
    super.key,
  });

  /// Provider owned by this application root.
  final ObsiProvider provider;

  /// Global Flutter error-handler installation owned by this application root.
  final ObsiFlutterErrorIntegration errorIntegration;

  /// Application rendered below the lifecycle boundary.
  final Widget child;

  @override
  State<ObsiLifecycle> createState() => _ObsiLifecycleState();
}

final class _ObsiLifecycleState extends State<ObsiLifecycle>
    with WidgetsBindingObserver {
  bool _shutdownStarted = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.detached) unawaited(_shutdown());
  }

  Future<void> _shutdown() async {
    if (_shutdownStarted) return;
    _shutdownStarted = true;
    if (widget.errorIntegration.isInstalled) {
      widget.errorIntegration.uninstall();
    }
    Obsi.disable();
    await widget.provider.shutdown();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    unawaited(_shutdown());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

/// Demonstrates navigation telemetry with named, low-cardinality routes.
final class ObsiNavigationExample extends StatelessWidget {
  /// Creates the example with an optional observer for testing.
  ObsiNavigationExample({super.key, ObsiNavigatorObserver? observer})
    : observer = observer ?? ObsiNavigatorObserver();

  /// Observer installed on the root navigator.
  final ObsiNavigatorObserver observer;

  /// Builds the two-screen navigation example.
  @override
  Widget build(BuildContext context) => MaterialApp(
    navigatorObservers: [observer],
    initialRoute: '/',
    routes: {
      '/': (context) => Scaffold(
        appBar: AppBar(title: const Text('Obsi navigation')),
        body: Center(
          child: FilledButton(
            key: const ValueKey('open-details'),
            onPressed: () => Navigator.of(context).pushNamed('/details'),
            child: const Text('Open details'),
          ),
        ),
      ),
      '/details': (context) => Scaffold(
        appBar: AppBar(title: const Text('Details')),
        body: Center(
          child: FilledButton(
            key: const ValueKey('go-back'),
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Go back'),
          ),
        ),
      ),
    },
  );
}
