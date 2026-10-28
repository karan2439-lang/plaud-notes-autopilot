#!/bin/bash
set -euo pipefail

REAL_SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TEST_ROOT=$(mktemp -d)
FAKE_BIN=$(mktemp -d)

cleanup() {
  rm -rf "$TEST_ROOT" "$FAKE_BIN"
}
trap cleanup EXIT

mkdir -p "$TEST_ROOT/scripts/lib" "$TEST_ROOT/logs" "$TEST_ROOT/state" "$TEST_ROOT/notes"
cp "$REAL_SCRIPT_DIR/run_plaud_pipeline.sh" "$TEST_ROOT/scripts/"
cp "$REAL_SCRIPT_DIR/lib/new_recordings.sh" "$TEST_ROOT/scripts/lib/"
cp -r "$REAL_SCRIPT_DIR/../pipeline" "$TEST_ROOT/"

fail() {
  echo "FAIL: $1"
  exit 1
}

JQ_BIN=$(command -v jq)
cat > "$FAKE_BIN/jq" <<EOF
#!/bin/bash
exec "$JQ_BIN" "\$@"
EOF
chmod +x "$FAKE_BIN/jq"

export OSASCRIPT_LOG="$TEST_ROOT/osascript.log"
cat > "$FAKE_BIN/osascript" <<'EOF'
#!/bin/bash
if [ -n "${OSASCRIPT_LOG:-}" ]; then
  printf 'OSASCRIPT_CALL' >> "$OSASCRIPT_LOG"
  for arg in "$@"; do
    printf ' |ARG|%s' "$arg" >> "$OSASCRIPT_LOG"
  done
  printf '\n' >> "$OSASCRIPT_LOG"
fi

if [ -n "${OSASCRIPT_FAIL:-}" ]; then
  exit 1
fi
exit 0
EOF
chmod +x "$FAKE_BIN/osascript"

export CURL_LOG="$TEST_ROOT/curl.log"
export CURL_DATA_FILE="$TEST_ROOT/curl_data.json"
cat > "$FAKE_BIN/curl" <<'EOF'
#!/bin/bash
if [ -n "${CURL_LOG:-}" ]; then
  printf 'CURL_CALL' >> "$CURL_LOG"
  for arg in "$@"; do
    printf ' |ARG|%s' "$arg" >> "$CURL_LOG"
  done
  printf '\n' >> "$CURL_LOG"
fi

# Capture -d data
data_next=0
for a in "$@"; do
  if [ "$data_next" -eq 1 ]; then
    if [ -n "${CURL_DATA_FILE:-}" ]; then
      printf '%s\n' "$a" >> "$CURL_DATA_FILE"
    fi
    data_next=0
  elif [ "$a" = "-d" ] || [ "$a" = "--data" ]; then
    data_next=1
  elif [[ "$a" == -d* ]]; then
    val="${a#-d}"
    if [ -n "${CURL_DATA_FILE:-}" ]; then
      printf '%s\n' "$val" >> "$CURL_DATA_FILE"
    fi
  fi
done

if [ -n "${CURL_FAIL:-}" ]; then
  exit 1
fi

# Return empty search results by default so create page proceeds
echo '{"results":[],"id":"page_123"}'
exit 0
EOF
chmod +x "$FAKE_BIN/curl"

export CLAUDE_LOG="$TEST_ROOT/claude.log"
export CLAUDE_HANDLER="$TEST_ROOT/claude_handler.sh"

cat > "$FAKE_BIN/claude" <<'EOF'
#!/bin/bash
if [ -n "${CLAUDE_LOG:-}" ]; then
  printf 'CLAUDE_CALL' >> "$CLAUDE_LOG"
  for a in "$@"; do
    printf ' |ARG|%s' "$a" >> "$CLAUDE_LOG"
  done
  printf '\n' >> "$CLAUDE_LOG"
fi

if [ -f "$CLAUDE_HANDLER" ]; then
  exec bash "$CLAUDE_HANDLER" "$@"
fi

[ -n "${CLAUDE_INVOKED_MARKER:-}" ] && touch "$CLAUDE_INVOKED_MARKER"

cat <<'JEOF'
{
  "structured_output": {
    "topic": "acme-corp",
    "title": "Strategic Roadmap",
    "summary": "Met with Acme Corp team about roadmap planning and delivery milestones.",
    "key_points": [
      "Agreed on Q4 architecture milestones",
      "Confirmed deployment target dates"
    ],
    "action_items": [
      {
        "text": "Send updated slide deck",
        "due_date": "2026-08-10"
      },
      {
        "text": "Schedule follow-up review",
        "due_date": null
      }
    ]
  },
  "total_cost_usd": 0.0250,
  "is_error": false
}
JEOF
EOF
chmod +x "$FAKE_BIN/claude"

