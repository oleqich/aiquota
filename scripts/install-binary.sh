#!/usr/bin/env bash
# Install the prebuilt macOS app from the latest GitHub release.
# No Xcode. Overrides: AIQUOTA_ZIP_URL, AIQUOTA_SKIP_LAUNCH=1.
set -euo pipefail

if [ "$(uname -s)" != "Darwin" ]; then
  echo "AIQuota is a macOS menu bar app." >&2
  exit 1
fi

REPO="oleqich/aiquota"
ASSET="AIQuota-macos.zip"
LABEL="app.aiquota"
DEST="$HOME/Applications/AIQuota.app"
AGENT="$HOME/Library/LaunchAgents/$LABEL.plist"
ZIP_URL="${AIQUOTA_ZIP_URL:-https://github.com/${REPO}/releases/latest/download/${ASSET}}"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "downloading ${ZIP_URL}"
curl -fsSL --retry 3 --retry-delay 2 -o "$TMP/$ASSET" "$ZIP_URL"
ditto -x -k "$TMP/$ASSET" "$TMP"
# unzip/GitHub can add AppleDouble files; they break the sealed signature.
find "$TMP" -name '._*' -delete
find "$TMP" -name '.DS_Store' -delete

APP="$TMP/AIQuota.app"
if [ ! -d "$APP" ]; then
  echo "archive does not contain AIQuota.app" >&2
  exit 1
fi

# GitHub downloads are quarantined. An ad-hoc signature then looks "damaged".
xattr -cr "$APP"
mkdir -p "$HOME/Applications"
rm -rf "$DEST"
cp -R "$APP" "$DEST"
xattr -cr "$DEST"
codesign --force --sign - "$DEST" >/dev/null

if [ "${AIQUOTA_SKIP_LAUNCH:-0}" = "1" ]; then
  echo "installed: $DEST"
  echo "launch skipped"
  exit 0
fi

cat > "$AGENT" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key>
  <array><string>$DEST/Contents/MacOS/AIQuota</string></array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key>
  <dict><key>SuccessfulExit</key><false/></dict>
  <key>ThrottleInterval</key><integer>10</integer>
  <key>ProcessType</key><string>Interactive</string>
  <key>StandardOutPath</key><string>$HOME/Library/Logs/AIQuota.out.log</string>
  <key>StandardErrorPath</key><string>$HOME/Library/Logs/AIQuota.err.log</string>
</dict>
</plist>
PLIST

launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$AGENT"

echo "installed: $DEST"
echo "click the menu bar icon -> Keys... to add your credentials"
