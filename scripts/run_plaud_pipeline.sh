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

BACKFILL=0
for arg in "$@"; do
  case "$arg" in
    --backfill)
      BACKFILL=1
      ;;
  esac
done

if [ "$BACKFILL" -eq 1 ]; then
  LOOKBACK_DAYS=30
else
  LOOKBACK_DAYS=$(jq -r '.lookback_days // 7' "$CONFIG_FILE")
fi

MODEL=$(jq -r '.model // "claude-haiku-4-5"' "$CONFIG_FILE")
MAX_BUDGET=$(jq -r '.max_budget_usd_per_run // 0.50' "$CONFIG_FILE")
MAX_ATTEMPTS=$(jq -r '.max_attempts // 3' "$CONFIG_FILE")
NOTES_DIR=$(jq -r '.notes_dir // "~/Documents/PlaudNotes"' "$CONFIG_FILE")
EXPANDED_NOTES_DIR="${NOTES_DIR/#\~/$HOME}"

REMINDERS_ENABLED=$(jq -r '.reminders.enabled // false' "$CONFIG_FILE")
REMINDERS_LIST=$(jq -r '.reminders.list_name // "Plaud Action Items"' "$CONFIG_FILE")

CALENDAR_ENABLED=$(jq -r '.calendar.enabled // false' "$CONFIG_FILE")
CALENDAR_NAME=$(jq -r '.calendar.calendar_name // "Calendar"' "$CONFIG_FILE")

NOTION_ENABLED=$(jq -r '.notion.enabled // false' "$CONFIG_FILE")
NOTION_DB_ID=$(jq -r '.notion.database_id // .notion.data_source // ""' "$CONFIG_FILE")
NOTION_TOKEN_ENV=$(jq -r '.notion.token_env // "NOTION_TOKEN"' "$CONFIG_FILE")

STATE_DIR="$PROJECT_DIR/state"
LOGS_DIR="$PROJECT_DIR/logs"
PIPELINE_DIR="$PROJECT_DIR/pipeline"
SCHEMA_FILE="$PIPELINE_DIR/note.schema.json"
PROMPT_FILE="$PIPELINE_DIR/system-prompt.md"

PROCESSED_FILE="$STATE_DIR/processed_ids.json"
ATTEMPTS_FILE="$STATE_DIR/attempts.json"
LEDGER_FILE="$LOGS_DIR/cost_ledger.csv"
RUN_LOG="$LOGS_DIR/run.log"
LAST_RUN_FILE="$LOGS_DIR/last_run.json"
SKIPPED_LOG="$LOGS_DIR/skipped.log"

mkdir -p "$STATE_DIR" "$LOGS_DIR" "$EXPANDED_NOTES_DIR"

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

if ! mkdir "$PROJECT_DIR/.lock" 2>/dev/null; then
  echo "$(date '+%Y-%m-%d %H:%M:%S') skipped: another run holds the lock" >> "$RUN_LOG"
  exit 0
fi
trap 'rmdir "$PROJECT_DIR/.lock" 2>/dev/null || true' EXIT

CANDIDATES=$(sort_candidates_oldest_first "$CANDIDATES" "$RECENT_OUTPUT")

