---
name: plaud-pipeline
description: Fetch new Plaud voice-note recordings, classify by topic, extract action items, write notes to Markdown, mirror to Notion, and sync action items to Reminders and Calendar according to config.
---

# Plaud Pipeline

You are running headlessly (via `claude -p`) with a fixed budget. Work through
every step below without asking questions — there is no human to answer them.

**All Plaud data comes from the `plaud` command-line tool, run through Bash (`plaud transcript --polished <id>`, `plaud transcript <id>`, `plaud file <id>`). Never use a Plaud MCP server or connector, even if one is listed. If the `plaud` CLI itself fails, log `plaud-cli-failed` for that ID in `logs/skipped.log` and move on.**

## Inputs and Configuration

Before starting, read `config.json` in `PROJECT_DIR` (the repository root) using `jq`.
The configuration defines:
- `notes_dir`: directory where Markdown notes are written (e.g. `~/Documents/PlaudNotes`).
  Expand `~` to the user's home directory.
- `notion.enabled`: boolean (`true` or `false`).
- `notion.data_source`: Notion data source URL or ID when Notion is enabled.
- `calendar.enabled`: boolean (`true` or `false`).
- `reminders.enabled`: boolean (`true` or `false`).
- `reminders.list_name`: name of the macOS Reminders list (e.g. `"Plaud Action Items"`).
- `max_attempts`: maximum failed attempts before a recording is skipped (default `3`).
- `lookback_days`: lookback window in days for normal runs (default `7`).

State files and logs:
- `PROJECT_DIR/state/candidates.txt` — list of gate-approved Plaud file_ids (`of_[a-f0-9]{32}`),
  one per line and ordered oldest first, written by the wrapper before running Claude.
- `PROJECT_DIR/state/processed_ids.json` — JSON array of Plaud file_ids (`of_[a-f0-9]{32}`) already
  handled. If missing, treat as `[]`. When reading this file, also count a bare 32-hex entry
  as matching its `of_` form, so older state files keep working.
- `PROJECT_DIR/state/attempts.json` — JSON object of retry counts `{ "<file_id>": <n> }`.
  Skip any recording with attempt count >= `max_attempts` (treat non-numeric values as 0).
- Diagnostics log: `PROJECT_DIR/logs/skipped.log` — append-only, one line per skip
  or failure: `<timestamp> <file_id> <reason>`.

## Mode

- Normal run (no argument, invoked as `/plaud-pipeline`): read the approved candidate
  recording IDs from `PROJECT_DIR/state/candidates.txt` (one per line). Process ONLY the IDs
  in that file (still at most 5 recordings per invocation, in the order listed).
  **Do NOT call `plaud recent`** — the wrapper script has already inspected recent recordings,
  verified that transcripts are ready and non-empty, filtered out processed recordings,
  and written the approved IDs in oldest-first order. If `state/candidates.txt` is missing
  or empty, there is nothing to process; exit cleanly.
- Backfill (`/plaud-pipeline --backfill`): process recordings from
  `plaud recent -d 30` instead, still skipping anything already in
  `state/processed_ids.json` (counting bare 32-hex entries as matching their `of_` form)
  or with attempt count >= `max_attempts`.

## Batch limit (both modes)

Process **at most 5 recordings per invocation**. In normal mode, take at most the first
5 IDs from `state/candidates.txt` (which are already ordered oldest first). In backfill
mode, order the candidate recordings **oldest first**, so that if the cap or the budget cuts
the run short, the recordings most at risk of ageing out of the window are the ones that got done.

If more than 5 remain, stop cleanly after the 5th and end with a short final
summary: how many you completed and how many are still outstanding. The next
invocation (scheduled, or re-run by hand) picks up the rest. **Never** trade
quality for volume to fit more recordings into one run — a smaller number of
real notes beats a larger number of bad ones.

## Steps, per new recording