# ==============================================================================
# Scenario 1: Missing config.json exits with clear error
# ==============================================================================
rm -f "$TEST_ROOT/config.json"
set +e
MISSING_OUT=$(PATH="$FAKE_BIN:$PATH" bash "$TEST_ROOT/scripts/run_plaud_pipeline.sh" 2>&1)
MISSING_EXIT=$?
set -e

if [ "$MISSING_EXIT" -ne 0 ] && [[ "$MISSING_OUT" == *"config.json"* ]]; then
  echo "PASS: missing config.json exits with clear error"
else
  fail "missing config.json should exit non-zero with config.json message, got code $MISSING_EXIT, output: $MISSING_OUT"
fi

# Now create default config.json for tests
cat > "$TEST_ROOT/config.json" <<EOF
{
  "notes_dir": "$TEST_ROOT/notes",
  "notion": { "enabled": false, "database_id": "" },
  "calendar": { "enabled": false, "calendar_name": "Calendar" },
  "reminders": { "enabled": true, "list_name": "Plaud Action Items" },
  "model": "claude-haiku-4-5",
  "max_budget_usd_per_run": 0.50,
  "max_attempts": 3,
  "lookback_days": 7
}
EOF

# ==============================================================================
# Scenario 2: Candidate with empty/header-only transcript never calls Claude and logs no-op
# ==============================================================================
export CLAUDE_INVOKED_MARKER="$TEST_ROOT/claude_was_invoked"
rm -f "$CLAUDE_INVOKED_MARKER"
echo '[]' > "$TEST_ROOT/state/processed_ids.json"
echo '{}' > "$TEST_ROOT/state/attempts.json"
echo -n "" > "$TEST_ROOT/logs/run.log"

cat > "$FAKE_BIN/plaud" <<'EOF'
#!/bin/bash
if [ "$1" = "recent" ]; then
  echo -e "\033[36mof_bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\033[39m  10-28 Meeting Title  2026-08-04  20s"
elif [ "$1" = "transcript" ]; then
  # Header lines only, empty body
  echo -e "- Fetching transcript...\n\nTranscript: 10-28 Meeting Title\n\n"
elif [ "$1" = "file" ]; then
  echo -e "File Details:\n  id: $2\n  created_at: 2026-08-04T10:00:00Z"
fi
EOF
chmod +x "$FAKE_BIN/plaud"

rm -f "$CLAUDE_HANDLER"

PATH="$FAKE_BIN:$PATH" bash "$TEST_ROOT/scripts/run_plaud_pipeline.sh"

[ ! -f "$CLAUDE_INVOKED_MARKER" ] || fail "claude was invoked even though candidate transcript was empty"
grep -q "no-op" "$TEST_ROOT/logs/run.log" || fail "run.log does not contain no-op when transcript was empty"
echo "PASS: empty transcript recording skips claude and logs no-op"

# ==============================================================================
# Scenario 3: Candidate with errored transcript never calls Claude and logs no-op
# ==============================================================================
rm -f "$CLAUDE_INVOKED_MARKER"
echo -n "" > "$TEST_ROOT/logs/run.log"

cat > "$FAKE_BIN/plaud" <<'EOF'
#!/bin/bash
if [ "$1" = "recent" ]; then
  echo -e "\033[36mof_cccccccccccccccccccccccccccccccc\033[39m  10-28 Meeting Title  2026-08-04  20s"
elif [ "$1" = "transcript" ]; then
  exit 1
elif [ "$1" = "file" ]; then
  echo -e "File Details:\n  id: $2\n  created_at: 2026-08-04T10:00:00Z"
fi
EOF
chmod +x "$FAKE_BIN/plaud"

PATH="$FAKE_BIN:$PATH" bash "$TEST_ROOT/scripts/run_plaud_pipeline.sh"

[ ! -f "$CLAUDE_INVOKED_MARKER" ] || fail "claude was invoked even though candidate transcript errored"
grep -q "no-op" "$TEST_ROOT/logs/run.log" || fail "run.log does not contain no-op when transcript errored"
echo "PASS: errored transcript recording skips claude and logs no-op"

