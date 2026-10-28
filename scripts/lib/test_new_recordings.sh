#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
source ./new_recordings.sh

TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

TMP_PROCESSED="$TMP_DIR/processed_ids.json"
echo '["of_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"]' > "$TMP_PROCESSED"

SAMPLE_OUTPUT=$'\x1b[36mof_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\x1b[39m  2026-08-01 10:00:00  2026-08-01  30s\n\x1b[36mof_bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\x1b[39m  2026-08-02 11:00:00  2026-08-02  45s'

RESULT=$(get_new_recording_ids "$SAMPLE_OUTPUT" "$TMP_PROCESSED")

if [ "$RESULT" = "of_bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb" ]; then
  echo "PASS: only the unprocessed id was returned"
else
  echo "FAIL: expected only 'of_bbbb...', got: $RESULT"
  exit 1
fi

RESULT_NO_FILE=$(get_new_recording_ids "$SAMPLE_OUTPUT" "$TMP_DIR/does_not_exist.json")
EXPECTED_NO_FILE=$'of_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\nof_bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'
if [ "$RESULT_NO_FILE" = "$EXPECTED_NO_FILE" ]; then
  echo "PASS: missing processed file treated as none processed"
else
  echo "FAIL: expected both ids with no processed file, got: $RESULT_NO_FILE"
  exit 1
fi

# Test bare 32-hex backward compatibility in processed_ids.json
TMP_LEGACY_PROCESSED="$TMP_DIR/legacy_processed.json"
echo '["cccccccccccccccccccccccccccccccc"]' > "$TMP_LEGACY_PROCESSED"
LEGACY_SAMPLE=$'\x1b[36mof_cccccccccccccccccccccccccccccccc\x1b[39m  2026-08-01 10:00:00  2026-08-01  30s\n\x1b[36mof_dddddddddddddddddddddddddddddddd\x1b[39m  2026-08-02 11:00:00  2026-08-02  45s'
LEGACY_RESULT=$(get_new_recording_ids "$LEGACY_SAMPLE" "$TMP_LEGACY_PROCESSED")
if [ "$LEGACY_RESULT" = "of_dddddddddddddddddddddddddddddddd" ]; then
  echo "PASS: bare 32-hex in processed_ids.json correctly counted as processed against of_ ID"
else
  echo "FAIL: bare 32-hex was not matched: $LEGACY_RESULT"
  exit 1
fi

if is_id_processed "of_cccccccccccccccccccccccccccccccc" "$TMP_LEGACY_PROCESSED" && \
   is_id_processed "cccccccccccccccccccccccccccccccc" "$TMP_LEGACY_PROCESSED"; then
  echo "PASS: is_id_processed matches bare 32-hex in processed_ids.json"
else
  echo "FAIL: is_id_processed failed to match bare hex in processed_ids.json"
  exit 1
fi

if ! is_id_processed "of_dddddddddddddddddddddddddddddddd" "$TMP_LEGACY_PROCESSED"; then
  echo "PASS: is_id_processed correctly reports unprocessed id as false"
else
  echo "FAIL: is_id_processed incorrectly reported absent id as processed"
  exit 1
fi

# Test real-shaped plaud recent output with header lines, ANSI codes, title, date, duration
REAL_SHAPED_OUTPUT=$'- Fetching recordings from the last 7 days...\n\nRecordings in the last 7 days: 2\n\n  \x1b[36mof_1111aaaa2222bbbb3333cccc4444dddd\x1b[39m  10-28 Meeting Discussion  2026-10-28  43m07s\n  \x1b[36mof_5555eeee6666ffff7777aaaa8888bbbb\x1b[39m  10-26 Planning Session  2026-10-26  6m48s\n'
REAL_RESULT=$(get_new_recording_ids "$REAL_SHAPED_OUTPUT" "$TMP_DIR/none.json")
EXPECTED_REAL=$'of_1111aaaa2222bbbb3333cccc4444dddd\nof_5555eeee6666ffff7777aaaa8888bbbb'
if [ "$REAL_RESULT" = "$EXPECTED_REAL" ]; then
  echo "PASS: real-shaped plaud recent output extracted full of_ IDs"
else
  echo "FAIL: real-shaped output failed, expected: $EXPECTED_REAL, got: $REAL_RESULT"
  exit 1
fi

# Test attempt count functions with valid, bare-hex, and non-numeric values
TMP_ATTEMPTS="$TMP_DIR/attempts.json"
cat > "$TMP_ATTEMPTS" <<'EOF'
{
  "of_valid": 1,
  "of_bad_string": "invalid_attempt_count",
  "of_bad_obj": {"nested": "value"},
  "1111aaaa2222bbbb3333cccc4444dddd": 2
}
EOF

