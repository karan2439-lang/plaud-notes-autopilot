#!/bin/bash
set -euo pipefail

TEST_DIR=$(mktemp -d)
FAKE_BIN=$(mktemp -d)
cleanup() {
  rm -rf "$TEST_DIR" "$FAKE_BIN"
}
trap cleanup EXIT

REPO_DIR="$TEST_DIR/repo"
mkdir -p "$REPO_DIR/scripts" "$REPO_DIR/deploy"

REAL_SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cp "$REAL_SCRIPT_DIR/install.sh" "$REPO_DIR/scripts/"
cp "$REAL_SCRIPT_DIR/uninstall.sh" "$REPO_DIR/scripts/"
cp "$REAL_SCRIPT_DIR/../deploy/launchd.plist.template" "$REPO_DIR/deploy/"
cp "$REAL_SCRIPT_DIR/../config.example.json" "$REPO_DIR/config.example.json"

# Create fake launchctl and fake jq
cat > "$FAKE_BIN/launchctl" <<'EOF'
#!/bin/bash
echo "launchctl $*" >> "$LAUNCHCTL_LOG"
exit 0
EOF
chmod +x "$FAKE_BIN/launchctl"

JQ_BIN=$(command -v jq)
cat > "$FAKE_BIN/jq" <<EOF
#!/bin/bash
exec "$JQ_BIN" "\$@"
EOF
chmod +x "$FAKE_BIN/jq"

export HOME="$TEST_DIR/home"
export LAUNCHCTL_LOG="$TEST_DIR/launchctl.log"
mkdir -p "$HOME"

# Test 1: install fails if config.json is missing
set +e
MISSING_OUT=$(PATH="$FAKE_BIN:$PATH" bash "$REPO_DIR/scripts/install.sh" 2>&1)
MISSING_EXIT=$?
set -e
if [ "$MISSING_EXIT" -ne 0 ] && [[ "$MISSING_OUT" == *"config.json"* ]]; then
  echo "PASS: install.sh fails cleanly when config.json is missing"
else
  echo "FAIL: install.sh did not fail cleanly without config.json"
  exit 1
fi

# Create custom config.json
cat > "$REPO_DIR/config.json" <<'EOF'
{
  "notes_dir": "~/Documents/PlaudNotes",
  "schedule": [
    { "hour": 9, "minute": 15 },
    { "hour": 18, "minute": 30 }
  ]
}
EOF

# Test 2: install succeeds with config.json
PATH="$FAKE_BIN:$PATH" bash "$REPO_DIR/scripts/install.sh"

TARGET_PLIST="$HOME/Library/LaunchAgents/com.github.plaud-notes-autopilot.plist"
[ -f "$TARGET_PLIST" ] || { echo "FAIL: target plist was not created"; exit 1; }

# Verify plist contents
grep -q "$REPO_DIR" "$TARGET_PLIST" || { echo "FAIL: plist does not contain repo path"; exit 1; }
grep -q "<integer>9</integer>" "$TARGET_PLIST" || { echo "FAIL: plist does not contain scheduled hour 9"; exit 1; }
grep -q "<integer>18</integer>" "$TARGET_PLIST" || { echo "FAIL: plist does not contain scheduled hour 18"; exit 1; }
grep -q "com.github.plaud-notes-autopilot" "$TARGET_PLIST" || { echo "FAIL: plist label mismatch"; exit 1; }
grep -q "launchctl bootstrap" "$LAUNCHCTL_LOG" || { echo "FAIL: launchctl bootstrap was not called"; exit 1; }
echo "PASS: install.sh creates plist with schedule and bootstraps service"

# Test 3: uninstall succeeds
PATH="$FAKE_BIN:$PATH" bash "$REPO_DIR/scripts/uninstall.sh"
[ ! -f "$TARGET_PLIST" ] || { echo "FAIL: plist was not removed by uninstall.sh"; exit 1; }
grep -q "launchctl bootout" "$LAUNCHCTL_LOG" || { echo "FAIL: launchctl bootout was not called"; exit 1; }
echo "PASS: uninstall.sh boots out and removes plist"

echo "All install and uninstall tests passed."
