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

# Word boundaries are required: the case-insensitive gate must not fire on
# ordinary English/library substrings. Without \b, "export"/"fileExporter"
# matched "Expo" and "community" would match "Unity", poisoning the gate
# against this app's own CSV save/restore vocabulary. Framework references
# (a standalone word) are still caught — covered by scripts/test_native_gate.sh.
if grep -RniE --exclude-dir=.git --exclude-dir=.build \
  --exclude='PLAN.md' --exclude='README.md' \
  --exclude='check_native_only.sh' \
  --exclude='test_native_gate.sh' \
  '(\bFlutter\b|React Native|\bExpo\b|Kotlin Multiplatform|\.NET MAUI|\bUnity\b)' \
  RecallRail RecallRailTests Packages RecallRail.xcodeproj scripts .github 2>/dev/null; then
  echo "Native-only gate: FAIL (cross-platform framework reference found)" >&2
  exit 1
fi

# Prove the gate's own boundary rules before trusting its PASS.
bash scripts/test_native_gate.sh

echo "Native-only gate: PASS (native Swift project only)"
