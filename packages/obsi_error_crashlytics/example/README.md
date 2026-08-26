# Crashlytics integration host

This app validates that `obsi_error_crashlytics` compiles, registers, and runs
on Android and iOS without sending telemetry to Firebase. The integration test
uses the package's injectable `CrashlyticsClient` boundary.

```sh
flutter test integration_test/crashlytics_integration_test.dart -d <device>
```

To verify delivery to a real Firebase project, run `flutterfire configure`,
initialize Firebase, use `FirebaseCrashlyticsClient`, and follow Firebase's
deliberate test-crash procedure. Never use production user data for that test.
