# Local Work Diary — Design

This doc covers *how* (architecture/implementation/verification). For *what/why* see [PRD.md](./PRD.md).

## Purpose

On macOS, periodically capture every display, classify the user's current activity with a local vision model
into one short Korean line (calendar-style time tracking), and append a single line per capture
(`time | status | summary`) to a daily Markdown diary — the final human-readable record. Resized/encoded
screenshots are deleted right after analysis; the latest screenshot per display is kept in the state dir. The
permanent artifact is the Markdown file. The pipeline input is screenshot images only — no OS metadata
(frontmost app, window titles) is read; any brief topic/app hint in a line comes only from what is clearly
legible in the screenshot itself.

The execution unit is a user-session `LaunchAgent` (not a `LaunchDaemon`), because macOS screen capture
requires a GUI session and Screen Recording permission.

## Environment assumptions

- Target: Apple Silicon Mac, M2 Pro, 16GB unified memory, macOS 26.
- Local tools available: `screencapture`, `launchctl`, `sips`, `python3`.
- Optional: `swiftc` (Xcode Command Line Tools) to build the OCR helper. Absent → OCR off, vision-only.
- Ollama is not installed yet; install and model download are a required verification step.
- Default model: `gemma4:12b-it-qat` (vision, 11.9B, QAT int4 / Q4_0, ~7.2GB). Local capture/analysis speed depends on
  resolution, monitor count, and Ollama version, so a local benchmark is a pre-release blocker.

## Fixed decisions

- Capture interval: 5 minutes by default. The model runs every interval; a run whose summary is essentially
  the same as the last written one writes no line (skip, below).
