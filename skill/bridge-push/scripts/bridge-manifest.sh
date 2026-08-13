#!/usr/bin/env bash
# bridge-manifest.sh <dir> — deterministic fingerprint of a directory's contents,
# comparable across macOS and Linux. Both ends run this to prove a transfer
# arrived intact: same FILES/BYTES/SHA on both hosts == byte-identical tree.
# .git is ignored so it doesn't have to be transferred to match.
set -uo pipefail
D="${1:?usage: bridge-manifest.sh <dir_or_file>}"

sha() { if command -v sha256sum >/dev/null 2>&1; then sha256sum; else shasum -a 256; fi; }

if [ -f "$D" ]; then
  sz=$(wc -c < "$D" | tr -d ' '); h=$(sha < "$D" | awk '{print $1}')
  echo "FILES=1 BYTES=$sz SHA=$h"; exit 0
fi
cd "$D" 2>/dev/null || { echo "MANIFEST_ERROR: no such dir: $D"; exit 1; }

lines=$(find . -type f ! -path './.git/*' | LC_ALL=C sort | while IFS= read -r f; do
  sz=$(wc -c < "$f" | tr -d ' ')
  h=$(sha < "$f" | awk '{print $1}')
  printf '%s\t%s\t%s\n' "$f" "$sz" "$h"
done)
files=$(printf '%s' "$lines" | grep -c . || true)
bytes=$(printf '%s\n' "$lines" | awk -F'\t' '{s+=$2} END{printf "%d", s+0}')
combined=$(printf '%s' "$lines" | sha | awk '{print $1}')
echo "FILES=$files BYTES=$bytes SHA=$combined"
