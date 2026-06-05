# work-diary

A local macOS work diary. Every 5 minutes it captures every display, classifies the current activity with a
local Ollama vision model into one short Korean line (calendar-style time tracking: coding / research /
docs / rest …), redacts it when secrets are detected, and appends a single line per capture
(`time | status | summary`) to a daily Markdown file. When the new line is essentially the same as the last
one, it writes nothing. The
only input is screenshot images; per-run images are deleted right after analysis and the latest screenshot
per display is kept in the state dir. All processing stays local.

- What/why: [docs/PRD.md](docs/PRD.md)
- How (architecture/verification): [docs/design.md](docs/design.md)

## Components

| Path | Role |
|---|---|
| `work-diary-capture` | Single-file CLI (Python stdlib only). Subcommand `capture-once`. |
| `config/config.toml.example` | Config example. Copy to `~/.config/work-diary/config.toml`. |
| `launchagent/com.local.work-diary.plist.template` | LaunchAgent template (5-minute interval). |
| `scripts/install.sh` | Install the CLI and register the LaunchAgent. |
| `scripts/uninstall.sh` | Unload the LaunchAgent and remove the CLI (keeps config, logs, diary, Ollama). |
| `scripts/verify.sh` | Validate Ollama, the model, and a vision call (pre-release blocker). |

Scope: automatic capture/summarize/daily-record, local processing, secret screening, error logging.

## Requirements

- Apple Silicon Mac, macOS. Python ≥3.11 (`tomllib`, only if you use a config file).
- [Ollama](https://ollama.com/download) and one vision model. No external Python dependencies.
  If installing via Homebrew, use the **cask**: `brew install --cask ollama-app`
  (the `ollama` formula ships without the runner — see Known Issues).

## Install

```bash
./scripts/verify.sh     # validate Ollama, model, and a vision call (first)
./scripts/install.sh    # install to ~/.local/bin + register the LaunchAgent
```

### Screen Recording permission (once)

macOS attributes Screen Recording to the **responsible process** — the program that runs the capture, not
`screencapture` itself. Manual runs inherit your terminal app's grant (allow it once and `capture-once` works).
The LaunchAgent runs under `launchd`, so its responsible process is the **Python interpreter** the agent runs,
which `install.sh` pins and prints. A background agent cannot show the consent prompt, so add it manually:

1. System Settings → Privacy & Security → **Screen & System Audio Recording**
2. Click **+**, press **⌘ ⇧ G** (Go to Folder), paste the interpreter path that `install.sh` printed
   (e.g. `/opt/homebrew/opt/python@3.14/bin/python3.14`), then select and enable it. For dot-folders like
   `~/.local/bin`, **⌘ ⇧ .** toggles hidden items.
3. Reapply the LaunchAgent and trigger one run to verify:

```bash
launchctl bootout   gui/$(id -u) ~/Library/LaunchAgents/com.local.work-diary.plist
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.local.work-diary.plist
launchctl kickstart -k gui/$(id -u)/com.local.work-diary
```

> Known Issue: `launchd`'s PATH lacks Homebrew, so a bare `#!/usr/bin/env python3` would resolve to Apple's
> `/usr/bin/python3` (3.9, no `tomllib`) and silently ignore `config.toml`. `install.sh` pins the agent's
> interpreter to the `python3` found at install time, so re-run it after a major Python upgrade.

> The only input is screenshot images, so **no Accessibility permission is needed**. Window titles and app
> metadata are not collected; Screen Recording is the only permission.

## Usage

```bash
work-diary-capture capture-once          # capture and record once, immediately
launchctl print gui/$(id -u)/com.local.work-diary   # status
launchctl bootout gui/$(id -u) ~/Library/LaunchAgents/com.local.work-diary.plist  # stop
./scripts/uninstall.sh                   # full uninstall (keeps config/logs/diary/Ollama)
```

Logs: `<repo>/logs/work-diary.out.log`, `<repo>/logs/work-diary.err.log` (kept inside the repo).

## Output

Appends to `<diary_root>/YYYY/MM/YYYY-MM-DD.md`. Default `diary_root` is this repo's `diary/`.
Field labels are English; the model summary is Korean.

```markdown
## 2026-06-05

- 09:35 | OK | 코딩/개발 — 에디터와 터미널에서 작업 중.
- 09:45 | NOK | hidden (secret-detected)
```

One line per capture: `- time | status | summary`. The `summary` is one short activity label for
calendar-style time tracking (coding / research / docs / rest …), not a detailed transcription.

Status is `OK` only for a clean analyzed entry; `NOK` covers both redacted (secret detected, summary
withheld as `hidden (...)`) and error (pipeline failure, diagnostic in the summary). The `summary` field
still distinguishes the two. A near-duplicate of the previous line is skipped entirely (stderr log only).

## Config

Copy `config/config.toml.example` to `~/.config/work-diary/config.toml` and edit. Without the file, the CLI
uses built-in defaults. Key options: `diary_root`, `model`, `api_timeout`, `total_timeout`,
`resize_single`/`resize_multi`, `block_tags`, duplicate-skip (`skip_similar`, `similarity_threshold`), and
`store_last_screenshot`.

## Known Issues

- **Install Ollama via cask / the official app.** The Homebrew **formula** `ollama` (0.30.5) does not bundle
  the `llama-server` runtime, so `/api/chat` fails with HTTP 500 (`llama-server binary not found … run cmake
  first`). Installing `brew install --cask ollama-app` (or the official app) includes the runner. Models are
  shared at `~/.ollama/models`, so a reinstall does not re-download them.
- **Model `gemma4:12b` is verified working** (vision, 11.9B, Q4_K_M, 7.6GB). To use a different tag, change
  `model` in `config.toml` and re-validate with `scripts/verify.sh`.
  Ref: [Ollama Vision](https://docs.ollama.com/capabilities/vision).
- **Storage path sync.** The default `diary_root` lives under `~/Desktop/diary`, which the macOS "Desktop &
  Documents" iCloud feature auto-syncs if enabled. design §operational cautions advises against defaulting to
  an auto-sync path. Turn it off or set `diary_root` to a non-synced path.
- **Screening relies on the model.** The local model judges sensitivity and flags it via `caution_tags`;
  redaction triggers on tags listed in `block_tags`. It may miss sensitive content or over-redact — tune the
  prompt or `block_tags` (PRD §privacy).
- **Imperfect permission detection.** Without Screen Recording permission, `screencapture` can produce a black
  image with no error, so it is detected only by abnormal-exit / empty-file heuristics.
- **Duplicate-skip is text-similarity based.** The skip compares the new summary to the last written one with
  `difflib` ratio (`similarity_threshold`). Because Gemma may reword the same task, a real duplicate can fall
  below the threshold (logs again) or trivially different work can read as a duplicate (skipped). Tune
  `similarity_threshold`, or set `skip_similar = false`.
- **The latest screenshot is retained.** The tool keeps the most recent screenshot per display in
  `~/Library/Application Support/work-diary/prev` (`0o700`), overwritten each run — a relaxation of the
  "volatile originals" rule. Set `store_last_screenshot = false` to keep nothing.