# ==============================================================================
# Scenario 4: Candidate with real transcript reaches Claude, creates note and cost ledger
# ==============================================================================
rm -f "$CLAUDE_INVOKED_MARKER"
rm -f "$TEST_ROOT/claude.log"
echo '[]' > "$TEST_ROOT/state/processed_ids.json"
echo '{}' > "$TEST_ROOT/state/attempts.json"
echo -n "" > "$TEST_ROOT/logs/run.log"
rm -rf "$TEST_ROOT/notes" && mkdir -p "$TEST_ROOT/notes"

cat > "$FAKE_BIN/plaud" <<'EOF'
#!/bin/bash
if [ "$1" = "recent" ]; then
  echo -e "- Fetching recordings from the last 7 days...\nRecordings in the last 7 days: 1\n  \033[36mof_dddddddddddddddddddddddddddddddd\033[39m  10-28 Strategic Roadmap  2026-08-04  20s"
elif [ "$1" = "transcript" ]; then
  echo -e "- Fetching transcript...\n\nTranscript: Strategic Roadmap\n\n[00:00 - 00:20] Speaker 1: Met with Acme Corp team about project roadmap"
elif [ "$1" = "file" ]; then
  echo -e "File Details:\n  id: $2\n  created_at: 2026-08-04T10:00:00Z"
fi
EOF
chmod +x "$FAKE_BIN/plaud"

rm -f "$CLAUDE_HANDLER"

PATH="$FAKE_BIN:$PATH" bash "$TEST_ROOT/scripts/run_plaud_pipeline.sh"

[ -f "$CLAUDE_INVOKED_MARKER" ] || fail "claude was not invoked for recording with valid transcript"
[ ! -f "$TEST_ROOT/state/candidates.txt" ] || fail "candidates.txt should no longer exist"
LEDGER_LINE=$(tail -n 1 "$TEST_ROOT/logs/cost_ledger.csv")
[[ "$LEDGER_LINE" == *",1,0.025,ok" ]] || [[ "$LEDGER_LINE" == *",1,0.0250,ok" ]] || fail "unexpected ledger line after processing real transcript: $LEDGER_LINE"

# Verify note file was created with correct Markdown layout
NOTE_FILE="$TEST_ROOT/notes/acme-corp/2026-08-04-strategic-roadmap.md"
[ -f "$NOTE_FILE" ] || fail "expected note file $NOTE_FILE does not exist"
grep -q "# Strategic Roadmap" "$NOTE_FILE" || fail "note missing title header"
grep -q -- "- \*\*Date:\*\* 2026-08-04" "$NOTE_FILE" || fail "note missing Date metadata"
grep -q -- "- \*\*Topic:\*\* acme-corp" "$NOTE_FILE" || fail "note missing Topic metadata"
grep -q -- "- \*\*File ID:\*\* of_dddddddddddddddddddddddddddddddd" "$NOTE_FILE" || fail "note missing File ID metadata"
grep -q "## Summary" "$NOTE_FILE" || fail "note missing Summary header"
grep -q "## Key Points" "$NOTE_FILE" || fail "note missing Key Points header"
grep -q "## Action Items" "$NOTE_FILE" || fail "note missing Action Items header"
grep -q -- "- Send updated slide deck (due: 2026-08-10)" "$NOTE_FILE" || fail "note missing dated action item"
grep -q -- "- Schedule follow-up review" "$NOTE_FILE" || fail "note missing undated action item"
echo "PASS: candidate with real transcript reached claude, created note, and updated ledger"

# ==============================================================================
# Scenario 5: Recording that keeps failing is handed to Claude at most max_attempts
# times, then ignored with one "gave up" line in logs/skipped.log
# ==============================================================================
export CLAUDE_COUNT_FILE="$TEST_ROOT/claude_invocations"
echo "0" > "$CLAUDE_COUNT_FILE"
echo '[]' > "$TEST_ROOT/state/processed_ids.json"
echo '{}' > "$TEST_ROOT/state/attempts.json"
rm -f "$TEST_ROOT/logs/skipped.log"

cat > "$FAKE_BIN/plaud" <<'EOF'
#!/bin/bash
if [ "$1" = "recent" ]; then
  echo -e "\033[36mof_eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee\033[39m  10-28 Test Call  2026-08-04  20s"
elif [ "$1" = "transcript" ]; then
  echo -e "- Fetching transcript...\n\nTranscript: Test Call\n\nValid transcript body with plenty of detailed characters for testing."
elif [ "$1" = "file" ]; then
  echo -e "File Details:\n  id: $2\n  created_at: 2026-08-04T10:00:00Z"
fi
EOF
chmod +x "$FAKE_BIN/plaud"

