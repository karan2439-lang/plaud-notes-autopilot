#!/bin/bash
set -euo pipefail

REAL_SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TEST_ROOT=$(mktemp -d)
FAKE_BIN=$(mktemp -d)

cleanup() {
  rm -rf "$TEST_ROOT" "$FAKE_BIN"
}
trap cleanup EXIT

mkdir -p "$TEST_ROOT/scripts/lib" "$TEST_ROOT/logs" "$TEST_ROOT/state"
cp "$REAL_SCRIPT_DIR/run_plaud_pipeline.sh" "$TEST_ROOT/scripts/"
cp "$REAL_SCRIPT_DIR/lib/new_recordings.sh" "$TEST_ROOT/scripts/lib/"

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

cat > "$FAKE_BIN/osascript" <<'EOF'
#!/bin/bash
exit 0
EOF
chmod +x "$FAKE_BIN/osascript"

export CLAUDE_HANDLER="$TEST_ROOT/claude_handler.sh"

cat > "$FAKE_BIN/claude" <<'EOF'
#!/bin/bash
prompt_args=()
args=("$@")
while [ ${#args[@]} -gt 0 ]; do
  arg="${args[0]}"
  args=("${args[@]:1}")
  case "$arg" in
    -p|--print)
      ;;
    --disallowedTools=*|--disallowed-tools=*)
      ;;
    --disallowedTools|--disallowed-tools)
      # treat --disallowedTools/--disallowed-tools given WITHOUT = as eating every following argument that doesn't start with --
      while [ ${#args[@]} -gt 0 ] && [[ "${args[0]}" != --* ]]; do
        args=("${args[@]:1}")
      done
      ;;
    --allowedTools=*|--allowed-tools=*|--tools=*|--betas=*|--add-dir=*)
      ;;
    --allowedTools|--allowed-tools|--tools|--betas|--add-dir)
      while [ ${#args[@]} -gt 0 ] && [[ "${args[0]}" != --* ]]; do
        args=("${args[@]:1}")
      done
      ;;
    --model|--effort|--output-format|--max-budget-usd|--agent|--agents|--append-system-prompt|--autocompact|--fallback-model|--mcp-config|--plugin-dir|--resume|--session-id|--settings|--system-prompt)
      if [ ${#args[@]} -gt 0 ]; then
        args=("${args[@]:1}")
      fi
      ;;
    --*=*)
      ;;
    --*)
      ;;
    -*)
      ;;
    *)
      prompt_args+=("$arg")
      ;;
  esac
done

