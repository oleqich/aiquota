#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="$ROOT/dist/AIQuota.app"
TARGET_OS="${MACOSX_DEPLOYMENT_TARGET:-13.0}"

rm -rf "$OUT"
mkdir -p "$OUT/Contents/MacOS" "$OUT/Contents/Resources"
cp "$ROOT/Resources/Info.plist" "$OUT/Contents/Info.plist"
cp "$ROOT/Resources/"*.svg "$OUT/Contents/Resources/"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

compile() {
  local arch="$1"
  swiftc -O \
    -target "${arch}-apple-macosx${TARGET_OS}" \
    -o "$TMP/AIQuota-${arch}" \
    "$ROOT/Sources/AIQuota.swift" \
    -framework Cocoa
}

compile arm64
compile x86_64
lipo -create -output "$OUT/Contents/MacOS/AIQuota" \
  "$TMP/AIQuota-arm64" "$TMP/AIQuota-x86_64"
codesign --force --sign - "$OUT" >/dev/null

MINOS="$(vtool -show-build "$OUT/Contents/MacOS/AIQuota" | awk '/minos/{print $2; exit}')"
if [ "$MINOS" != "$TARGET_OS" ]; then
  echo "unexpected minos: ${MINOS:-missing} (wanted ${TARGET_OS})" >&2
  exit 1
fi

echo "built: $OUT"
lipo -info "$OUT/Contents/MacOS/AIQuota"
echo "minos: $MINOS"
if [ "${1:-}" = "--run" ]; then
  open "$OUT"
fi