BATCH=()
while IFS= read -r cid; do
  [ -n "$cid" ] || continue
  BATCH+=("$cid")
  [ ${#BATCH[@]} -ge 5 ] && break
done <<< "$CANDIDATES"

COUNT="${#BATCH[@]}"
echo "$(date '+%Y-%m-%d %H:%M:%S') found $COUNT candidate recording(s), processing" >> "$RUN_LOG"

# Build full system prompt with existing archive topics
BASE_PROMPT=""
if [ -f "$PROMPT_FILE" ]; then
  BASE_PROMPT=$(cat "$PROMPT_FILE")
fi

EXISTING_TOPICS=""
if [ -d "$EXPANDED_NOTES_DIR" ]; then
  TOPIC_LIST=$(find "$EXPANDED_NOTES_DIR" -mindepth 1 -maxdepth 1 -type d ! -name '.*' -exec basename {} \; 2>/dev/null | sort | tr '\n' ',' | sed 's/,$//' | sed 's/,/, /g')
  if [ -n "$TOPIC_LIST" ]; then
    EXISTING_TOPICS="Existing topic folder names in archive: $TOPIC_LIST. Reuse an existing topic if it fits."
  fi
fi

FULL_SYSTEM_PROMPT="$BASE_PROMPT"
if [ -n "$EXISTING_TOPICS" ]; then
  FULL_SYSTEM_PROMPT="${FULL_SYSTEM_PROMPT}"$'\n\n'"${EXISTING_TOPICS}"
fi

TOTAL_COST=0
RUN_STATUS="ok"
PROCESSED_NOW=0

for id in "${BATCH[@]}"; do
  if is_id_processed "$id" "$PROCESSED_FILE"; then
    continue
  fi

  recording_date=$(get_recording_date "$id" || true)
  if [[ ! "$recording_date" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
    echo "$(date '+%Y-%m-%d %H:%M:%S') $id plaud-file-failed" >> "$SKIPPED_LOG"
    increment_attempt "$id" "$ATTEMPTS_FILE"
    continue
  fi

  transcript_text=$(get_transcript_text "$id" || true)
  if [ -z "$transcript_text" ]; then
    echo "$(date '+%Y-%m-%d %H:%M:%S') $id transcript-empty-or-failed" >> "$SKIPPED_LOG"
    increment_attempt "$id" "$ATTEMPTS_FILE"
    continue
  fi

  tmp_transcript=$(mktemp)
  printf '%s\n' "$transcript_text" > "$tmp_transcript"

  set +e
  CLAUDE_OUTPUT=$(claude -p --tools="" --strict-mcp-config \
    --model "$MODEL" --effort low \
    --max-budget-usd "$MAX_BUDGET" --output-format json \
    --json-schema "$(cat "$SCHEMA_FILE")" \
    --system-prompt "$FULL_SYSTEM_PROMPT" < "$tmp_transcript")
  CLAUDE_EXIT=$?
  set -e
  rm -f "$tmp_transcript"

  printf '%s\n' "$CLAUDE_OUTPUT" > "$LAST_RUN_FILE"

  CALL_COST=$(printf '%s' "$CLAUDE_OUTPUT" | jq -r '.total_cost_usd // 0' 2>/dev/null || echo "0")
  CALL_COST=${CALL_COST:-0}
  TOTAL_COST=$(jq -n --arg a "$TOTAL_COST" --arg b "$CALL_COST" '($a | tonumber? // 0) + ($b | tonumber? // 0)')

  if [ "$CLAUDE_EXIT" -ne 0 ]; then
    RUN_STATUS="error"
    echo "$(date '+%Y-%m-%d %H:%M:%S') WARNING: claude exited with status $CLAUDE_EXIT" >> "$RUN_LOG"
    echo "$(date '+%Y-%m-%d %H:%M:%S') $id claude-failed: exit $CLAUDE_EXIT" >> "$SKIPPED_LOG"
    increment_attempt "$id" "$ATTEMPTS_FILE"
    continue
  fi

  IS_ERR=$(echo "$CLAUDE_OUTPUT" | jq -r '.is_error // false' 2>/dev/null || echo false)
  if [ "$IS_ERR" = "true" ]; then
    RUN_STATUS="error"
  fi

  MODEL_DATA=$(printf '%s' "$CLAUDE_OUTPUT" | jq -e '
    def parse_val:
      if type == "string" then (fromjson? // null)
      elif type == "object" then .
      else null end;

    (.structured_output | parse_val) // (.result | parse_val) // null
  ' 2>/dev/null || true)

  if [ -z "$MODEL_DATA" ] || [ "$MODEL_DATA" = "null" ]; then
    echo "$(date '+%Y-%m-%d %H:%M:%S') $id claude-output-invalid" >> "$SKIPPED_LOG"
    increment_attempt "$id" "$ATTEMPTS_FILE"
    continue
  fi

  # Validate model outputs
  topic=$(echo "$MODEL_DATA" | jq -r '.topic // "misc"')
  if [[ ! "$topic" =~ ^[a-z0-9][a-z0-9-]{0,39}$ ]]; then
    topic="misc"
  fi

  title=$(echo "$MODEL_DATA" | jq -r '.title // "Untitled"')
  slug=$(echo "$title" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/-/g' | sed -E 's/^-+|-+$//g' | cut -c 1-60 | sed -E 's/-+$//g')
  [ -n "$slug" ] || slug="untitled"

  summary=$(echo "$MODEL_DATA" | jq -r '.summary // ""')
  key_points_json=$(echo "$MODEL_DATA" | jq -c '.key_points // []')
  action_items_json=$(echo "$MODEL_DATA" | jq -c '
    (.action_items // []) | map(
      .due_date = (if (.due_date | type == "string" and test("^[0-9]{4}-[0-9]{2}-[0-9]{2}$")) then .due_date else null end)
    )
  ')

  # Enforce note path resolves inside notes_dir
  TARGET_DIR="$EXPANDED_NOTES_DIR/$topic"
  mkdir -p "$TARGET_DIR"
  REAL_BASE=$(cd "$EXPANDED_NOTES_DIR" 2>/dev/null && pwd -P)
  REAL_TARGET=$(cd "$TARGET_DIR" 2>/dev/null && pwd -P)
  if [[ "$REAL_TARGET" != "$REAL_BASE"/* && "$REAL_TARGET" != "$REAL_BASE" ]]; then
    topic="misc"
    TARGET_DIR="$EXPANDED_NOTES_DIR/misc"
    mkdir -p "$TARGET_DIR"
  fi

  RECORDING_FAILED=0

  # Side effect 1: Markdown Note
  NOTE_CONTENT=$(jq -r -n \
    --arg title "$title" \
    --arg date "$recording_date" \
    --arg topic "$topic" \
    --arg id "$id" \
    --arg summary "$summary" \
    --argjson kp "$key_points_json" \
    --argjson ai "$action_items_json" \
    '
      "# \($title)\n\n" +
      "- **Date:** \($date)\n" +
      "- **Topic:** \($topic)\n" +
      "- **File ID:** \($id)\n\n" +
      "## Summary\n\n\($summary)\n\n" +
      "## Key Points\n\n" +
      (if ($kp | length) == 0 then "Nothing beyond the summary\n\n" else (($kp | map("- " + .) | join("\n")) + "\n\n") end) +
      "## Action Items\n\n" +
      (if ($ai | length) == 0 then "None identified\n" else (($ai | map("- \(.text)" + (if .due_date then " (due: \(.due_date))" else "" end)) | join("\n")) + "\n") end)
    ')

  if grep -rl "$id" "$EXPANDED_NOTES_DIR" 2>/dev/null | grep -q .; then
    :
  else
    NOTE_FILE="$TARGET_DIR/${recording_date}-${slug}.md"
    printf '%s\n' "$NOTE_CONTENT" > "$NOTE_FILE"
  fi

  # Side effect 2: Reminders
  if [ "$RECORDING_FAILED" -eq 0 ] && [ "$REMINDERS_ENABLED" = "true" ]; then
    ai_count=$(echo "$action_items_json" | jq '. | length')
    for ((i=0; i<ai_count; i++)); do
      ai_text=$(echo "$action_items_json" | jq -r ".[$i].text")
      ai_due=$(echo "$action_items_json" | jq -r ".[$i].due_date // \"\"")
      [ "$ai_due" != "null" ] || ai_due=""

      set +e
      osascript \
        -e 'on run argv' \
        -e '  set listName to item 1 of argv' \
        -e '  set reminderText to item 2 of argv' \
        -e '  set dueDateStr to item 3 of argv' \
        -e '  tell application "Reminders"' \
        -e '    if not (exists list listName) then' \
        -e '      make new list with properties {name:listName}' \
        -e '    end if' \
        -e '    tell list listName' \
        -e '      set existingReminders to (reminders whose name is reminderText and completed is false)' \
        -e '      if (count of existingReminders) = 0 then' \
        -e '        if dueDateStr is not "" then' \
        -e '          set prevTIDs to text item delimiters of AppleScript' \
        -e '          set text item delimiters of AppleScript to "-"' \
        -e '          set y to text item 1 of dueDateStr as integer' \
        -e '          set m to text item 2 of dueDateStr as integer' \
        -e '          set d to text item 3 of dueDateStr as integer' \
        -e '          set text item delimiters of AppleScript to prevTIDs' \
        -e '          set targetDate to current date' \
        -e '          set day of targetDate to 1' \
        -e '          set year of targetDate to y' \
        -e '          set month of targetDate to m' \
        -e '          set day of targetDate to d' \
        -e '          set time of targetDate to 0' \
        -e '          make new reminder with properties {name:reminderText, due date:targetDate}' \
        -e '        else' \
        -e '          make new reminder with properties {name:reminderText}' \
        -e '        end if' \
        -e '      end if' \
        -e '    end tell' \
        -e '  end tell' \
        -e 'end run' \
        -- "$REMINDERS_LIST" "$ai_text" "$ai_due"
      OSA_EXIT=$?
      set -e

      if [ "$OSA_EXIT" -ne 0 ]; then
        echo "$(date '+%Y-%m-%d %H:%M:%S') $id reminders-failed: osascript exited with status $OSA_EXIT" >> "$SKIPPED_LOG"
        RECORDING_FAILED=1
        break
      fi
    done
  fi

  # Side effect 3: Calendar
  if [ "$RECORDING_FAILED" -eq 0 ] && [ "$CALENDAR_ENABLED" = "true" ]; then
    ai_count=$(echo "$action_items_json" | jq '. | length')
    for ((i=0; i<ai_count; i++)); do
      ai_due=$(echo "$action_items_json" | jq -r ".[$i].due_date // \"\"")
      [ "$ai_due" != "null" ] || ai_due=""
      [ -n "$ai_due" ] || continue

      ai_text=$(echo "$action_items_json" | jq -r ".[$i].text")

      set +e
      osascript \
        -e 'on run argv' \
        -e '  set calName to item 1 of argv' \
        -e '  set eventTitle to item 2 of argv' \
        -e '  set dueDateStr to item 3 of argv' \
        -e '  if dueDateStr is "" then' \
        -e '    return' \
        -e '  end if' \
        -e '  set prevTIDs to text item delimiters of AppleScript' \
        -e '  set text item delimiters of AppleScript to "-"' \
        -e '  set y to text item 1 of dueDateStr as integer' \
        -e '  set m to text item 2 of dueDateStr as integer' \
        -e '  set d to text item 3 of dueDateStr as integer' \
        -e '  set text item delimiters of AppleScript to prevTIDs' \
        -e '  set startDate to current date' \
        -e '  set day of startDate to 1' \
        -e '  set year of startDate to y' \
        -e '  set month of startDate to m' \
        -e '  set day of startDate to d' \
        -e '  set time of startDate to 0' \
        -e '  set endDate to startDate + (24 * 60 * 60)' \
        -e '  tell application "Calendar"' \
        -e '    if not (exists calendar calName) then' \
        -e '      make new calendar with properties {name:calName}' \
        -e '    end if' \
        -e '    tell calendar calName' \
        -e '      set existingEvents to (events whose summary is eventTitle and start date >= startDate and start date < endDate)' \
        -e '      if (count of existingEvents) = 0 then' \
        -e '        make new event with properties {summary:eventTitle, start date:startDate, end date:endDate, allday event:true}' \
        -e '      end if' \
        -e '    end tell' \
        -e '  end tell' \
        -e 'end run' \
        -- "$CALENDAR_NAME" "$ai_text" "$ai_due"
      CAL_EXIT=$?
      set -e

      if [ "$CAL_EXIT" -ne 0 ]; then
        echo "$(date '+%Y-%m-%d %H:%M:%S') $id calendar-failed: osascript exited with status $CAL_EXIT" >> "$SKIPPED_LOG"
        RECORDING_FAILED=1
        break
      fi
    done
  fi

  # Side effect 4: Notion
  if [ "$RECORDING_FAILED" -eq 0 ] && [ "$NOTION_ENABLED" = "true" ]; then
    notion_token="${!NOTION_TOKEN_ENV:-${NOTION_TOKEN:-}}"
    if [ -z "$notion_token" ] || [ -z "$NOTION_DB_ID" ]; then
      echo "$(date '+%Y-%m-%d %H:%M:%S') $id notion-failed: missing NOTION_TOKEN or database_id" >> "$SKIPPED_LOG"
      RECORDING_FAILED=1
    else
      SEARCH_PAYLOAD=$(jq -n --arg id "$id" '{
        filter: {
          property: "File ID",
          rich_text: {
            equals: $id
          }
        }
      }')

      set +e
      SEARCH_RESP=$(curl -s -f -X POST "https://api.notion.com/v1/databases/${NOTION_DB_ID}/query" \
        -H "Authorization: Bearer ${notion_token}" \
        -H "Notion-Version: 2022-06-28" \
        -H "Content-Type: application/json" \
        -d "$SEARCH_PAYLOAD" 2>&1)
      SEARCH_EXIT=$?
      set -e

      if [ "$SEARCH_EXIT" -ne 0 ]; then
        echo "$(date '+%Y-%m-%d %H:%M:%S') $id notion-failed: search failed with status $SEARCH_EXIT" >> "$SKIPPED_LOG"
        RECORDING_FAILED=1
      else
        PAGE_COUNT=$(echo "$SEARCH_RESP" | jq '.results | length' 2>/dev/null || echo 0)
        if [ "$PAGE_COUNT" -gt 0 ]; then
          :
        else
          PAGE_PAYLOAD=$(jq -n \
            --arg db "$NOTION_DB_ID" \
            --arg title "$title" \
            --arg date "$recording_date" \
            --arg topic "$topic" \
            --arg id "$id" \
            --arg summary "$summary" \
            --argjson key_points "$key_points_json" \
            --argjson action_items "$action_items_json" \
            '{
              parent: { database_id: $db },
              properties: {
                "Name": { title: [{ text: { content: $title } }] },
                "Date": { date: { start: $date } },
                "Topic": { select: { name: $topic } },
                "File ID": { rich_text: [{ text: { content: $id } }] }
              },
              children: (
                [
                  {
                    object: "block",
                    type: "heading_2",
                    heading_2: { rich_text: [{ type: "text", text: { content: "Summary" } }] }
                  },
                  {
                    object: "block",
                    type: "paragraph",
                    paragraph: { rich_text: [{ type: "text", text: { content: $summary } }] }
                  },
                  {
                    object: "block",
                    type: "heading_2",
                    heading_2: { rich_text: [{ type: "text", text: { content: "Key Points" } }] }
                  }
                ] +
                (
                  if ($key_points | length) == 0 then
                    [{
                      object: "block",
                      type: "paragraph",
                      paragraph: { rich_text: [{ type: "text", text: { content: "Nothing beyond the summary" } }] }
                    }]
                  else
                    [ $key_points[] | {
                      object: "block",
                      type: "bulleted_list_item",
                      bulleted_list_item: { rich_text: [{ type: "text", text: { content: . } }] }
                    } ]
                  end
                ) +
                [
                  {
                    object: "block",
                    type: "heading_2",
                    heading_2: { rich_text: [{ type: "text", text: { content: "Action Items" } }] }
                  }
                ] +
                (
                  if ($action_items | length) == 0 then
                    [{
                      object: "block",
                      type: "paragraph",
                      paragraph: { rich_text: [{ type: "text", text: { content: "None identified" } }] }
                    }]
                  else
                    [ $action_items[] | {
                      object: "block",
                      type: "bulleted_list_item",
                      bulleted_list_item: {
                        rich_text: [{
                          type: "text",
                          text: { content: (if .due_date then "\(.text) (due: \(.due_date))" else .text end) }
                        }]
                      }
                    } ]
                  end
                )
              )
            }')

          set +e
          CREATE_RESP=$(curl -s -f -X POST "https://api.notion.com/v1/pages" \
            -H "Authorization: Bearer ${notion_token}" \
            -H "Notion-Version: 2022-06-28" \
            -H "Content-Type: application/json" \
            -d "$PAGE_PAYLOAD" 2>&1)
          CREATE_EXIT=$?
          set -e

          if [ "$CREATE_EXIT" -ne 0 ]; then
            echo "$(date '+%Y-%m-%d %H:%M:%S') $id notion-failed: create page failed with status $CREATE_EXIT" >> "$SKIPPED_LOG"
            RECORDING_FAILED=1
          fi
        fi
      fi
    fi
  fi

  if [ "$RECORDING_FAILED" -eq 1 ]; then
    increment_attempt "$id" "$ATTEMPTS_FILE"
  else
    tmp_proc=$(mktemp "${PROCESSED_FILE}.tmp.XXXXXX")
    jq --arg id "$id" '. + [$id] | unique' "$PROCESSED_FILE" > "$tmp_proc"
    mv "$tmp_proc" "$PROCESSED_FILE"
    PROCESSED_NOW=$((PROCESSED_NOW + 1))
  fi
done

LEDGER_DATE=$(date '+%Y-%m-%d')
echo "${LEDGER_DATE},${PROCESSED_NOW},${TOTAL_COST},${RUN_STATUS}" >> "$LEDGER_FILE"
echo "$(date '+%Y-%m-%d %H:%M:%S') run complete, processed=${PROCESSED_NOW}, cost=\$${TOTAL_COST}, status=${RUN_STATUS}" >> "$RUN_LOG"

osascript \
  -e 'on run argv' \
  -e '  set noteMsg to item 1 of argv' \
  -e '  set noteTitle to item 2 of argv' \
  -e '  display notification noteMsg with title noteTitle' \
  -e 'end run' \
  -- "processed=${PROCESSED_NOW} cost=\$${TOTAL_COST}" "Plaud pipeline: ${RUN_STATUS}" 2>/dev/null || true