1. Run `plaud transcript --polished <file_id>` to get the cleaned transcript.
   **If the polished block isn't available, don't give up — fall back to
   `plaud transcript <file_id>` (the raw "transaction" block, no flag).**
   Older recordings may never have received a polished version but do have the
   raw one, and the raw block is just as usable as synthesis input
   (same `[00:00 - 00:21] Speaker N: ...` format, just without Plaud's own
   cleanup) — the anti-dump rule already governs how you use it either way,
   so there's no extra risk in accepting raw input. If neither the polished
   nor the raw block is available, try `plaud transcript --block outline <file_id>`
   as a last resort. Only if all three come back unavailable/empty is this a
   genuine failure.

   Whichever block you used, its output contains ANSI escape sequences (the
   `\x1b[...m` colour codes). **Strip/ignore every ANSI escape sequence
   before doing anything with the transcript** — classification, title
   derivation, and note body must all be built from clean text. An escape
   fragment such as `1m` or `22m` must never end up in a title, filename, or
   note body.

   If all three blocks genuinely fail or return empty, append a line to
   `PROJECT_DIR/logs/skipped.log` (`<timestamp> <file_id> transcript-empty-or-failed`)
   and skip it — do NOT add it to `state/processed_ids.json` (so it can be retried
   on a later run if under the attempt limit).

   **Determine the recording date via `plaud file <file_id>` — its
   `created_at` field. This is a mechanical lookup, never a judgment call.**
   For recordings whose Plaud-assigned name has no date in it (recordings
   are often auto-titled without dates, such as demo content or imported audio),
   the date must not be inferred from dates mentioned inside the transcript
   nor invented outright. Never infer the date from transcript content, and never
   assume a title date prefix is present — check `created_at` directly, every time,
   regardless of what the title looks like.

   **Put a 15-second timeout on every `plaud file` call**, same mechanism as
   the osascript calls below: `perl -e 'alarm shift; exec @ARGV' 15 plaud file <file_id>`
   (exit status 142 means it timed out). Plaud's servers can occasionally become
   unreachable. An unattended run must not hang indefinitely on a stalled call.
   If the timed-out call fails, append to `PROJECT_DIR/logs/skipped.log`
   (`<timestamp> <file_id> plaud-file-timeout`) and move on to the next
   recording — do NOT retry it in the same run.
2. From the transcript, determine:
   - `topic`: a short, stable label for the client/project/subject. **Prefer a
     client or company name when the transcript is clearly a conversation
     with or about one** (e.g. "acme-corp", "internal-initiative") — that's the
     most useful axis to browse an archive by. Fall back to an internal
     initiative/project label (e.g. "product-launch", "data-migration",
     "roadmap-planning") when no external client is the subject, or "personal"
     when neither applies. Reuse an existing topic name under `notes_dir` if the
     transcript is clearly about the same client/subject as one that already
     exists there; only invent a new topic name if none fits.
   - `title`: a short human-readable title for this recording.
   - `summary`: 2-4 sentence summary **written by you**, not excerpted.
   - `key_points`: 3-8 bullet points of substantive detail beyond the summary
     — decisions actually made, ideas or concerns raised worth remembering,
     names and roles of who owns what, numbers/figures that mattered. Written
     **by you**, in your own words — genuine synthesis of what a reader
     wants to remember months later, never excerpted or quoted transcript
     text. This is what makes the note worth re-reading later instead of
     just a task list; don't pad it with restatements of the summary.
   - `action_items`: list of `{ text, due_date }`. `due_date` is an ISO date
     (`YYYY-MM-DD`) only when the transcript states or clearly implies one
     (e.g. "by Friday", "before the Aug 10 review"). Leave `due_date` empty
     when no real due date is stated — do not invent one.
