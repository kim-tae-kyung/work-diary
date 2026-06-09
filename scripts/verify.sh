#!/usr/bin/env bash
# Validate the Ollama install, model, and a vision call (design §install verification).
# This check is a pre-release blocker.
set -uo pipefail

CFG="${WORK_DIARY_CONFIG:-$HOME/.config/work-diary/config.toml}"
MODEL="${MODEL:-}"
if [[ -z "$MODEL" && -f "$CFG" ]]; then
  MODEL="$(grep -E '^[[:space:]]*model[[:space:]]*=' "$CFG" | head -1 | sed -E 's/.*"([^"]*)".*/\1/')"
fi
MODEL="${MODEL:-gemma4:12b-it-qat}"
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

echo "==> OCR helper build + smoke test (optional; grounds detail in real on-screen text)"
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if command -v swiftc >/dev/null 2>&1; then
  OCR_BIN="$(mktemp -t work-diary-ocr-XXXX)"
  trap 'rm -f "$TMP_IMG" "$PAYLOAD" "$OCR_BIN"' EXIT
  if swiftc -O -o "$OCR_BIN" "$REPO_DIR/ocr/work-diary-ocr.swift" 2>/dev/null; then
    if "$OCR_BIN" --lang ko-KR,en-US "$TMP_IMG" | jq -e 'type == "array"' >/dev/null 2>&1; then
      echo "PASS: OCR helper builds and returns a JSON array."
    else
      echo "WARN: OCR helper built but returned no JSON array — OCR will be skipped at runtime."
    fi
  else
    echo "WARN: OCR helper failed to build — the diary runs vision-only."
  fi
else
  echo "SKIP: swiftc not found — OCR disabled (vision-only). Install Xcode CLT: xcode-select --install"
fi
echo
echo "Performance note (design §performance verification): separately measure that the total"
echo "run time including the keep_alive:0 cold load stays within the 5-minute interval and p95 ≤ 240s."
