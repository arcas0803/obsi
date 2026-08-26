#!/usr/bin/env bash

set -euo pipefail

workspace_root=$(cd "$(dirname "$0")/.." && pwd)
flutter_root=$(cd "$(dirname "$(command -v flutter)")/.." && pwd)
export FLUTTER_ROOT="$flutter_root"

for package in "$workspace_root"/packages/*; do
  if [[ ! -f "$package/pubspec.yaml" ]]; then
    continue
  fi

  package_name=$(basename "$package")
  echo "Validating dartdoc for $package_name"
  output=$(cd "$package" && dart doc --validate-links 2>&1)
  echo "$output"

  if grep -Eiq '(^|[[:space:]])warning:|Found [1-9][0-9]* warning' <<<"$output"; then
    echo "dartdoc warnings found in $package_name" >&2
    exit 1
  fi
done
