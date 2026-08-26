#!/usr/bin/env bash
set -euo pipefail

packages=(
  obsi
  obsi_exporter_otlp
  obsi_error_sentry
  obsi_error_crashlytics
  obsi_flutter
  obsi_instrumentation_dio
  obsi_instrumentation_http
  obsi_instrumentation_shelf
)

for package in "${packages[@]}"; do
  echo "Collecting coverage for $package"
  (
    cd "packages/$package"
    flutter test --coverage
  )

  case "$package" in
    obsi) minimum=85 ;;
    obsi_error_crashlytics) minimum=77 ;;
    obsi_error_sentry) minimum=96 ;;
    obsi_exporter_otlp) minimum=90 ;;
    obsi_flutter) minimum=93 ;;
    obsi_instrumentation_dio) minimum=90 ;;
    obsi_instrumentation_http) minimum=87 ;;
    obsi_instrumentation_shelf) minimum=91 ;;
  esac

  awk -F: -v package="$package" -v minimum="$minimum" '
    /^LF:/ {found += $2}
    /^LH:/ {hit += $2}
    END {
      coverage = found == 0 ? 0 : (100 * hit / found)
      printf "%s coverage: %.1f%% (minimum %d%%)\n", package, coverage, minimum
      if (coverage < minimum) exit 1
    }
  ' "packages/$package/coverage/lcov.info"
done
