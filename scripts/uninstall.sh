#!/usr/bin/env bash
set -euo pipefail

LABEL="app.aiquota"
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
rm -f "$HOME/Library/LaunchAgents/$LABEL.plist"
rm -rf "$HOME/Applications/AIQuota.app"
rm -rf "$HOME/Library/Application Support/AIQuota"
rm -f "$HOME/Library/Logs/AIQuota.log" "$HOME/Library/Logs/AIQuota.log.1" \
      "$HOME/Library/Logs/AIQuota.out.log" "$HOME/Library/Logs/AIQuota.err.log"

echo "removed AIQuota (Keychain items aiquota-* are kept)"
