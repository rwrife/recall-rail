#!/usr/bin/env bash
# Self-test for the native-only gate's word-boundary matching.
# Guards against reintroducing a substring pattern where legitimate
# save/restore vocabulary (export, fileExporter, community) trips the gate,
# and against a boundary so loose that framework references slip through.
set -euo pipefail

cd "$(dirname "$0")/.."
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

pattern='(\bFlutter\b|React Native|\bExpo\b|Kotlin Multiplatform|\.NET MAUI|\bUnity\b)'

should_not_match=(
  'fileExporter saves the CSV document'
  '/// Round-trip through CSV export is update-safe'
  'a tight-knit study community'
  'the exporters reimport updated rows'
)
should_match=(
  'import Expo from "expo"'
  'this app uses Flutter widgets'
  'written in React Native'
  'Kotlin Multiplatform shared layer'
  'migrated from .NET MAUI'
  'Unity scene assets'
)

fail=0
for text in "${should_not_match[@]}"; do
  if printf '%s\n' "$text" | grep -qiE "$pattern"; then
    echo "gate self-test FAIL: false positive on: $text" >&2
    fail=1
  fi
done
for text in "${should_match[@]}"; do
  if ! printf '%s\n' "$text" | grep -qiE "$pattern"; then
    echo "gate self-test FAIL: missed framework reference in: $text" >&2
    fail=1
  fi
done
[[ $fail -eq 0 ]] && echo "gate self-test: PASS"
exit $fail
