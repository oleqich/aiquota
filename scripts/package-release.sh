#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
"$ROOT/scripts/build.sh"

ZIP="$ROOT/dist/AIQuota-macos.zip"
rm -f "$ZIP"
COPYFILE_DISABLE=1 ditto -c -k --norsrc --keepParent "$ROOT/dist/AIQuota.app" "$ZIP"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
ditto -x -k "$ZIP" "$TMP"
codesign --verify --strict --verbose=2 "$TMP/AIQuota.app"
lipo -info "$TMP/AIQuota.app/Contents/MacOS/AIQuota"
vtool -show-build "$TMP/AIQuota.app/Contents/MacOS/AIQuota" | awk '/minos|platform/'

echo "zip: $ZIP"
shasum -a 256 "$ZIP"
