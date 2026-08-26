import 'package:flutter/material.dart';

/// Performs main.
void main() => runApp(const ObsiCrashlyticsExample());

/// Represents obsi crashlytics example.
final class ObsiCrashlyticsExample extends StatelessWidget {
  /// Creates a instance.
  const ObsiCrashlyticsExample({super.key});

  /// Performs build.
  @override
  Widget build(BuildContext context) => const MaterialApp(
    home: Scaffold(body: Center(child: Text('Obsi Crashlytics integration'))),
  );
}
