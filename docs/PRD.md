# Local Work Diary — PRD

One-line summary: on macOS, automatically record the day's work without user intervention, preserving
privacy, to enable daily/weekly/monthly reflection.

This doc covers *what/why*. For *how* (architecture/implementation/verification) see [design.md](./design.md).

## Problem

- At the end of the day it is hard to recall exactly where time went. There is no basis for reflection,
  weekly reports, or focus review.
- Manual logging (timesheets, notes) has too much friction to sustain.
- Cloud time-tracking / screenshot tools that automate this send screen content off-device, a privacy concern
  that makes them unusable in sensitive work environments.

## Goals

- Record work automatically without user intervention.
- Keep all processing local so screens/screenshots never leave the device.
- Keep secrets (passwords, tokens, verification codes, etc.) out of the permanent record.
- Keep the record human-readable, owned, and portable by the user.

## Non-goals

- Team sharing, collaboration, central aggregation.
- Cloud sync or SaaS.
- Automated timesheets, billing, productivity scoring. Each line is one short activity label for calendar-style
  time tracking, not a detailed transcription; this tool computes no durations or scores itself.
- Keylogging / input tracking or any off-screen activity collection.
- Real-time notifications / coaching.

## Target user

- A single individual working on macOS (Apple Silicon) — developer / knowledge worker.
- Privacy-sensitive, prefers local-first.
- Wants to quickly reconstruct "what did I do today" for self-reflection / weekly reports.

## Requirements

Priority: MUST (v1) / SHOULD.

- R1 (MUST): periodically capture and summarize the current task into a record.
- R2 (MUST): every step (capture, summarize, store) runs locally. Screen data is never transmitted.
- R3 (MUST): on secret detection before storage, redact the entry so no secret string remains in the
  permanent Markdown record.
- R4 (MUST): output is human-readable and the user controls its location/backup/sync.
- R5 (MUST): failures (model down, missing permission, etc.) are recorded rather than disappearing silently,
  so they are recoverable.
- R6 (SHOULD): background execution does not degrade the user's perceived performance.

## Privacy requirements (core differentiator)

- Single local processing: screens, screenshots, and intermediates never leave the device.
- Volatile originals: per-run screenshots and intermediate images are deleted right after analysis. The only
  permanent artifact is the summary text. Exception: the latest screenshot per display is retained in the
  `0o700` state dir, overwritten each run; `store_last_screenshot = false` keeps nothing.
- No secret logging: passwords, tokens, verification codes, etc. are not kept in the permanent record; on
  detection the entry is redacted.
- User ownership: the user can read, move, and fully delete the record. No auto cloud-sync path is used as a
  default.
- Known Issue: sensitivity detection relies on the local model's judgment, so it may miss some sensitive
  content or over-redact. Strengthen the prompt or redaction tags if needed.

## Success metrics

- Auto-record rate: fraction of active work time where capture/summarize succeeded and was recorded.
- Reflection usefulness: can the user accurately reconstruct the day from the record alone (subjective).
- Privacy hit: number of secrets left in the permanent record = 0.
- Non-intrusiveness: no sustained memory pressure / perceived slowdown from background execution.
- Durability: how long the user keeps the tool running without turning it off.

## Assumptions and constraints

- Target environment: Apple Silicon Mac, 16GB unified memory, capable of running a local LLM.
- macOS screen capture requires Screen Recording permission (user allows once).
- Input is screen screenshots only. No OS metadata (frontmost app, window titles) is collected, and no
  permission beyond Screen Recording is needed.
- Local inference cost/latency constrains the capture interval.
- Single user, single device. Multi-device aggregation is out of scope.

## Scope

- v1: automatic capture/summarize/daily-record, local processing, secret screening, error logging.
- Later (not implemented): weekly/monthly reflection generation, search/aggregation.

## Open questions

- How far to generalize/redact non-secret but sensitive context.
- Default storage path and how to guide the user.
- Interval/resolution defaults that stay non-intrusive on multi-monitor / high-DPI setups.
