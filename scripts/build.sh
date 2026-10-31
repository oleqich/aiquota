#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="$ROOT/dist/AIQuota.app"

rm -rf "$OUT"
mkdir -p "$OUT/Contents/MacOS" "$OUT/Contents/Resources"
cp "$ROOT/Resources/Info.plist" "$OUT/Contents/Info.plist"
cp "$ROOT/Resources/"*.svg "$OUT/Contents/Resources/"

swiftc -O -o "$OUT/Contents/MacOS/AIQuota" "$ROOT/Sources/AIQuota.swift" -framework Cocoa
codesign --force --sign - "$OUT" >/dev/null 2>&1 || true

echo "built: $OUT"
if [ "${1:-}" = "--run" ]; then
  open "$OUT"
fi