# Non-numeric values must be treated as 0 without crashing
[ $(get_attempt_count "of_bad_string" "$TMP_ATTEMPTS") -eq 0 ] || { echo "FAIL: string value not treated as 0"; exit 1; }
[ $(get_attempt_count "of_bad_obj" "$TMP_ATTEMPTS") -eq 0 ] || { echo "FAIL: object value not treated as 0"; exit 1; }
[ $(get_attempt_count "of_valid" "$TMP_ATTEMPTS") -eq 1 ] || { echo "FAIL: valid count mismatch"; exit 1; }
[ $(get_attempt_count "of_1111aaaa2222bbbb3333cccc4444dddd" "$TMP_ATTEMPTS") -eq 2 ] || { echo "FAIL: bare hex key in attempts not found"; exit 1; }
[ $(get_attempt_count "of_unseen" "$TMP_ATTEMPTS") -eq 0 ] || { echo "FAIL: unseen key not 0"; exit 1; }

# Incrementing on non-numeric key should treat it as 0 + 1 = 1
increment_attempt "of_bad_string" "$TMP_ATTEMPTS"
[ $(get_attempt_count "of_bad_string" "$TMP_ATTEMPTS") -eq 1 ] || { echo "FAIL: incrementing non-numeric attempt failed"; exit 1; }

# Incrementing on normal key
increment_attempt "of_valid" "$TMP_ATTEMPTS"
[ $(get_attempt_count "of_valid" "$TMP_ATTEMPTS") -eq 2 ] || { echo "FAIL: incrementing valid attempt failed"; exit 1; }
echo "PASS: attempt tracking functions work atomically and handle non-numeric values"

# Test has_valid_transcript with fake plaud
FAKE_BIN="$TMP_DIR/fake_bin"
mkdir -p "$FAKE_BIN"
cat > "$FAKE_BIN/plaud" <<'EOF'
#!/bin/bash
if [ "$1" = "transcript" ]; then
  case "$2" in
    of_valid_id)
      # Header plus real body with >= 20 non-whitespace chars
      echo -e "- Fetching transcript...\n\nTranscript: 10-28 Strategic Review\n\n[00:00 - 00:20] Speaker 1: Met with the team to finalize roadmap architecture."
      exit 0
      ;;
    of_header_only_id)
      # Header lines only, empty body
      echo -e "- Fetching transcript...\n\nTranscript: 10-28 Empty Call Title\n\n"
      exit 0
      ;;
    of_short_body_id)
      # Header plus tiny body (< 20 non-whitespace chars)
      echo -e "- Fetching transcript...\n\nTranscript: 10-28 Call\n\nShort note"
      exit 0
      ;;
    of_status_only_id)
      # Status icons and headers, no real body
      echo -e "- Fetching transcript...\n✔ Done\nTranscript: 10-28 Call\n"
      exit 0
      ;;
    of_empty_id)
      echo "   "
      exit 0
      ;;
    of_error_id)
      exit 1
      ;;
  esac
fi
exit 0
EOF
chmod +x "$FAKE_BIN/plaud"

PATH="$FAKE_BIN:$PATH"

if has_valid_transcript "of_valid_id"; then
  echo "PASS: header plus real body transcript accepted"
else
  echo "FAIL: valid transcript was rejected"
  exit 1
fi

if ! has_valid_transcript "of_header_only_id"; then
  echo "PASS: header-only transcript rejected"
else
  echo "FAIL: header-only transcript was accepted"
  exit 1
fi

if ! has_valid_transcript "of_short_body_id"; then
  echo "PASS: short body (< 20 chars) transcript rejected"
else
  echo "FAIL: short body transcript was accepted"
  exit 1
fi

if ! has_valid_transcript "of_status_only_id"; then
  echo "PASS: status-only transcript rejected"
else
  echo "FAIL: status-only transcript was accepted"
  exit 1
fi

if ! has_valid_transcript "of_empty_id"; then
  echo "PASS: whitespace-only transcript rejected"
else
  echo "FAIL: whitespace-only transcript was accepted"
  exit 1
fi

if ! has_valid_transcript "of_error_id"; then
  echo "PASS: errored transcript rejected"
else
  echo "FAIL: errored transcript was accepted"
  exit 1
fi

# Test sort_candidates_oldest_first
SORT_OUTPUT=$(sort_candidates_oldest_first $'of_1111aaaa2222bbbb3333cccc4444dddd\nof_5555eeee6666ffff7777aaaa8888bbbb' "$REAL_SHAPED_OUTPUT")
EXPECTED_SORT=$'of_5555eeee6666ffff7777aaaa8888bbbb\nof_1111aaaa2222bbbb3333cccc4444dddd'
if [ "$SORT_OUTPUT" = "$EXPECTED_SORT" ]; then
  echo "PASS: sort_candidates_oldest_first ordered candidates oldest first"
else
  echo "FAIL: sort_candidates_oldest_first output mismatch, got: $SORT_OUTPUT"
  exit 1
fi

echo "All new_recordings library tests passed."
