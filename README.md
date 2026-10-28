# Plaud Notes Autopilot

An automated pipeline for Plaud voice recorder notes on macOS. A scheduled background job checks for new Plaud recordings, uses the free Plaud CLI to verify that transcripts are complete, and runs Claude Code headlessly to synthesize structured Markdown notes organized by topic. Action items are automatically added to macOS Reminders and optionally to Google Calendar, with optional note mirroring to Notion.

```text
[macOS launchd]
       │
       ▼
[scripts/run_plaud_pipeline.sh]
       │
       ├─► (Checks plaud recent -d <days>)
       ├─► (Checks state/processed_ids.json & state/attempts.json)
       ├─► (Verifies non-empty transcript via plaud transcript)
       │
       ▼
Are candidates actionable?
       ├── No  ──► Log "no-op" and exit ($0 cost)
       └── Yes ──► Invoke Claude Code (/plaud-pipeline)
                         │
                         ├─► Write Markdown note (~/Documents/PlaudNotes/<topic>/...)
                         ├─► Create macOS Reminders (Plaud Action Items)
                         ├─► [Optional] Create Google Calendar events
                         └─► [Optional] Mirror note to Notion database
```

## What It Costs

Quiet runs cost **$0**.

Runs that process recordings cost roughly **$0.25–$0.45** per run under the default budget cap (`max_budget_usd_per_run: 0.50`).

**Why the cost gate exists:**
The first version of this tool had a free check that pulled recording IDs out of `plaud recent` with a 32-hex-character pattern. Plaud IDs actually start with `of_`, so the check dropped the prefix, never matched the IDs it had already processed, and treated every recording from the past week as new. Each scheduled run then paid Claude about $0.25 to find there was nothing to do. For two weeks most runs processed 0 recordings and still cost $0.11–$0.40 each. Recordings whose transcripts weren't ready yet caused the same problem.

On the first run, everything in the lookback window (default 7 days) counts as new, and up to 5 recordings get processed per run.

This pipeline fixes that cost bug by running a local gate before Claude is ever called. The shell script checks `plaud transcript <file_id>` directly with the free Plaud CLI and tracks retry attempts in `state/attempts.json`. If a recording transcript is unready or empty, or if it exceeds `max_attempts` (default 3), Claude is never invoked. The run logs `no-op` and costs $0.

## Requirements

- **macOS** (uses `launchd` and `osascript` for Reminders)
- **Plaud CLI** (`@plaud-ai/cli`) installed and logged in (`plaud auth login`)
- **Claude Code CLI** (`claude`) installed and authenticated
- **jq** installed (`brew install jq`)
- **Optional**: Google Calendar and Notion MCP servers configured in Claude Code (if using those integrations)

## 5-Minute Setup

1. **Clone the repository:**
   ```bash
   git clone https://github.com/your-username/plaud-notes-autopilot.git
   cd plaud-notes-autopilot
   ```

2. **Create your configuration file:**
   ```bash
   cp config.example.json config.json
   ```

3. **Configure settings:**
   Open `config.json` and adjust:
   - `notes_dir`: where you want your Markdown notes saved (defaults to `~/Documents/PlaudNotes`).
   - `reminders`: ensure `enabled` is `true` and set your preferred `list_name` (default: `"Plaud Action Items"`).
   - `schedule`: list of daily run times (default: 10:00 and 20:00).
   - `notion` / `calendar`: set `enabled: true` and provide `data_source` if using them.

4. **Install the background scheduler:**
   ```bash
   bash scripts/install.sh
   ```
   This generates `~/Library/LaunchAgents/com.github.plaud-notes-autopilot.plist` configured to your repository directory and schedule, and loads it into `launchd`.

## How to Run It Once by Hand

To run the pipeline immediately from your terminal:

```bash
bash scripts/run_plaud_pipeline.sh
```

To run a 30-day historical backfill with Claude Code:

```bash
claude -p "/plaud-pipeline --backfill"
```

## How to Uninstall

To remove the scheduled job and delete the launchd plist:

```bash
bash scripts/uninstall.sh
```

Your notes in `notes_dir`, logs in `logs/`, and state files in `state/` remain untouched.

## Privacy

- Audio recording transcripts are sent to Anthropic via Claude Code for processing and summarization.
- No data leaves your computer other than what is required by Claude Code and any integrations you explicitly enable (Notion API or Google Calendar).
- All notes, logs, and state files are saved locally on your machine.

## Troubleshooting

- **`config.json not found` error:**
  Ensure you copied `config.example.json` to `config.json` in the project root.
- **`plaud recent failed` or authentication error:**
  Verify that the Plaud CLI is authenticated by running `plaud auth status` or `plaud auth login`.
- **Plaud MCP connector:**
  If you also have a Plaud MCP connector, this tool ignores it on purpose and uses the CLI.
- **macOS Reminders permission prompt:**
  macOS may ask for permission to let terminal or osascript control Reminders on first run. Grant access in System Settings > Privacy & Security > Automation.
- **Inspecting logs:**
  - `logs/run.log`: summary of each pipeline run.
  - `logs/cost_ledger.csv`: CSV ledger of recordings processed and Claude API costs.
  - `logs/skipped.log`: recordings skipped due to errors or reaching `max_attempts`.
  - `logs/launchd.log` & `logs/launchd.err.log`: launchd output and errors.

## Disclaimer

This project is an independent open-source tool and is not affiliated with, sponsored by, or endorsed by Plaud or Nicebuild LLC.