if [ ${#prompt_args[@]} -eq 0 ]; then
  echo "Error: Input must be provided either through stdin or as a prompt argument when using --print" >&2
  exit 1
fi

if [ -f "$CLAUDE_HANDLER" ]; then
  exec bash "$CLAUDE_HANDLER" "$@"
fi

[ -n "${CLAUDE_INVOKED_MARKER:-}" ] && touch "$CLAUDE_INVOKED_MARKER"
echo '{"total_cost_usd":0.0100,"is_error":false}'
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

# Now create config.json for remaining scenarios
cat > "$TEST_ROOT/config.json" <<'EOF'
{
  "notes_dir": "~/Documents/PlaudNotes",
  "notion": { "enabled": false, "data_source": "" },
  "calendar": { "enabled": false },
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
fi
EOF
chmod +x "$FAKE_BIN/plaud"

PATH="$FAKE_BIN:$PATH" bash "$TEST_ROOT/scripts/run_plaud_pipeline.sh"

[ ! -f "$CLAUDE_INVOKED_MARKER" ] || fail "claude was invoked even though candidate transcript errored"
grep -q "no-op" "$TEST_ROOT/logs/run.log" || fail "run.log does not contain no-op when transcript errored"
echo "PASS: errored transcript recording skips claude and logs no-op"

# ==============================================================================
# Scenario 4: Candidate with real transcript reaches Claude and candidates.txt holds approved IDs
# ==============================================================================
rm -f "$CLAUDE_INVOKED_MARKER"
rm -f "$TEST_ROOT/candidates_captured_during_claude.txt"
echo '[]' > "$TEST_ROOT/state/processed_ids.json"
echo '{}' > "$TEST_ROOT/state/attempts.json"
echo -n "" > "$TEST_ROOT/logs/run.log"

cat > "$FAKE_BIN/plaud" <<'EOF'
#!/bin/bash
if [ "$1" = "recent" ]; then
  echo -e "- Fetching recordings from the last 7 days...\nRecordings in the last 7 days: 1\n  \033[36mof_dddddddddddddddddddddddddddddddd\033[39m  10-28 Strategic Roadmap  2026-08-04  20s"
elif [ "$1" = "transcript" ]; then
  echo -e "- Fetching transcript...\n\nTranscript: Strategic Roadmap\n\n[00:00 - 00:20] Speaker 1: Met with Acme Corp team about project roadmap"
fi
EOF
chmod +x "$FAKE_BIN/plaud"

cat > "$CLAUDE_HANDLER" <<EOF
touch "\$CLAUDE_INVOKED_MARKER"
if [ -f "$TEST_ROOT/state/candidates.txt" ]; then
  cp "$TEST_ROOT/state/candidates.txt" "$TEST_ROOT/candidates_captured_during_claude.txt"
fi
echo '["of_dddddddddddddddddddddddddddddddd"]' > "$TEST_ROOT/state/processed_ids.json"
echo '{"total_cost_usd":0.0250,"is_error":false}'
EOF

PATH="$FAKE_BIN:$PATH" bash "$TEST_ROOT/scripts/run_plaud_pipeline.sh"

[ -f "$CLAUDE_INVOKED_MARKER" ] || fail "claude was not invoked for recording with valid transcript"
[ -f "$TEST_ROOT/candidates_captured_during_claude.txt" ] || fail "candidates.txt was not found when claude executed"
CAPTURED_CANDS=$(cat "$TEST_ROOT/candidates_captured_during_claude.txt")
[ "$CAPTURED_CANDS" = "of_dddddddddddddddddddddddddddddddd" ] || fail "candidates.txt had unexpected content: $CAPTURED_CANDS"
[ ! -f "$TEST_ROOT/state/candidates.txt" ] || fail "candidates.txt was not deleted after run"
LEDGER_LINE=$(tail -n 1 "$TEST_ROOT/logs/cost_ledger.csv")
[[ "$LEDGER_LINE" == *",1,0.0250,ok" ]] || fail "unexpected ledger line after processing real transcript: $LEDGER_LINE"
echo "PASS: candidate with real transcript reached claude and candidates.txt held approved IDs and was cleaned up"

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
fi
EOF
chmod +x "$FAKE_BIN/plaud"

# Fake claude fails to process recording (never adds to processed_ids.json)
cat > "$CLAUDE_HANDLER" <<EOF
CURR=\$(cat "$CLAUDE_COUNT_FILE")
echo "\$((CURR + 1))" > "$CLAUDE_COUNT_FILE"
echo '{"total_cost_usd":0.0100,"is_error":true}'
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
[[ "$LEDGER_LINE" == *",0,0,unknown" ]] || fail "unexpected ledger line after claude failure: $LEDGER_LINE"
[ ! -d "$TEST_ROOT/.lock" ] || fail "lock directory was left behind after failed run"
[ ! -f "$TEST_ROOT/state/candidates.txt" ] || fail "candidates.txt was left behind after failed run"
echo "PASS: claude exit failure logged with WARNING, lock and candidates cleaned up"

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
fi
EOF
chmod +x "$FAKE_BIN/plaud"

rm -f "$CLAUDE_HANDLER"

PATH="$FAKE_BIN:$PATH" bash "$TEST_ROOT/scripts/run_plaud_pipeline.sh"
[ -f "$CLAUDE_INVOKED_MARKER" ] || fail "claude was not invoked when attempt count was non-numeric"
echo "PASS: non-numeric attempt count treated as 0 and does not crash script under set -e"

# ==============================================================================
# Scenario 10: Claude receives disallowed-tools arguments for Plaud
# ==============================================================================
rm -f "$CLAUDE_INVOKED_MARKER"
rm -f "$TEST_ROOT/claude_args.txt"
echo '[]' > "$TEST_ROOT/state/processed_ids.json"
echo '{}' > "$TEST_ROOT/state/attempts.json"
echo -n "" > "$TEST_ROOT/logs/run.log"

cat > "$FAKE_BIN/plaud" <<'EOF'
#!/bin/bash
if [ "$1" = "recent" ]; then
  echo -e "\033[36mof_99999999999999999999999999999999\033[39m  10-28 Disallowed Tools Check  2026-08-04  20s"
elif [ "$1" = "transcript" ]; then
  echo -e "- Fetching transcript...\n\nTranscript: Disallowed Tools Check\n\nValid transcript content for verifying disallowed tools flags."
fi
EOF
chmod +x "$FAKE_BIN/plaud"

cat > "$CLAUDE_HANDLER" <<EOF
touch "\$CLAUDE_INVOKED_MARKER"
printf '%s\n' "\$@" > "$TEST_ROOT/claude_args.txt"
echo '["of_99999999999999999999999999999999"]' > "$TEST_ROOT/state/processed_ids.json"
echo '{"total_cost_usd":0.0100,"is_error":false}'
EOF

PATH="$FAKE_BIN:$PATH" bash "$TEST_ROOT/scripts/run_plaud_pipeline.sh"

[ -f "$CLAUDE_INVOKED_MARKER" ] || fail "claude was not invoked in disallowed tools test"
[ -f "$TEST_ROOT/claude_args.txt" ] || fail "claude args were not captured"
CLAUDE_ARGS=$(cat "$TEST_ROOT/claude_args.txt")
echo "$CLAUDE_ARGS" | grep -qE -- "--disallowedTools|--disallowed-tools" || fail "claude did not receive disallowed-tools flag"
echo "$CLAUDE_ARGS" | grep -q "mcp__claude_ai_Plaud" || fail "claude did not receive mcp__claude_ai_Plaud in disallowed tools"
echo "$CLAUDE_ARGS" | grep -q "mcp__plaud" || fail "claude did not receive mcp__plaud in disallowed tools"
echo "PASS: fake claude receives disallowed-tools argument for Plaud"

# ==============================================================================
# Scenario 11: Fake claude enforces argument rules (--disallowedTools eating prompt)
# ==============================================================================
rm -f "$CLAUDE_HANDLER"

# Without '=': eats prompt argument that follows, exits 1 with error
set +e
ERR_OUT=$(PATH="$FAKE_BIN:$PATH" claude -p --disallowedTools "mcp__claude_ai_Plaud" --disallowedTools "mcp__plaud" "/plaud-pipeline" 2>&1)
ERR_EXIT=$?
set -e

[ "$ERR_EXIT" -eq 1 ] || fail "fake claude should exit 1 when disallowedTools eats prompt, got: $ERR_EXIT"
[[ "$ERR_OUT" == *"Error: Input must be provided either through stdin or as a prompt argument when using --print"* ]] || fail "unexpected error message: $ERR_OUT"

# With '=': does not eat prompt argument, exits 0
set +e
OK_OUT=$(PATH="$FAKE_BIN:$PATH" claude -p --disallowedTools="mcp__claude_ai_Plaud,mcp__plaud" --model "haiku" "/plaud-pipeline" 2>&1)
OK_EXIT=$?
set -e

[ "$OK_EXIT" -eq 0 ] || fail "fake claude with = should succeed, got $OK_EXIT: $OK_OUT"
echo "PASS: fake claude exits 1 when --disallowedTools without = eats the prompt argument"

echo "All run_plaud_pipeline tests passed successfully."
