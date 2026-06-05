#!/usr/bin/env bash
# Validate the Ollama install, model, and a vision call (design §install verification).
# This check is a pre-release blocker.
set -uo pipefail

CFG="${WORK_DIARY_CONFIG:-$HOME/.config/work-diary/config.toml}"
MODEL="${MODEL:-}"
if [[ -z "$MODEL" && -f "$CFG" ]]; then
  MODEL="$(grep -E '^[[:space:]]*model[[:space:]]*=' "$CFG" | head -1 | sed -E 's/.*"([^"]*)".*/\1/')"
fi
MODEL="${MODEL:-gemma4:12b}"
OLLAMA_URL="${OLLAMA_URL:-http://localhost:11434}"

fail() { echo "FAIL: $*" >&2; exit 1; }

echo "==> Model: $MODEL"

command -v ollama >/dev/null 2>&1 || fail "ollama not installed. Install from https://ollama.com/download"
echo "==> ollama --version"; ollama --version || fail "ollama cannot run"

echo "==> ollama pull $MODEL (download if missing)"
ollama pull "$MODEL" || fail "model pull failed. Check the tag exists in the registry: $MODEL"

echo "==> ollama list check"
ollama list | grep -F "$MODEL" >/dev/null || fail "$MODEL not in list"

echo "==> Sample vision call (design §install verification)"
TMP_IMG="$(mktemp -t work-diary-test).jpg"
trap 'rm -f "$TMP_IMG"' EXIT
curl -fsSL -o "$TMP_IMG" \
  "https://upload.wikimedia.org/wikipedia/commons/3/3a/Cat03.jpg" \
  || fail "sample image download failed (network)"

IMG="$(base64 < "$TMP_IMG" | tr -d '\n')"
PAYLOAD="$(mktemp -t work-diary-payload)"
trap 'rm -f "$TMP_IMG" "$PAYLOAD"' EXIT
jq -n --arg model "$MODEL" --arg img "$IMG" '{
  model: $model, stream: false,
  messages: [{role:"user", content:"What is in this image? Be concise.", images:[$img]}]
}' > "$PAYLOAD"

RESP="$(curl -sS -X POST "$OLLAMA_URL/api/chat" \
  -H "Content-Type: application/json" --data @"$PAYLOAD")" \
  || fail "vision call failed. Check that ollama serve is running."

echo "$RESP" | jq -e '.message.content | length > 0' >/dev/null \
  || fail "no message.content in response: $(echo "$RESP" | head -c 200)"

echo "PASS: response contains message.content."
echo "    content: $(echo "$RESP" | jq -r '.message.content' | head -c 120)"
echo
echo "Performance note (design §performance verification): separately measure that the total"
echo "run time including the keep_alive:0 cold load stays within the 5-minute interval and p95 ≤ 240s."
