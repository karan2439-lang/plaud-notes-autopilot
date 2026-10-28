#!/bin/bash
# Extracts Plaud file_ids from `plaud recent` output that aren't yet in
# state/processed_ids.json. Missing/empty/malformed state files are handled safely.

strip_ansi() {
  sed -E "s/$(printf '\033')\[[0-9;?]*[a-zA-Z]//g"
}

get_new_recording_ids() {
  local recent_output="$1"
  local processed_file="$2"

  local processed_ids=""
  if [ -f "$processed_file" ]; then
    processed_ids=$(jq -r '.[]' "$processed_file" 2>/dev/null || true)
  fi

  local all_ids
  all_ids=$(echo "$recent_output" | strip_ansi | grep -oE 'of_[a-f0-9]{32}' || true)

  local id bare
  for id in $all_ids; do
    bare="${id#of_}"
    if ! printf '%s\n' "$processed_ids" | grep -qx -e "$id" -e "$bare"; then
      echo "$id"
    fi
  done
  return 0
}

has_valid_transcript() {
  local id="$1"
  local output
  local exit_code

  set +e
  output=$(plaud transcript "$id" 2>/dev/null)
  exit_code=$?
  set -e

  if [ "$exit_code" -ne 0 ]; then
    return 1
  fi

  local clean
  clean=$(printf '%s' "$output" | strip_ansi | sed -E '/^[[:space:]]*(- Fetching|[✔✗✓]|Transcript:)/d' | tr -d '[:space:]')
  if [ "${#clean}" -lt 20 ]; then
    return 1
  fi

  return 0
}

get_attempt_count() {
  local id="$1"
  local attempts_file="$2"

  local val=0
  if [ -f "$attempts_file" ]; then
    local bare="${id#of_}"
    val=$(jq -r --arg id "$id" --arg bare "$bare" \
      'if ((.[$id] // .[$bare]) | type) == "number" then (.[$id] // .[$bare]) else 0 end' \
      "$attempts_file" 2>/dev/null || echo 0)
  fi

  if [[ "$val" =~ ^[0-9]+$ ]]; then
    echo "$val"
  else
    echo 0
  fi
}

increment_attempt() {
  local id="$1"
  local attempts_file="$2"
  local state_dir
  state_dir="$(dirname "$attempts_file")"
  mkdir -p "$state_dir"

  if [ ! -f "$attempts_file" ]; then
    echo '{}' > "$attempts_file"
  fi

  local bare="${id#of_}"
  local tmp_file
  tmp_file=$(mktemp "${attempts_file}.tmp.XXXXXX")
  jq --arg id "$id" --arg bare "$bare" '
    (if ((.[$id] // .[$bare]) | type) == "number" then (.[$id] // .[$bare]) else 0 end) as $curr |
    .[$id] = ($curr + 1)
  ' "$attempts_file" > "$tmp_file"
  mv "$tmp_file" "$attempts_file"
}

is_id_processed() {
  local id="$1"
  local processed_file="$2"

  if [ ! -f "$processed_file" ]; then
    return 1
  fi

  local bare="${id#of_}"
  local full="of_${bare}"

  jq -e --arg id "$id" --arg bare "$bare" --arg full "$full" \
    'index($id) != null or index($bare) != null or index($full) != null' \
    "$processed_file" >/dev/null 2>&1
}

sort_candidates_oldest_first() {
  local candidates="$1"
  local recent_output="$2"

  local line id d
  local dated_list=""
  local count=0
  local any_date=0

  while IFS= read -r id; do
    [ -n "$id" ] || continue
    count=$((count + 1))
    line=$(printf '%s\n' "$recent_output" | strip_ansi | grep -F "$id" | head -n 1 || true)
    d=$(printf '%s\n' "$line" | grep -oE '[0-9]{4}-[0-9]{2}-[0-9]{2}' | tail -n 1 || true)
    if [ -n "$d" ]; then
      any_date=1
      dated_list="${dated_list}${d} ${count} ${id}"$'\n'
    else
      dated_list="${dated_list}9999-99-99 ${count} ${id}"$'\n'
    fi
  done <<< "$candidates"

  if [ "$any_date" -eq 1 ]; then
    printf '%s' "$dated_list" | sort -k1,1 -k2,2nr | awk '{print $3}'
  else
    printf '%s\n' "$candidates"
  fi
}
