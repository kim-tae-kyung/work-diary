#!/usr/bin/env bash
# work-diary uninstall: unload the LaunchAgent and remove the CLI binary.
# Leaves Ollama, the model, your config, logs, and diary data untouched.
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN="$HOME/.local/bin/work-diary-capture"
PLIST="$HOME/Library/LaunchAgents/com.local.work-diary.plist"
LABEL="com.local.work-diary"

echo "==> Unload LaunchAgent: $LABEL"
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null \
  && echo "    Unloaded" || echo "    Not loaded (skipped)"

echo "==> Remove LaunchAgent plist: $PLIST"
rm -f "$PLIST"

echo "==> Remove CLI: $BIN"
rm -f "$BIN"

cat <<EOF

Done. Removed the LaunchAgent and the CLI binary.

Left in place (remove manually if you want):
  config:  $HOME/.config/work-diary/config.toml
  logs:    $REPO/logs/work-diary.out.log / work-diary.err.log   (inside the repo)
  state:   $HOME/Library/Application Support/work-diary/   (lock + tmp)
  diary:   your diary_root (personal records — kept on purpose)

Ollama and the model are left installed.
EOF