3. Write a note to
   `<notes_dir>/<topic>/<recording date YYYY-MM-DD>-<slugified title>.md`.

   **First, check for an existing note for this recording** — run
   `grep -rl "<file_id>" "<notes_dir>"`. If it returns any file,
   this recording already has a note: skip writing, do not overwrite, do not
   write a second file. The existing note is authoritative.

   Use exactly this schema (ISO dates everywhere, every section present):

   ```markdown
   # <title>

   - **Date:** <recording date YYYY-MM-DD>
   - **Topic:** <topic>
   - **File ID:** <file_id>

   ## Summary

   <2-4 sentence summary>

   ## Key Points

   - <substantive point, written by you>
   - <substantive point, written by you>

   ## Action Items

   - <action item text> (due: YYYY-MM-DD)
   - <action item text with no stated due date>
   ```

   Never omit the `## Action Items` heading. When the transcript genuinely has
   no action items, write `None identified` under it — an always-present heading
   is what makes `grep -L "Action Items"` a reliable check for notes that skipped
   extraction. Same for `## Key Points`: if there's truly nothing beyond the
   summary (a very short or thin recording), write `Nothing beyond the summary`
   rather than omitting the heading or padding it with filler.
4. Mirror the note into Notion:
   **First, check `notion.enabled` in `config.json`. If `notion.enabled` is
   `false` or `notion.data_source` is empty, SKIP THIS STEP ENTIRELY.**

   When enabled:
   - **Check for an existing page for this recording.** Call the Notion `search`
     tool with `query` set to the `file_id` and `data_source_url` set to
     `notion.data_source`. If it returns a result, this recording already has a
     Notion page: skip creating one.
   - Otherwise, extract the data source ID from `notion.data_source` and create
     one page via the Notion `create-pages` tool, parent
     `{"type": "data_source_id", "data_source_id": "<data_source_id>"}`, with:
     - `properties.title` = `<title>`
     - `properties."date:Date:start"` = `<recording date YYYY-MM-DD>`
     - `properties.Topic` = `<topic>`
     - `properties."File ID"` = `<file_id>`
     - `content` = the `## Summary`, `## Key Points`, and `## Action Items`
       sections (same text as the Markdown note) — omit the H1 title and the
       Date/Topic/File ID bullets, since those are page properties here.
   - **If that fails with an "Invalid select value" error on `Topic`**, this
     topic has never been used in this database before. Fetch the data source
     to read its current full list of Topic options, then call
     `update-data-source` with
     `ALTER COLUMN "Topic" SET SELECT(<every existing option>:<its existing color>, '<topic>':<a color not already used>)`.
     **This statement replaces the entire option list — it does not append.**
     Include every option the fetch showed, plus the new one. Then retry the
     page creation once.
   - **If Notion page creation fails for any other reason**, append a line to
     `PROJECT_DIR/logs/skipped.log` (`<timestamp> <file_id> notion-failed: <what failed>`)
     and move on. A Notion failure must never abort the run or block the remaining
     steps for this recording.
5. Sync Action Items to macOS Reminders and Google Calendar:

   ### macOS Reminders
   **First, check `reminders.enabled` in `config.json`. If `reminders.enabled`
   is `false`, SKIP creating reminders.**

   When enabled:
   Create a macOS Reminder for **every single action item**, whether or not it
   has a `due_date`. Undated items are open tasks to track; creating a Reminder
   for them is essential so they remain visible. Use the list name specified in
   `reminders.list_name` (default: `"Plaud Action Items"`).

   For each action item, **write the AppleScript to a temp file and run
   `osascript` on the file — never inline the script on the command line with
   `osascript -e`.** Action item text may contain apostrophes (e.g. "Acme's team",
   "don't forget") — inlining breaks shell quoting. Writing to a file sidesteps
   shell quoting entirely: only escape literal double-quotes inside action item
   text as `\"`.

   - **Put a 15-second timeout on every osascript call**:
     `perl -e 'alarm shift; exec @ARGV' 15 osascript /path/to/tempfile`
     (exit status 142 means it timed out). Delete the temp file after use.
   - Before creating the Reminder: check whether a reminder with that name
     already exists in `<reminders.list_name>` (e.g.
     `exists (reminders whose name is "<text>")` within a `tell list`).
     Only proceed if one does not already exist.
   - Create the Reminder in `<reminders.list_name>`:
     - **No `due_date`:** temp file content:
       ```applescript
       tell application "Reminders" to tell list "<reminders.list_name>" to make new reminder with properties {name:"<action item text>"}
       ```
     - **Has a `due_date`:** parse the ISO date (`YYYY-MM-DD`) into year, month,
       day, then build the date by setting fields on `current date`. Set `day`
       to 1 first to avoid month-length overflow. Temp file content:
       ```applescript
       set targetDate to current date
       set day of targetDate to 1
       set year of targetDate to <YYYY>
       set month of targetDate to <M>
       set day of targetDate to <D>
       set time of targetDate to 0
       tell application "Reminders" to tell list "<reminders.list_name>" to make new reminder with properties {name:"<action item text>", due date:targetDate}
       ```
   - If any osascript call fails or times out (including the list not existing),
     append a line to `PROJECT_DIR/logs/skipped.log`
     (`<timestamp> <file_id> osascript-failed: <what failed>`) and continue with
     the next item.

   ### Google Calendar
   **First, check `calendar.enabled` in `config.json`. If `calendar.enabled`
   is `false`, SKIP Google Calendar event creation.**

   When enabled:
   For action items that DO have a `due_date`, create a Google Calendar event
   via Calendar MCP (`search_events` / `create_event`). Check if an event with
   the same title already exists on that date first.
   Create as an **all-day event**: `allDay: true`, `startTime` = due date at
   midnight, `endTime` = following day at midnight (exclusive end date).
   If Calendar MCP call fails, append a line to `PROJECT_DIR/logs/skipped.log`
   (`<timestamp> <file_id> calendar-failed: <what failed>`) and continue.
