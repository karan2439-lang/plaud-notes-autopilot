#!/bin/bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG_FILE="$PROJECT_DIR/config.json"
TEMPLATE_FILE="$PROJECT_DIR/deploy/launchd.plist.template"
LABEL="com.github.plaud-notes-autopilot"
LAUNCH_AGENTS_DIR="${HOME}/Library/LaunchAgents"
TARGET_PLIST="${LAUNCH_AGENTS_DIR}/${LABEL}.plist"

if [ ! -f "$CONFIG_FILE" ]; then
  echo "Error: config.json not found in $PROJECT_DIR." >&2
  echo "Copy config.example.json to config.json and configure it before installing." >&2
  exit 1
fi

if [ ! -f "$TEMPLATE_FILE" ]; then
  echo "Error: Template file $TEMPLATE_FILE not found." >&2
  exit 1
fi

mkdir -p "$LAUNCH_AGENTS_DIR" "$PROJECT_DIR/logs"

# Generate StartCalendarInterval XML from config.json
SCHEDULE_XML=$(jq -r '.schedule // [{"hour": 10, "minute": 0}, {"hour": 20, "minute": 0}] | 
  ["  <array>"] + 
  map("    <dict>\n      <key>Hour</key>\n      <integer>\(.hour)</integer>\n      <key>Minute</key>\n      <integer>\(.minute)</integer>\n    </dict>") + 
  ["  </array>"] | join("\n")' "$CONFIG_FILE")

# Prepare PATH for launchd environment
ENV_PATH="${HOME}/.local/bin:${HOME}/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
if [ -n "${PATH:-}" ]; then
  ENV_PATH="${PATH}:${ENV_PATH}"
fi

while IFS= read -r line || [ -n "$line" ]; do
  if [[ "$line" == *"__START_CALENDAR_INTERVAL__"* ]]; then
    printf '%s\n' "$SCHEDULE_XML"
  else
    line="${line//__PROJECT_DIR__/$PROJECT_DIR}"
    line="${line//__ENV_PATH__/$ENV_PATH}"
    printf '%s\n' "$line"
  fi
done < "$TEMPLATE_FILE" > "$TARGET_PLIST"

# Bootout if already loaded, then bootstrap
DOMAIN_TARGET="gui/$(id -u)"
launchctl bootout "$DOMAIN_TARGET/$LABEL" 2>/dev/null || true
launchctl bootstrap "$DOMAIN_TARGET" "$TARGET_PLIST"

echo "Installed and loaded $LABEL successfully into $DOMAIN_TARGET."
