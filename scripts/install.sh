#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LABEL="app.aiquota"
DEST="$HOME/Applications/AIQuota.app"
AGENT="$HOME/Library/LaunchAgents/$LABEL.plist"

"$ROOT/scripts/build.sh"

mkdir -p "$HOME/Applications"
rm -rf "$DEST"
cp -R "$ROOT/dist/AIQuota.app" "$DEST"

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