# Fake claude fails (exits 1)
cat > "$CLAUDE_HANDLER" <<EOF
CURR=\$(cat "$CLAUDE_COUNT_FILE")
echo "\$((CURR + 1))" > "$CLAUDE_COUNT_FILE"
exit 1
EOF

# Run 1
PATH="$FAKE_BIN:$PATH" bash "$TEST_ROOT/scripts/run_plaud_pipeline.sh"
[ $(cat "$CLAUDE_COUNT_FILE") -eq 1 ] || fail "claude should have been called 1 time in run 1"
ATTEMPTS_1=$(jq -r '.["of_eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee"]' "$TEST_ROOT/state/attempts.json")
[ "$ATTEMPTS_1" -eq 1 ] || fail "attempt count should be 1 after run 1, got $ATTEMPTS_1"

# Run 2
PATH="$FAKE_BIN:$PATH" bash "$TEST_ROOT/scripts/run_plaud_pipeline.sh"
[ $(cat "$CLAUDE_COUNT_FILE") -eq 2 ] || fail "claude should have been called 2 times in run 2"
ATTEMPTS_2=$(jq -r '.["of_eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee"]' "$TEST_ROOT/state/attempts.json")
[ "$ATTEMPTS_2" -eq 2 ] || fail "attempt count should be 2 after run 2, got $ATTEMPTS_2"

# Run 3
PATH="$FAKE_BIN:$PATH" bash "$TEST_ROOT/scripts/run_plaud_pipeline.sh"
[ $(cat "$CLAUDE_COUNT_FILE") -eq 3 ] || fail "claude should have been called 3 times in run 3"
ATTEMPTS_3=$(jq -r '.["of_eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee"]' "$TEST_ROOT/state/attempts.json")
[ "$ATTEMPTS_3" -eq 3 ] || fail "attempt count should be 3 after run 3, got $ATTEMPTS_3"

# Run 4: Attempts is now 3 (max_attempts). Claude MUST NOT be called!
echo -n "" > "$TEST_ROOT/logs/run.log"
PATH="$FAKE_BIN:$PATH" bash "$TEST_ROOT/scripts/run_plaud_pipeline.sh"
[ $(cat "$CLAUDE_COUNT_FILE") -eq 3 ] || fail "claude was called after reaching max_attempts!"
grep -q "no-op" "$TEST_ROOT/logs/run.log" || fail "run 4 should log no-op"
[ -f "$TEST_ROOT/logs/skipped.log" ] || fail "skipped.log was not created on gave up"
GAVE_UP_COUNT=$(grep -c "of_eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee.*gave up" "$TEST_ROOT/logs/skipped.log" || true)
[ "$GAVE_UP_COUNT" -eq 1 ] || fail "expected 1 gave up line in skipped.log, got $GAVE_UP_COUNT"

# Run 5: Subsequent run must not duplicate the gave up log line
PATH="$FAKE_BIN:$PATH" bash "$TEST_ROOT/scripts/run_plaud_pipeline.sh"
[ $(cat "$CLAUDE_COUNT_FILE") -eq 3 ] || fail "claude was called in run 5!"
GAVE_UP_COUNT_5=$(grep -c "of_eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee.*gave up" "$TEST_ROOT/logs/skipped.log" || true)
[ "$GAVE_UP_COUNT_5" -eq 1 ] || fail "expected still exactly 1 gave up line in skipped.log, got $GAVE_UP_COUNT_5"

echo "PASS: failing recording handed to claude at most max_attempts (3) times, then ignored with one gave up line"

# ==============================================================================
# Scenario 6: Bare-hex entry in an old processed_ids.json still counts as processed
# ==============================================================================
rm -f "$CLAUDE_INVOKED_MARKER"
echo '["a0000000000000000000000000000001"]' > "$TEST_ROOT/state/processed_ids.json"
echo -n "" > "$TEST_ROOT/logs/run.log"

cat > "$FAKE_BIN/plaud" <<'EOF'
#!/bin/bash
if [ "$1" = "recent" ]; then
  echo -e "\033[36mof_a0000000000000000000000000000001\033[39m  10-28 Old Call  2026-08-04  20s"
fi
EOF
chmod +x "$FAKE_BIN/plaud"

rm -f "$CLAUDE_HANDLER"

PATH="$FAKE_BIN:$PATH" bash "$TEST_ROOT/scripts/run_plaud_pipeline.sh"
[ ! -f "$CLAUDE_INVOKED_MARKER" ] || fail "claude was invoked even though bare-hex recording was already processed"
grep -q "no-op" "$TEST_ROOT/logs/run.log" || fail "run.log does not contain no-op when bare-hex recording was processed"
echo "PASS: bare-hex entry in an old processed_ids.json still counts as processed"