6. **Append the recording's full `file_id` (always in `of_[a-f0-9]{32}` format) to
   `PROJECT_DIR/state/processed_ids.json` only if all enabled steps succeeded for that
   recording — not if anything about it was written to `skipped.log`.**
   A logged failure means real work for this recording did not complete;
   leaving its `file_id` out lets a subsequent run retry it (if under `max_attempts`).
   Do this immediately after finishing each recording (success or genuine failure),
   before moving to the next one, so a budget cutoff mid-run does not lose or
   duplicate work.

   **Do the append with `jq`, never by hand-editing the file's text.**
   Always write atomically via a temp file:
   ```bash
   jq --arg id "<file_id>" '. + [$id] | unique' PROJECT_DIR/state/processed_ids.json \
     > PROJECT_DIR/state/processed_ids.json.tmp \
     && mv PROJECT_DIR/state/processed_ids.json.tmp PROJECT_DIR/state/processed_ids.json
   ```

## What NOT to do

- **Never use a Plaud MCP server or connector, even if one is listed.** All Plaud
  data must come from the `plaud` CLI via Bash (`plaud transcript --polished <id>`,
  `plaud transcript <id>`, `plaud file <id>`). If the `plaud` CLI itself fails,
  log `plaud-cli-failed` for that ID in `logs/skipped.log` and move on.
- **In normal mode, never call `plaud recent`.** Always read the gate-approved IDs
  from `state/candidates.txt`.
- **Never paste raw transcript lines into a note — this applies to `## Key
  Points` just as much as `## Summary`.** Every note must be genuine summarization,
  genuine key-point synthesis, and genuine action-item extraction. A transcript dump
  is a failed note. If a transcript is too long to process properly within the run's
  remaining budget, skip it (log to `logs/skipped.log`, leave it out of
  `state/processed_ids.json`) so a subsequent run can handle it.
- **Never skip a Reminder because an action item has no due date** (when reminders
  are enabled). Undated items are the common case. Every action item gets a Reminder;
  only dated ones additionally get a Calendar event (if calendar is enabled).
- **A recording is either fully completed or not marked processed at all.**
  Never mark a recording processed in `state/processed_ids.json` if any enabled
  step failed or was skipped.
- Never call Notion's `update-data-source` with a `Topic` select list that
  omits an existing option — `ALTER COLUMN ... SET SELECT(...)` replaces the
  entire list. Always fetch current options first and include all of them.
- Do not invent due dates that aren't stated or clearly implied in the transcript.
- Do not reprocess a file_id already present in `state/processed_ids.json` (counting
  bare 32-hex entries as matching their `of_` form) or whose attempt count in
  `state/attempts.json` is >= `max_attempts`.