- Implementation: a single Python 3 stdlib CLI (`work-diary-capture`). No external dependencies.
- Input: screenshot images only (the only required permission is Screen Recording).
- Execution: a `LaunchAgent` runs the CLI every 5 minutes.
- Model: `gemma4:12b-it-qat` by default (Google's QAT int4 / Q4_0 checkpoint), via the Ollama REST API `POST /api/chat`, `"stream": false`.
- Structured output: the request sets `"format"` (JSON schema) so the model always returns valid JSON.
- Model residency: `"keep_alive": 0` — unload the model right after each run so nothing stays resident between
  captures. Each run pays a cold-load cost, which is accepted.
- Image input: base64-encoded images in the `messages[].images` array.
- Storage: Markdown only; one line per capture (`- time | status | summary`), summary in Korean.
- Log shape: the activity label lives in a single `summary` string, not in separate fields — kept flat and
  grep-/line-friendly so the day reads in one pass.
- Originals: resized/encoded images and the per-run temp dir are deleted right after analysis. The latest
  screenshot per display is retained under the state dir, overwritten each run (`store_last_screenshot = false`
  keeps nothing).
- Skip: the model runs every interval, then the new summary is compared to the last written one; near-duplicates
  are not appended (below). Redaction and error lines are always written.
- Privacy: no app block-list. Every screen is captured and summarized; the model judges sensitivity and tags it,
  and when a sensitivity tag is present the summary is not stored and a `redacted` record is left (the model is
  the sole sensitivity judge — no regex layer). The protection goal is that no secret remains in the permanent
  Markdown; the screen reaching a local model is accepted because the model is local and screenshots are deleted
  right after analysis.

## Output structure

Append daily Markdown under `diary_root` at the path below. Default `diary_root` is this repo's `diary/`
(`config.toml` can change it; use an absolute path). One line per capture: `- HH:MM | status | summary`.
The summary is Korean; everything else is a fixed token.

```text
diary/YYYY/MM/YYYY-MM-DD.md
```

```markdown
## 2026-06-05

- 09:35 | OK | 코딩/개발 — 에디터와 터미널에서 작업 중.
- 09:45 | NOK | hidden (secret-detected)
- 09:50 | NOK | Ollama API call failed. Check that `ollama serve` is running. [connection-refused]
```

Each line is `time | status | summary`. The `summary` is one short activity label for calendar-style time
tracking (coding / research / docs / rest …), not a detailed transcription; the line is deliberately flat so
the day reads in one pass.

Status column: `OK` / `NOK`. The pipeline keeps four internal outcomes for control flow, mapped at write time:

- `analyzed` → **OK**: capture/summarize succeeded; the activity line is stored.
- `redacted` → **NOK**: the model flagged the screen as sensitive → content withheld; summary is `hidden (<tag>)`.
- `error` → **NOK**: pipeline failure (Ollama down, timeout, JSON parse failure, etc.). The summary is the diagnostic.
- `skip`: summary ~same as the last written one → no line is written (only an stderr log line).

`NOK` collapses redacted and error into one "needs-attention" flag; the `summary` field still tells them apart.

## Capture loop

1. The `LaunchAgent` runs the CLI every 5 minutes.
2. The CLI acquires a lock.
3. If the lock cannot be acquired, a previous run is still in progress → exit.
4. `screencapture -x` saves each display to a temp dir (shutter muted, non-frontmost monitors included).
5. The latest screenshot per display is refreshed in the state dir (`store_last_screenshot`).
6. `sips` downscales each display image (longest edge `resize_single`) to reduce model input cost and latency.
7. Each resized image is base64-encoded.
8. Stage 1 — one Ollama `/api/chat` call **per display** (single image), each returning
   `{category, detail, caution_tags}`. When the OCR helper is available, the display's real on-screen
   text (Apple Vision, from the full-resolution capture) is appended to the prompt so `detail` is
   grounded rather than guessed (§OCR grounding). The model stays warm between calls; the last call
   unloads it (`keep_alive`). A display whose response is unparseable is skipped; the run errors only
   if every display fails.
9. Stage 2 — the per-display findings are collapsed into the single dominant activity by one text-only call
   (`{category, detail}`); a single display skips this step. The line is composed as `category (detail)`.
10. Post-screening: if **any** display set a sensitivity caution tag (`secret-detected` / `possibly-sensitive`),
    the content is not stored and a `redacted` line is appended.
11. Skip check: if the new summary is essentially the same as the last written one, no line is written. (§skip)
12. Otherwise the summary is appended as one `analyzed` line and stored as the new "last summary".
13. Resized/encoded images and the per-run temp dir are deleted; the lock is released.

Deleting resized images, the temp dir, and any payload is guaranteed by a `finally` (regardless of
success/failure). Only the latest screenshot per display and the last summary persist between runs.

## Skip (duplicate summaries)

The goal is to not write redundant lines while the user stays on the same thing. The model runs every interval;
afterwards the new summary is compared to the **last written** summary with `difflib.SequenceMatcher.ratio()`
(stdlib). If the ratio is ≥ `similarity_threshold`, the line is skipped (`status: skip`, stderr only). The
"last summary" is updated only when a line is actually written, so the comparison anchors to what is already in
the log — duplicates are dropped, but slow drift eventually crosses the threshold and gets logged.

- State: `~/Library/Application Support/work-diary/prev/summary.txt` (last written summary) and
  `shot-<i>.png` (latest screenshot per display), mode `0o700`.
- The first run, and `redacted`/`error` outcomes, always write.
- Trade-off 1: text-ratio similarity is phrasing-sensitive — the same task reworded may fall below the
  threshold and log again, or trivially different work may read as a duplicate. Tune `similarity_threshold`
  to taste.
- Trade-off 2: keeping the latest screenshot relaxes the "volatile originals" rule (PRD §privacy). It is a
  single generation in the `0o700` state dir, overwritten each run, never under `diary_root`; set
  `store_last_screenshot = false` to keep nothing.

## Model request

Two stages, both built with the Python stdlib (`json`/`urllib`) via one `ollama_call(cfg, user_msg, schema,
keep_alive)` helper. Each model call sends **one** image (or none, for aggregation) so every screen gets the
model's full attention instead of N screens blended into one guess.

**Stage 1 — per display** (one call per screen):

```json
{
  "model": "gemma4:12b-it-qat",
  "stream": false,
  "keep_alive": "60s",
  "options": { "temperature": 0 },
  "format": { "type": "object",
    "properties": {
      "category": { "type": "string" },
      "detail": { "type": "string" },
      "caution_tags": { "type": "array", "items": { "type": "string" } } },
    "required": ["category", "detail", "caution_tags"] },
  "messages": [
    { "role": "system", "content": "You summarize screenshots into privacy-preserving work diary entries." },
    { "role": "user", "content": "<MONITOR_PROMPT: classify THIS one screen; see §prompt principles>",
      "images": ["<base64>"] }
  ]
}
```

**Stage 2 — aggregation** (text only, no images; skipped for a single display): same envelope with
`format` `{category, detail}` and a user message listing the per-display `category | detail` findings, asking
for the single dominant activity.

`keep_alive` is `"60s"` for the per-display calls so the model is not cold-loaded N+1 times; the **final** call
of the run uses `keep_alive: 0` to unload promptly (no idle RAM between 5-minute runs). The diary line is
composed in code as `category (detail)` (detail omitted when empty), so the format is uniform — the model no
longer chooses parens vs colon. `caution_tags` exists only to drive post-screening and is not printed;
redaction screens the **union** across displays. `"options": {"temperature": 0}` forces greedy decoding: the
gemma model defaults to `temperature=1`, which makes OCR/summary hallucinate and vary run to run (at temp 0,
top_p/top_k are moot). Setting `"format"` to a JSON schema forces schema-valid JSON output, reducing parse
failures. The payload is serialized by a JSON encoder, never by ad hoc string concatenation, since captured
screens may contain quotes, newlines, and control chars.

### Post-screening

The model is the sensitivity judge. Before storing the response as Markdown, check its `caution_tags`: if any
tag is in `block_tags` (`secret-detected` / `possibly-sensitive`), store no summary and leave a `redacted`
record. There is no regex layer — sensitivity is decided entirely by the model. Originals/resized images are
deleted on both paths. The tags that trigger redaction (`block_tags`) are configurable in `config.toml`.

Trade-off: this drops the deterministic guarantee a regex backstop would give. Redaction is only as reliable as
the model's judgment, so the prompt instructs it explicitly (§prompt principles) and `block_tags` can be tuned.

## Prompt principles

- **Stage 1 (`MONITOR_PROMPT`)** classifies ONE display per call. `category` is one of a fixed list
  (코딩/개발, 자료 조사, 문서·PPT 작성, 이메일·메신저, 회의·영상 시청, 디자인, 휴식·비업무); idle/locked/empty
  screens map to 휴식·비업무. `detail` is a brief Korean topic/app hint **only when clearly legible**, else an
  empty string. The model must NOT guess or invent file/project/library names, versions, URLs, or small text it
  cannot read. This keeps coarse-but-true entries instead of confident-but-wrong specifics: Ollama caps gemma
  vision at 896²/image (§image resize policy Known Issue), so small text is unreadable and asking for specifics
  only induces fabrication. One image per call gives each screen the full 896² budget and stops the displays
  blending into a single hallucinated guess.
- **Stage 2 (`AGG_PROMPT`)** is text-only: given the per-display `category | detail` findings, pick the single
  dominant work activity (idle/video/wallpaper/secondary screens lose to active work) and emit `{category,
  detail}`. It must not introduce any detail absent from the stage-1 findings.
- When OCR is available, `OCR_SECTION` is appended to the stage-1 prompt with the screen's real text and tells
  the model to ground `detail` in it rather than guess (§OCR grounding) — the same secret/privacy rules apply.
- The diary line is composed in code as `category (detail)` — the format is fixed, not chosen by the model.
- Do not transcribe passwords, verification codes, API tokens, private message contents, email bodies, or
  financial/medical/legal details into `detail` (this applies to OCR-sourced text too).
- If a screen looks sensitive, generalize and add `caution_tags: ["possibly-sensitive"]`.
- If a password/token/verification code is visible, add `caution_tags: ["secret-detected"]` — the signal that
  drives post-screening redaction. Redaction screens the union of every display's tags.
- Force JSON output via the `"format"` schema at both stages.

## Error handling

These conditions are recorded as `error` entries: Ollama not running, model not installed, API timeout, missing
Screen Recording permission, `screencapture` failure, `sips` resize failure, response not parseable as JSON.
Error entries record the cause, time, and a recovery hint — never a screenshot path or image data.

```markdown
- 10:05 | NOK | Ollama API call failed. Check that `ollama serve` is running. [connection-refused]
```

The bracketed token is the machine-readable reason code; the rest is the human-readable cause + recovery hint.

## Permission setup

macOS attributes Screen Recording to the **responsible process** — the program that invokes `screencapture`,
not `screencapture` itself. Manual runs inherit the terminal app's grant. The `LaunchAgent` runs under `launchd`,
whose responsible process is the **Python interpreter**, so that interpreter must be granted. A background agent
cannot show the consent prompt, so it is added manually: System Settings → Privacy & Security → Screen & System
Audio Recording → **+** → ⌘⇧G to paste the interpreter path (⌘⇧. toggles dot-folders) → enable → reload the agent.

`launchd`'s PATH lacks Homebrew, so a bare `#!/usr/bin/env python3` resolves to Apple's `/usr/bin/python3` (3.9,
no `tomllib`, ignores `config.toml`). `install.sh` therefore pins the agent's interpreter to the `python3` found
at install time (rendered into the plist's `ProgramArguments`). Input is screenshots only, so no Accessibility or
other permission is needed.

## LaunchAgent design

Placed at `~/Library/LaunchAgents/com.local.work-diary.plist`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>com.local.work-diary</string>
  <key>ProgramArguments</key>
  <array>
    <string>/opt/homebrew/opt/python@3.14/bin/python3.14</string>  <!-- pinned interpreter (install.sh fills the real path) -->
    <string>/Users/USER/.local/bin/work-diary-capture</string>
    <string>capture-once</string>
  </array>
  <key>StartInterval</key><integer>300</integer>
  <key>RunAtLoad</key><true/>
  <key>StandardOutPath</key><string>/Users/USER/Desktop/diary/logs/work-diary.out.log</string>
  <key>StandardErrorPath</key><string>/Users/USER/Desktop/diary/logs/work-diary.err.log</string>
</dict>
</plist>
```

Install and operations (status / stop / run-now) are in the [README](../README.md).

## Lock and timeout

- Lock path: `~/Library/Application Support/work-diary/capture.lock`.
- Lock method: atomic `mkdir` (flock is not available on macOS by default).
- Total run timeout: 360s (covers N per-display calls + 1 aggregation). Ollama API timeout: 180s per call.
- The run cold-loads the model once (~7.6GB), then keeps it warm (`keep_alive: "60s"`) across the per-display
  and aggregation calls; the final call unloads it (`keep_alive: 0`), so RAM is free between 5-minute runs.
- If one analysis exceeds the 5-minute interval, the next run does not start concurrently (lock).

## Image resize policy

- Per display: longest edge ≤ `resize_single` (1600px). Every model call is single-image, so there is no
  separate multi-monitor size — the legacy `resize_multi` key is removed (unknown keys are ignored).
- If average processing time approaches 5 minutes, lower the longest edge, reduce `max_displays`, or lengthen
  the interval — per-display calls run sequentially, so total time scales with the display count.

Known Issue — Ollama caps gemma3 vision at a fixed 896×896 per image (256 tokens); it does **not**
implement pan-and-scan tiling ([ollama#10392](https://github.com/ollama/ollama/issues/10392),
[multimodal](https://deepwiki.com/ollama/ollama/7.3-multimodal-and-vision-support)). So raising the resize
longest edge above ~896px buys no extra detail — each full screen is squashed to 896², destroying small text,
which is the dominant cause of wrong OCR/summaries. Sending one screen per call (rather than all displays in
one request) does not lift the 896² cap, but it gives each screen the full budget and stops displays blending
into one fabricated guess. Exact small text is recovered separately by on-device OCR (§OCR grounding), which
is not subject to the 896² cap.

## OCR grounding

The 896²/image cap means the vision model cannot read small text, so it would otherwise invent specifics. To
recover real text, a tiny native helper (`ocr/work-diary-ocr.swift`, Apple Vision `VNRecognizeTextRequest`,
`.accurate`, `ko-KR`+`en-US`) runs on the **full-resolution** capture — Vision is not capped at 896². It is a
separate process invoked like `screencapture`/`sips`, so the Python CLI stays stdlib-only (no pyobjc). It reads
an image **file**, not the screen, so it needs no Screen Recording permission. `scripts/install.sh` builds it
to `~/.local/bin/work-diary-ocr`; the CLI resolves it next to itself, then on `PATH`.

- Output: a JSON array `[{"t": text, "h": normalized-box-height, "c": confidence}]`, one entry per text
  observation. The CLI ranks by `h` (taller box = larger font), de-dupes, and passes the top `ocr_max_lines`
  to the stage-1 prompt (`OCR_SECTION`). Largest-font-first favours titles/app/tab names — high signal — and
  naturally down-weights dense body text, which limits how much sensitive content reaches the model.
- The prompt tells the model to ground `category`/`detail` in the OCR text but **not** to copy
  passwords/tokens/codes or private message/email bodies, and to set `caution_tags` as usual; redaction is
  unchanged. OCR text is transient (never written to disk), like the screenshots.
- Best-effort: a missing helper (no `swiftc` at install) or any OCR failure degrades to vision-only. Toggle
  with `use_ocr`; tune `ocr_languages` / `ocr_max_lines` / `ocr_timeout` / `ocr_helper` in `config.toml`.
- Cost: one extra subprocess per display per run; Vision OCR on a single screen is sub-second. Measured input for a 2-display capture is ~770 tokens
(≈ prompt + 256×images), far below Ollama's default `num_ctx` of 4096, so there is no context truncation and
raising `num_ctx` does nothing. Not pursued: more detail would require a different model (a dynamic-resolution
document VLM) or manual pan-and-scan tiling — the decision is to keep gemma4 and ask only for coarse activity.

## Install verification

Automated by `scripts/verify.sh` (pre-release blocker):

```bash
ollama --version
ollama pull gemma4:12b-it-qat
ollama list | grep gemma4:12b-it-qat
```

Sample vision call:

```bash
IMG=$(base64 < /tmp/test.jpg | tr -d '\n')
curl -sS -X POST http://localhost:11434/api/chat \
  -H "Content-Type: application/json" \
  -d '{"model":"gemma4:12b-it-qat","stream":false,
       "messages":[{"role":"user","content":"What is in this image? Be concise.","images":["'"$IMG"'"]}]}'
```

Success: HTTP 200, response JSON contains `message.content`, and no sustained memory pressure.

## Performance verification

For single- and multi-monitor, measure: `screencapture`, `sips` resize, base64 encode, model cold load
(`keep_alive: 0` makes it per-run), Ollama inference (excluding load), Markdown append, and total run time.

Targets:

- Average total run time stays within the 5-minute interval.
- p95 total run time (cold load included) ≤ 240s (and the cold load alone must not exceed the 180s API timeout).
- No sustained memory pressure increase (Activity Monitor or `vm_stat`).
- If multi-monitor runs time out repeatedly, raise the interval to 10 minutes or lower the resize limit.

## Functional verification

- A normal capture appends one `OK` line (`time | OK | <short Korean activity summary>`).
- A second run on the same task (near-duplicate summary) writes no line (`status: skip`, stderr only).
- A run after switching tasks (different summary) appends a new line.
- A screen showing a token/password yields a `NOK` line (`hidden (...)`, not the secret).
- A secret visible on a non-frontmost monitor is also redacted (`NOK`).
- With Ollama stopped, a `NOK` line is produced (Ollama unavailable).
- With the model not installed, a `NOK` line with a recovery hint is produced.
- After a successful analysis, only the latest screenshot per display + `summary.txt` remain under the state
  dir; the per-run temp dir is gone.
- After a timeout, the lock is released.
- Without Screen Recording permission, an error is recorded and no per-run image files remain.

## Operational cautions

- Defaults stay conservative because the tool handles the user's screen.
- Captured images and any payload are excluded from logs, crash dumps, and debug output; request bodies must not
  leak into `StandardOutPath`/`StandardErrorPath`.
- Keep the diary storage location somewhere the user clearly understands for backup/sync.
- Do not default to an auto-sync path (iCloud Drive, Dropbox, Git repo).
- Known Issue: the default `diary_root` (`~/Desktop/diary/diary`) is auto-synced if macOS "Desktop & Documents"
  iCloud is on, conflicting with the above. Turn it off or move `diary_root` to a non-synced path.
- Shared-screen / video-call / remote-desktop screens go through the same post-screening as any other.
  Known Issue: screening relies on the model's judgment, so it may miss sensitive content or over-redact —
  strengthen the prompt or add tags to `block_tags` if needed.

## References

- Google, "Introducing Gemma 4 12B": https://blog.google/innovation-and-ai/technology/developers-tools/introducing-gemma-4-12b/
- Ollama model registry, `gemma4:12b-it-qat`: https://registry.ollama.com/library/gemma4%3A12b-it-qat
- Ollama Vision documentation: https://docs.ollama.com/capabilities/vision