# ==============================================================================
# Scenario 7: Claude exits non-zero with unparseable output
# ==============================================================================
echo '[]' > "$TEST_ROOT/state/processed_ids.json"
echo '{}' > "$TEST_ROOT/state/attempts.json"
echo -n "" > "$TEST_ROOT/logs/run.log"

cat > "$FAKE_BIN/plaud" <<'EOF'
#!/bin/bash
if [ "$1" = "recent" ]; then
  echo -e "\033[36mof_ffffffffffffffffffffffffffffffff\033[39m  10-28 Failing Run  2026-08-04  20s"
elif [ "$1" = "transcript" ]; then
  echo -e "- Fetching transcript...\n\nTranscript: Title\n\nValid transcript content with plenty of words to pass the gate."
elif [ "$1" = "file" ]; then
  echo -e "File Details:\n  id: $2\n  created_at: 2026-08-04T10:00:00Z"
fi
EOF
chmod +x "$FAKE_BIN/plaud"

cat > "$CLAUDE_HANDLER" <<'EOF'
echo "syntax error or crash"
exit 1
EOF

PATH="$FAKE_BIN:$PATH" bash "$TEST_ROOT/scripts/run_plaud_pipeline.sh"

RUN_LOG_CONTENT=$(cat "$TEST_ROOT/logs/run.log")
[[ "$RUN_LOG_CONTENT" == *"WARNING: claude exited with status 1"* ]] || fail "claude exit failure not logged in run.log"
LEDGER_LINE=$(tail -n 1 "$TEST_ROOT/logs/cost_ledger.csv")
[[ "$LEDGER_LINE" == *",0,0,error"* ]] || fail "unexpected ledger line after claude failure: $LEDGER_LINE"
[ ! -d "$TEST_ROOT/.lock" ] || fail "lock directory was left behind after failed run"
echo "PASS: claude exit failure logged with WARNING, lock cleaned up"

# ==============================================================================
# Scenario 8: Held lock skips the run
# ==============================================================================
rm -f "$CLAUDE_INVOKED_MARKER"
mkdir "$TEST_ROOT/.lock"
PATH="$FAKE_BIN:$PATH" bash "$TEST_ROOT/scripts/run_plaud_pipeline.sh"
[ ! -f "$CLAUDE_INVOKED_MARKER" ] || fail "claude was invoked while lock was held"
rmdir "$TEST_ROOT/.lock"
echo "PASS: held lock skipped the run"

# ==============================================================================
# Scenario 9: Non-numeric value in attempts.json treated as 0 without crashing
# ==============================================================================
rm -f "$CLAUDE_INVOKED_MARKER"
echo '[]' > "$TEST_ROOT/state/processed_ids.json"
echo '{"of_11112222333344445555666677778888": "corrupt_string_value"}' > "$TEST_ROOT/state/attempts.json"

cat > "$FAKE_BIN/plaud" <<'EOF'
#!/bin/bash
if [ "$1" = "recent" ]; then
  echo -e "\033[36mof_11112222333344445555666677778888\033[39m  10-28 Corrupt Test  2026-08-04  20s"
elif [ "$1" = "transcript" ]; then
  echo -e "- Fetching transcript...\n\nTranscript: Corrupt Test\n\nValid transcript content with plenty of words to pass the gate."
elif [ "$1" = "file" ]; then
  echo -e "File Details:\n  id: $2\n  created_at: 2026-08-04T10:00:00Z"
fi
EOF
chmod +x "$FAKE_BIN/plaud"

rm -f "$CLAUDE_HANDLER"

PATH="$FAKE_BIN:$PATH" bash "$TEST_ROOT/scripts/run_plaud_pipeline.sh"
[ -f "$CLAUDE_INVOKED_MARKER" ] || fail "claude was not invoked when attempt count was non-numeric"
echo "PASS: non-numeric attempt count treated as 0 and does not crash script under set -e"

# ==============================================================================
# Scenario 10: Fake claude receives --tools with empty value and --strict-mcp-config
# ==============================================================================
rm -f "$CLAUDE_LOG"
rm -f "$CLAUDE_HANDLER"
echo '[]' > "$TEST_ROOT/state/processed_ids.json"
echo '{}' > "$TEST_ROOT/state/attempts.json"

cat > "$FAKE_BIN/plaud" <<'EOF'
#!/bin/bash
if [ "$1" = "recent" ]; then
  echo -e "\033[36mof_99999999999999999999999999999999\033[39m  10-28 Flags Check  2026-08-04  20s"
