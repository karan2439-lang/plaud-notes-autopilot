#!/bin/bash
set -euo pipefail

LABEL="com.github.plaud-notes-autopilot"
LAUNCH_AGENTS_DIR="${HOME}/Library/LaunchAgents"
TARGET_PLIST="${LAUNCH_AGENTS_DIR}/${LABEL}.plist"
DOMAIN_TARGET="gui/$(id -u)"

if launchctl print "$DOMAIN_TARGET/$LABEL" >/dev/null 2>&1; then
  launchctl bootout "$DOMAIN_TARGET/$LABEL" 2>/dev/null || true
fi

if [ -f "$TARGET_PLIST" ]; then
  rm -f "$TARGET_PLIST"
  echo "Removed $TARGET_PLIST."
else
  echo "No plist found at $TARGET_PLIST."
fi

echo "Uninstalled $LABEL successfully."
