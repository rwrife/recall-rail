#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

forbidden_paths=(
  pubspec.yaml
  android
  node_modules
  package.json
  Podfile
)

for path in "${forbidden_paths[@]}"; do
  if [[ -e "$path" ]]; then
    echo "Native-only gate: FAIL (forbidden hybrid/cross-platform path: $path)" >&2
    exit 1
  fi
done

if grep -RniE --exclude-dir=.git --exclude-dir=.build \
  --exclude='PLAN.md' --exclude='README.md' \
  --exclude='check_native_only.sh' \
  '(Flutter|React Native|Expo|Kotlin Multiplatform|\.NET MAUI|Unity)' \
  RecallRail RecallRailTests Packages RecallRail.xcodeproj scripts .github 2>/dev/null; then
  echo "Native-only gate: FAIL (cross-platform framework reference found)" >&2
  exit 1
fi

echo "Native-only gate: PASS (native Swift project only)"