elif [ "$1" = "transcript" ]; then
  echo -e "- Fetching transcript...\n\nTranscript: Flags Check\n\nValid transcript content for verifying tools and strict mcp config flags."
elif [ "$1" = "file" ]; then
  echo -e "File Details:\n  id: $2\n  created_at: 2026-08-04T10:00:00Z"
fi
EOF
chmod +x "$FAKE_BIN/plaud"

PATH="$FAKE_BIN:$PATH" bash "$TEST_ROOT/scripts/run_plaud_pipeline.sh"

[ -f "$CLAUDE_LOG" ] || fail "claude was not invoked in flags check test"
CAPTURED_CALL=$(cat "$CLAUDE_LOG")

# Verify --tools="" was passed as the list flag in = form
echo "$CAPTURED_CALL" | grep -q -- '|ARG|--tools=' || fail "claude did not receive --tools with empty value"
echo "$CAPTURED_CALL" | grep -q -- '|ARG|--strict-mcp-config' || fail "claude did not receive --strict-mcp-config"
echo "PASS: fake claude receives --tools with an empty value and --strict-mcp-config"

# ==============================================================================
# Scenario 11: Prompt injection defense in Reminders:
# Model returns action item: "; do shell script "touch /tmp/pwned" --\
# Proves fake osascript received exact text as separate argument, script text doesn't contain it
# ==============================================================================
rm -f "$OSASCRIPT_LOG"
echo '[]' > "$TEST_ROOT/state/processed_ids.json"
echo '{}' > "$TEST_ROOT/state/attempts.json"

cat > "$FAKE_BIN/plaud" <<'EOF'
#!/bin/bash
if [ "$1" = "recent" ]; then
  echo -e "\033[36mof_12121212121212121212121212121212\033[39m  10-28 Injection Test  2026-08-04  20s"
elif [ "$1" = "transcript" ]; then
  echo -e "- Fetching transcript...\n\nTranscript: Injection\n\nValid transcript content for testing prompt injection defense in osascript."
elif [ "$1" = "file" ]; then
  echo -e "File Details:\n  id: $2\n  created_at: 2026-08-04T10:00:00Z"
fi
EOF
chmod +x "$FAKE_BIN/plaud"

# Return exact malicious payload
cat > "$CLAUDE_HANDLER" <<'EOF'
cat <<'JEOF'
{
  "structured_output": {
    "topic": "security-audit",
    "title": "Injection Test",
    "summary": "Testing prompt injection defense.",
    "key_points": ["Point A"],
    "action_items": [
      {
        "text": "\"; do shell script \"touch /tmp/pwned\" --\\",
        "due_date": null
      }
    ]
  },
  "total_cost_usd": 0.0100,
  "is_error": false
}
JEOF
EOF

PATH="$FAKE_BIN:$PATH" bash "$TEST_ROOT/scripts/run_plaud_pipeline.sh"

[ -f "$OSASCRIPT_LOG" ] || fail "osascript was not invoked for reminder creation"

# Find the call made for creating the reminder
REMINDER_CALL=$(grep "Reminders" "$OSASCRIPT_LOG" || true)
[ -n "$REMINDER_CALL" ] || fail "no osascript call for Reminders found in log"

# Verify script text (-e arguments) does NOT contain 'touch /tmp/pwned'
SCRIPT_TEXT_IN_CALL=$(echo "$REMINDER_CALL" | grep -oE '\|ARG\|-e\|ARG\|[^|]+' || true)
if echo "$SCRIPT_TEXT_IN_CALL" | grep -q "touch /tmp/pwned"; then
  fail "malicious text leaked into the osascript script text (-e)"
fi

# Verify the exact argument was passed after --
MALICIOUS_TARGET='"; do shell script "touch /tmp/pwned" --\'
if ! echo "$REMINDER_CALL" | grep -q -F "|ARG|${MALICIOUS_TARGET}"; then
  fail "osascript did not receive the exact malicious string as a separate argument"
fi

echo "PASS: osascript received untrusted action item as separate argument without leaking into script text"

# ==============================================================================
# Scenario 12: Path traversal defense: topic "../../etc" writes under notes_dir/misc/
# ==============================================================================
echo '[]' > "$TEST_ROOT/state/processed_ids.json"
echo '{}' > "$TEST_ROOT/state/attempts.json"
rm -rf "$TEST_ROOT/notes" && mkdir -p "$TEST_ROOT/notes"

cat > "$FAKE_BIN/plaud" <<'EOF'
#!/bin/bash
if [ "$1" = "recent" ]; then
  echo -e "\033[36mof_34343434343434343434343434343434\033[39m  10-28 Traversal  2026-08-04  20s"
