#!/usr/bin/env bash
# work-diary install: place the CLI in ~/.local/bin and register the LaunchAgent.
# design §LaunchAgent / §permission setup.
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN_DIR="$HOME/.local/bin"
BIN="$BIN_DIR/work-diary-capture"
CFG_DIR="$HOME/.config/work-diary"
# Keep logs inside the repo so every artifact (code, config, diary, logs) lives in
# one place — no orphaned files under ~/Library/Logs.
LOG_DIR="$REPO/logs"
OUT_LOG="$LOG_DIR/work-diary.out.log"
ERR_LOG="$LOG_DIR/work-diary.err.log"
LA_DIR="$HOME/Library/LaunchAgents"
PLIST="$LA_DIR/com.local.work-diary.plist"
LABEL="com.local.work-diary"

# Pin the interpreter. launchd's PATH lacks Homebrew, so a bare `env python3`
# would resolve to Apple's /usr/bin/python3 (3.9, no tomllib). Bake the real
# python3 found now into the plist; it is also the Screen Recording grant target.
PY="$(command -v python3 || true)"
[[ -n "$PY" ]] || { echo "python3 not found on PATH" >&2; exit 1; }
PY="$("$PY" -c 'import sys; print(sys.executable)' 2>/dev/null || echo "$PY")"

echo "==> Install CLI: $BIN"
mkdir -p "$BIN_DIR"
install -m 0755 "$REPO/work-diary-capture" "$BIN"

echo "==> Build OCR helper: $BIN_DIR/work-diary-ocr"
if command -v swiftc >/dev/null 2>&1; then
  if swiftc -O -o "$BIN_DIR/work-diary-ocr" "$REPO/ocr/work-diary-ocr.swift"; then
    echo "    Built (on-device OCR grounds the summary in real on-screen text)"
  else
    echo "    swiftc build failed — OCR disabled (vision-only); the CLI still runs." >&2
  fi
else
  echo "    swiftc not found — OCR disabled (vision-only). Install Xcode CLT: xcode-select --install"
fi

echo "==> Config file"
mkdir -p "$CFG_DIR"
if [[ -f "$CFG_DIR/config.toml" ]]; then
  echo "    Already exists: $CFG_DIR/config.toml (kept)"
else
  cp "$REPO/config/config.toml.example" "$CFG_DIR/config.toml"
  echo "    Created: $CFG_DIR/config.toml (edit diary_root/model if needed)"
fi

echo "==> Log directory: $LOG_DIR"
mkdir -p "$LOG_DIR"

echo "==> Render LaunchAgent: $PLIST"
mkdir -p "$LA_DIR"
sed -e "s|__PY__|$PY|g" \
    -e "s|__BIN__|$BIN|g" \
    -e "s|__OUT__|$OUT_LOG|g" \
    -e "s|__ERR__|$ERR_LOG|g" \
    "$REPO/launchagent/com.local.work-diary.plist.template" > "$PLIST"

echo "==> Register LaunchAgent"
launchctl bootout "gui/$(id -u)" "$PLIST" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$PLIST"
launchctl print "gui/$(id -u)/$LABEL" >/dev/null && echo "    Registered"

cat <<EOF

────────────────────────────────────────────────────────────────────
One manual step is required (design §permission setup):

macOS attributes Screen Recording to the responsible process — the interpreter
that runs the script, not screencapture. The agent runs under launchd, so grant
the pinned interpreter (a background agent cannot show the consent prompt):

1) System Settings → Privacy & Security → Screen & System Audio Recording
2) Click +, press Cmd-Shift-G (Go to Folder), paste this path, then enable it:
       $PY
   (For dot-folders like ~/.local/bin, Cmd-Shift-. toggles hidden items.)
3) Reapply, then trigger one run to verify:
     launchctl bootout   gui/$(id -u) "$PLIST"
     launchctl bootstrap gui/$(id -u) "$PLIST"
     launchctl kickstart -k gui/$(id -u)/$LABEL

Operations:
  status:  launchctl print gui/$(id -u)/$LABEL
  stop:    launchctl bootout gui/$(id -u) "$PLIST"
  run now: launchctl kickstart -k gui/$(id -u)/$LABEL   # exercises the agent path
  logs:    $OUT_LOG / $ERR_LOG

First run ./scripts/verify.sh to validate Ollama and the model.
────────────────────────────────────────────────────────────────────
EOF
