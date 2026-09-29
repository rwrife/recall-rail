#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

roots=("RecallRail" "Packages")
patterns=(
  '\bURLSession\b'
  '\bNSURLSession\b'
  '\bNWConnection\b'
  '\bNWListener\b'
  '\bNWBrowser\b'
  '\bNetService\b'
  '\bCFNetwork\b'
  '\bimport[[:space:]]+Network\b'
  '\bWebSocket\b'
  '\bgetaddrinfo\b'
  '\bsocket[[:space:]]*\('
  '\bconnect[[:space:]]*\('
)

matches=""
for root in "${roots[@]}"; do
  [[ -d "$root" ]] || continue
  for pattern in "${patterns[@]}"; do
    hits=$(grep -RnE --include='*.swift' --include='*.h' --include='*.m' --include='*.c' \
      --exclude-dir=.build "$pattern" "$root" 2>/dev/null || true)
    [[ -z "$hits" ]] || matches+="$hits"$'\n'
  done
done

if [[ -n "$matches" ]]; then
  echo "Zero-network gate: FAIL (network API usage found; allowlist is empty)" >&2
  printf '%s' "$matches" >&2
  exit 1
fi

echo "Zero-network gate: PASS (empty allowlist; no network API usage found)"