elif [ "$1" = "transcript" ]; then
  echo -e "- Fetching transcript...\n\nTranscript: Traversal\n\nValid transcript content for verifying path traversal defense."
elif [ "$1" = "file" ]; then
  echo -e "File Details:\n  id: $2\n  created_at: 2026-08-04T10:00:00Z"
fi
EOF
chmod +x "$FAKE_BIN/plaud"

cat > "$CLAUDE_HANDLER" <<'EOF'
cat <<'JEOF'
{
  "structured_output": {
    "topic": "../../etc",
    "title": "Traversal Attempt",
    "summary": "Testing path traversal defense.",
    "key_points": ["Point A"],
    "action_items": []
  },
  "total_cost_usd": 0.0100,
  "is_error": false
}
JEOF
EOF

PATH="$FAKE_BIN:$PATH" bash "$TEST_ROOT/scripts/run_plaud_pipeline.sh"

# Note must be in $TEST_ROOT/notes/misc/
MISC_DIR="$TEST_ROOT/notes/misc"
[ -d "$MISC_DIR" ] || fail "misc directory was not created under notes_dir"
NOTE_COUNT=$(ls -1 "$MISC_DIR" | wc -l | tr -d '[:space:]')
[ "$NOTE_COUNT" -ge 1 ] || fail "no note was written under misc/"

# Verify no files were created outside notes_dir
[ ! -f "$TEST_ROOT/etc" ] || fail "file was created outside notes_dir via path traversal!"

echo "PASS: topic '../../etc' wrote under notes_dir/misc/"

# ==============================================================================
# Scenario 13: Notion body built with jq --arg and title containing quotes produces valid JSON
# ==============================================================================
rm -f "$CURL_LOG" "$CURL_DATA_FILE"
echo '[]' > "$TEST_ROOT/state/processed_ids.json"
echo '{}' > "$TEST_ROOT/state/attempts.json"

# Enable Notion in config.json
cat > "$TEST_ROOT/config.json" <<EOF
{
  "notes_dir": "$TEST_ROOT/notes",
  "notion": { "enabled": true, "database_id": "test_db_id", "token_env": "NOTION_TOKEN" },
  "calendar": { "enabled": false, "calendar_name": "Calendar" },
  "reminders": { "enabled": false, "list_name": "Plaud Action Items" },
  "model": "claude-haiku-4-5",
  "max_budget_usd_per_run": 0.50,
  "max_attempts": 3,
  "lookback_days": 7
}
EOF
export NOTION_TOKEN="secret_test_token"

cat > "$FAKE_BIN/plaud" <<'EOF'
#!/bin/bash
if [ "$1" = "recent" ]; then
  echo -e "\033[36mof_56565656565656565656565656565656\033[39m  10-28 Notion Test  2026-08-04  20s"
elif [ "$1" = "transcript" ]; then
  echo -e "- Fetching transcript...\n\nTranscript: Notion Test\n\nValid transcript content for verifying Notion JSON generation."
elif [ "$1" = "file" ]; then
  echo -e "File Details:\n  id: $2\n  created_at: 2026-08-04T10:00:00Z"
fi
EOF
chmod +x "$FAKE_BIN/plaud"

cat > "$CLAUDE_HANDLER" <<'EOF'
cat <<'JEOF'
{
  "structured_output": {
    "topic": "notion-test",
    "title": "Meeting with \"Acme Corp\" & 'Partners'",
    "summary": "Summary with \"quotes\" and 'apostrophes'.",
    "key_points": ["Key point with \"quotes\""],
    "action_items": [
      {
        "text": "Review \"doc 1\" with team",
        "due_date": "2026-08-15"
      }
    ]
  },
  "total_cost_usd": 0.0100,
  "is_error": false
}
JEOF
EOF

PATH="$FAKE_BIN:$PATH" bash "$TEST_ROOT/scripts/run_plaud_pipeline.sh"

[ -f "$CURL_DATA_FILE" ] || fail "curl was not called with data for Notion"

# Validate that captured payload in CURL_DATA_FILE is valid JSON
jq . "$CURL_DATA_FILE" >/dev/null 2>&1 || fail "captured Notion request body is not valid JSON"

CAPTURED_TITLE=$(jq -r 'select(.properties.Name != null) | .properties.Name.title[0].text.content' "$CURL_DATA_FILE")
EXPECTED_TITLE="Meeting with \"Acme Corp\" & 'Partners'"
[ "$CAPTURED_TITLE" = "$EXPECTED_TITLE" ] || fail "captured Notion title mismatch: got '$CAPTURED_TITLE'"

