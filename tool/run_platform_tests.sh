#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 2 ]]; then
  echo "Usage: $0 <android-device-id> <ios-device-id>" >&2
  exit 64
fi

android_device=$1
ios_device=$2

run_suite() {
  local package=$1
  local device=$2
  echo "Running $package integration tests on $device"
  (
    cd "packages/$package/example"
    flutter test integration_test -d "$device"
  )
}

run_suite obsi_flutter "$android_device"
run_suite obsi_error_crashlytics "$android_device"
run_suite obsi_flutter "$ios_device"
run_suite obsi_error_crashlytics "$ios_device"
