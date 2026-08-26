# Contributing to Obsi

Use the stable Flutter SDK and run `flutter pub get` at the repository root.
Before opening a pull request, run:

```sh
dart format --output=none --set-exit-if-changed .
flutter analyze --fatal-infos
bash tool/run_coverage.sh
```

Keep the `obsi` core free of Flutter and integration dependencies. Public API
changes require tests, documentation and a changelog entry. Avoid recording
credentials, URL query values or high-cardinality identifiers in telemetry.

Packages are released independently with `<package>-v<version>` tags. Do not
reuse or move a published tag.