echo "PASS: Notion body built with jq --arg and title containing quotes produced valid JSON"

# ==============================================================================
# Scenario 14: Failed Reminders call leaves ID out of processed_ids.json and increments attempts
# ==============================================================================
echo '[]' > "$TEST_ROOT/state/processed_ids.json"
echo '{}' > "$TEST_ROOT/state/attempts.json"
rm -f "$TEST_ROOT/logs/skipped.log"

# Re-enable Reminders, disable Notion
cat > "$TEST_ROOT/config.json" <<EOF
{
  "notes_dir": "$TEST_ROOT/notes",
  "notion": { "enabled": false, "database_id": "" },
  "calendar": { "enabled": false, "calendar_name": "Calendar" },
  "reminders": { "enabled": true, "list_name": "Plaud Action Items" },
  "model": "claude-haiku-4-5",
  "max_budget_usd_per_run": 0.50,
  "max_attempts": 3,
  "lookback_days": 7
}
EOF

cat > "$FAKE_BIN/plaud" <<'EOF'
#!/bin/bash
if [ "$1" = "recent" ]; then
  echo -e "\033[36mof_78787878787878787878787878787878\033[39m  10-28 Rem Fail  2026-08-04  20s"
elif [ "$1" = "transcript" ]; then
  echo -e "- Fetching transcript...\n\nTranscript: Rem Fail\n\nValid transcript content for testing reminders failure handling."
elif [ "$1" = "file" ]; then
  echo -e "File Details:\n  id: $2\n  created_at: 2026-08-04T10:00:00Z"
fi
EOF
chmod +x "$FAKE_BIN/plaud"

cat > "$CLAUDE_HANDLER" <<'EOF'
cat <<'JEOF'
{
  "structured_output": {
    "topic": "rem-fail",
    "title": "Reminders Failure Test",
    "summary": "Testing osascript failure.",
    "key_points": ["Point A"],
    "action_items": [
      {
        "text": "Task A",
        "due_date": null
      }
    ]
  },
  "total_cost_usd": 0.0100,
  "is_error": false
}
JEOF
EOF

# Make osascript fail
export OSASCRIPT_FAIL=1

PATH="$FAKE_BIN:$PATH" bash "$TEST_ROOT/scripts/run_plaud_pipeline.sh"

unset OSASCRIPT_FAIL

# ID must NOT be in processed_ids.json
if grep -q "of_78787878787878787878787878787878" "$TEST_ROOT/state/processed_ids.json"; then
  fail "failed recording was marked as processed in processed_ids.json"
fi

# Attempt count must be incremented to 1
REM_ATTEMPTS=$(jq -r '.["of_78787878787878787878787878787878"]' "$TEST_ROOT/state/attempts.json")
[ "$REM_ATTEMPTS" -eq 1 ] || fail "expected attempt count 1 after reminders failure, got: $REM_ATTEMPTS"

# Logged to skipped.log
[ -f "$TEST_ROOT/logs/skipped.log" ] || fail "skipped.log was not created on reminders failure"
grep -q "of_78787878787878787878787878787878.*reminders-failed" "$TEST_ROOT/logs/skipped.log" || fail "reminders failure not logged in skipped.log"

echo "PASS: failed Reminders call leaves ID out of processed_ids.json and increments attempts"

# ==============================================================================
# Scenario 15: Backfill flag uses 30-day lookback
# ==============================================================================
rm -f "$TEST_ROOT/plaud_recent_args.txt"
cat > "$FAKE_BIN/plaud" <<EOF
#!/bin/bash
if [ "\$1" = "recent" ]; then
  printf '%s\n' "\$*" > "$TEST_ROOT/plaud_recent_args.txt"
  echo -e "- Fetching recordings...\nRecordings: 0"
fi
EOF
chmod +x "$FAKE_BIN/plaud"

PATH="$FAKE_BIN:$PATH" bash "$TEST_ROOT/scripts/run_plaud_pipeline.sh" --backfill

[ -f "$TEST_ROOT/plaud_recent_args.txt" ] || fail "plaud was not called in backfill mode"
RECENT_ARGS=$(cat "$TEST_ROOT/plaud_recent_args.txt")
[[ "$RECENT_ARGS" == *"recent -d 30"* ]] || fail "expected plaud recent -d 30 in backfill mode, got: $RECENT_ARGS"
echo "PASS: --backfill flag uses 30-day lookback"

echo "All run_plaud_pipeline tests passed successfully."
