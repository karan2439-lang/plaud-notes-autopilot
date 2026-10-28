#!/bin/bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJECT_DIR"
source "$PROJECT_DIR/scripts/lib/new_recordings.sh"

CONFIG_FILE="$PROJECT_DIR/config.json"
if [ ! -f "$CONFIG_FILE" ]; then
  echo "Error: config.json not found in $PROJECT_DIR. Copy config.example.json to config.json and configure it." >&2
  exit 1
fi

LOOKBACK_DAYS=$(jq -r '.lookback_days // 7' "$CONFIG_FILE")
MODEL=$(jq -r '.model // "claude-haiku-4-5"' "$CONFIG_FILE")
MAX_BUDGET=$(jq -r '.max_budget_usd_per_run // 0.50' "$CONFIG_FILE")
MAX_ATTEMPTS=$(jq -r '.max_attempts // 3' "$CONFIG_FILE")

STATE_DIR="$PROJECT_DIR/state"
LOGS_DIR="$PROJECT_DIR/logs"
PROCESSED_FILE="$STATE_DIR/processed_ids.json"
ATTEMPTS_FILE="$STATE_DIR/attempts.json"
CANDIDATES_FILE="$STATE_DIR/candidates.txt"
LEDGER_FILE="$LOGS_DIR/cost_ledger.csv"
RUN_LOG="$LOGS_DIR/run.log"
LAST_RUN_FILE="$LOGS_DIR/last_run.json"
SKIPPED_LOG="$LOGS_DIR/skipped.log"

mkdir -p "$STATE_DIR" "$LOGS_DIR"

# Migrate legacy root processed_ids.json if present
if [ -f "$PROJECT_DIR/processed_ids.json" ] && [ ! -f "$PROCESSED_FILE" ]; then
  mv "$PROJECT_DIR/processed_ids.json" "$PROCESSED_FILE"
fi

if [ ! -f "$PROCESSED_FILE" ]; then
  echo '[]' > "$PROCESSED_FILE"
fi

if [ ! -f "$ATTEMPTS_FILE" ]; then
  echo '{}' > "$ATTEMPTS_FILE"
fi

if [ ! -f "$LEDGER_FILE" ]; then
  echo "date,recordings_processed,total_cost_usd,status" > "$LEDGER_FILE"
fi

set +e
RECENT_OUTPUT=$(plaud recent -d "$LOOKBACK_DAYS")
PLAUD_EXIT=$?
set -e

if [ "$PLAUD_EXIT" -ne 0 ]; then
  echo "$(date '+%Y-%m-%d %H:%M:%S') WARNING: plaud recent failed with status $PLAUD_EXIT" >> "$RUN_LOG"
  exit 0
fi

NEW_IDS=$(get_new_recording_ids "$RECENT_OUTPUT" "$PROCESSED_FILE")

if [ -z "$NEW_IDS" ]; then
  echo "$(date '+%Y-%m-%d %H:%M:%S') no-op: nothing new" >> "$RUN_LOG"
  exit 0
fi

CANDIDATES=""
for id in $NEW_IDS; do
  attempts=$(get_attempt_count "$id" "$ATTEMPTS_FILE")
  if [ "$attempts" -ge "$MAX_ATTEMPTS" ]; then
    if ! grep -qE "$id.*gave up" "$SKIPPED_LOG" 2>/dev/null; then
      echo "$(date '+%Y-%m-%d %H:%M:%S') $id gave up (max attempts reached: $MAX_ATTEMPTS)" >> "$SKIPPED_LOG"
    fi
    continue
  fi

  if ! has_valid_transcript "$id"; then
    continue
  fi

  if [ -z "$CANDIDATES" ]; then
    CANDIDATES="$id"
  else
    CANDIDATES="$CANDIDATES"$'\n'"$id"
  fi
done

if [ -z "$CANDIDATES" ]; then
  echo "$(date '+%Y-%m-%d %H:%M:%S') no-op: no candidate recordings ready" >> "$RUN_LOG"
  exit 0
fi

# The skill rewrites processed_ids.json wholesale, so two overlapping runs
# (e.g. a manual backfill still going when the scheduled job fires) would race.
if ! mkdir "$PROJECT_DIR/.lock" 2>/dev/null; then
  echo "$(date '+%Y-%m-%d %H:%M:%S') skipped: another run holds the lock" >> "$RUN_LOG"
  exit 0
fi
trap 'rm -f "$CANDIDATES_FILE" 2>/dev/null || true; rmdir "$PROJECT_DIR/.lock" 2>/dev/null || true' EXIT

CANDIDATES=$(sort_candidates_oldest_first "$CANDIDATES" "$RECENT_OUTPUT")
printf '%s\n' "$CANDIDATES" > "$CANDIDATES_FILE"

COUNT=$(echo "$CANDIDATES" | grep -v '^$' | wc -l | tr -d '[:space:]')
echo "$(date '+%Y-%m-%d %H:%M:%S') found $COUNT candidate recording(s), invoking claude" >> "$RUN_LOG"

BEFORE_COUNT=$(jq 'length' "$PROCESSED_FILE" 2>/dev/null || echo 0)

set +e
RESULT_JSON=$(claude -p --disallowedTools="mcp__claude_ai_Plaud,mcp__plaud" \
  --model "$MODEL" --effort low \
  --output-format json --max-budget-usd "$MAX_BUDGET" --dangerously-skip-permissions \
  "/plaud-pipeline")
CLAUDE_EXIT=$?
set -e

rm -f "$CANDIDATES_FILE" 2>/dev/null || true

printf '%s\n' "$RESULT_JSON" > "$LAST_RUN_FILE"

if [ "$CLAUDE_EXIT" -ne 0 ]; then
  echo "$(date '+%Y-%m-%d %H:%M:%S') WARNING: claude exited with status $CLAUDE_EXIT" >> "$RUN_LOG"
fi

# Increase retry count for recordings handed to Claude that are still not processed
for id in $CANDIDATES; do
  [ -n "$id" ] || continue
  if ! is_id_processed "$id" "$PROCESSED_FILE"; then
    increment_attempt "$id" "$ATTEMPTS_FILE"
  fi
done

AFTER_COUNT=$(jq 'length' "$PROCESSED_FILE" 2>/dev/null || echo 0)
# What the skill actually got through, not what the free gate detected.
PROCESSED_NOW=$((AFTER_COUNT - BEFORE_COUNT))

COST=$(echo "$RESULT_JSON" | jq -r '.total_cost_usd // 0' 2>/dev/null || echo "0")
STATUS=$(echo "$RESULT_JSON" \
  | jq -r 'if .is_error == true then "error" elif .is_error == false then "ok" else "unknown" end' \
  2>/dev/null || echo "unknown")
STATUS=${STATUS:-unknown}

LEDGER_DATE=$(date '+%Y-%m-%d')
echo "${LEDGER_DATE},${PROCESSED_NOW},${COST},${STATUS}" >> "$LEDGER_FILE"
echo "$(date '+%Y-%m-%d %H:%M:%S') run complete, processed=${PROCESSED_NOW}, cost=\$${COST}, status=${STATUS}" >> "$RUN_LOG"

# Notify locally regardless of whether any Claude session is watching.
osascript -e "display notification \"processed=${PROCESSED_NOW} cost=\$${COST}\" with title \"Plaud pipeline: ${STATUS}\"" 2>/dev/null || true
