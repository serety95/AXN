#!/usr/bin/env bash
# AXN PostToolUse Hook: auto-verify-loop.sh
# Runs scoped syntax/lint/type checks on the modified file and feeds errors
# back via stderr + exit 2 so the agent self-heals in the same turn.
# Exit 0 = clean or no applicable checker, Exit 2 = verification failed.

set -euo pipefail

MAX_BYTES="${AXN_HOOK_MAX_BYTES:-1048576}"

read_bounded_stdin() {
  if command -v python3 >/dev/null 2>&1; then
    python3 -c '
import sys
max_b = int(sys.argv[1])
data = sys.stdin.buffer.read(max_b + 1)
if len(data) > max_b:
    sys.exit(42)
sys.stdout.buffer.write(data)
' "$MAX_BYTES"
  elif command -v python >/dev/null 2>&1; then
    python -c '
import sys
max_b = int(sys.argv[1])
data = sys.stdin.buffer.read(max_b + 1)
if len(data) > max_b:
    sys.exit(42)
sys.stdout.buffer.write(data)
' "$MAX_BYTES"
  elif command -v node >/dev/null 2>&1; then
    node -e '
const fs = require("fs");
const maxB = Number(process.argv[1]);
const buf = fs.readFileSync(0);
if (buf.length > maxB) process.exit(42);
process.stdout.write(buf);
' "$MAX_BYTES"
  else
    local chunk
    chunk="$(head -c $((MAX_BYTES + 1)))"
    [ "${#chunk}" -le "$MAX_BYTES" ] || return 42
    printf '%s' "$chunk"
  fi
}

PAYLOAD=""
if ! PAYLOAD="$(read_bounded_stdin)"; then
  printf '[AXN auto-verify-loop] Hook input exceeded %s bytes.\n' "$MAX_BYTES" >&2
  exit 2
fi

[ -z "${PAYLOAD//[[:space:]]/}" ] && exit 0

extract_file_path() {
  if command -v jq >/dev/null 2>&1; then
    printf '%s' "$PAYLOAD" | jq -r '(.tool_input.file_path // .tool_input.path // .toolInput.file_path // .toolInput.path // "")'
  elif command -v python3 >/dev/null 2>&1 || command -v python >/dev/null 2>&1; then
    local py_bin="python3"
    command -v python3 >/dev/null 2>&1 || py_bin="python"
    printf '%s' "$PAYLOAD" | "$py_bin" -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(0)
ti = (d.get("tool_input") or d.get("toolInput") or {}) if isinstance(d, dict) else {}
print(str(ti.get("file_path") or ti.get("path") or "") if isinstance(ti, dict) else "")
'
  elif command -v node >/dev/null 2>&1; then
    printf '%s' "$PAYLOAD" | node -e '
const fs = require("fs");
try {
  const d = JSON.parse(fs.readFileSync(0, "utf8"));
  const ti = (d && (d.tool_input || d.toolInput)) || {};
  console.log(String(ti.file_path || ti.path || ""));
} catch {}
'
  fi
}

FILE_PATH="$(extract_file_path)"
[ -z "$FILE_PATH" ] && exit 0
[ ! -f "$FILE_PATH" ] && exit 0

BASE_STRIKE_DIR="${AXN_STRIKE_DIR:-${TMPDIR:-/tmp}/axn-strikes}"
REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
REPO_KEY="$(printf '%s' "$REPO_ROOT" | cksum | awk '{print $1"-"$2}')"
STRIKE_DIR="${BASE_STRIKE_DIR}/${REPO_KEY}"
MAX_RETRIES="${AXN_MAX_RETRIES_BEFORE_ESCALATION:-2}"
STRIKE_KEY="$(printf '%s' "auto-verify:$FILE_PATH" | cksum | awk '{print $1"-"$2}')"
STRIKE_FILE="${STRIKE_DIR}/${STRIKE_KEY}.count"
TURN_STATE_FILE="${STRIKE_DIR}/turn-state.json"

update_turn_state() {
  local seen_count="$1"
  local py_bin=""
  if command -v python3 >/dev/null 2>&1; then
    py_bin="python3"
  elif command -v python >/dev/null 2>&1; then
    py_bin="python"
  fi
  if [ -n "$py_bin" ]; then
    AXN_TURN_STATE="$TURN_STATE_FILE" AXN_SEEN="$seen_count" "$py_bin" -c '
import json, os
fp = os.environ["AXN_TURN_STATE"]
seen = int(os.environ.get("AXN_SEEN", "0"))
if os.path.islink(fp):
    os.unlink(fp)
data = {}
if os.path.isfile(fp):
    try:
        data = json.load(open(fp, "r", encoding="utf-8"))
        if not isinstance(data, dict):
            data = {}
    except Exception:
        data = {}
prev = data.get("max_strikes_seen", 0)
if not isinstance(prev, int):
    prev = 0
data["max_strikes_seen"] = max(prev, seen)
with open(fp, "w", encoding="utf-8") as f:
    json.dump(data, f, separators=(",", ":"))
' 2>/dev/null || true
  fi
}

clear_strikes() {
  [ -f "$STRIKE_FILE" ] && rm -f "$STRIKE_FILE" 2>/dev/null || true
}

record_strike() {
  local label="$1"
  mkdir -p "$STRIKE_DIR" 2>/dev/null || return 0
  [ -L "$STRIKE_DIR" ] && return 0
  [ -L "$STRIKE_FILE" ] && rm -f "$STRIKE_FILE" 2>/dev/null || true
  local count=0
  if [ -f "$STRIKE_FILE" ]; then
    local raw
    raw="$(cat "$STRIKE_FILE" 2>/dev/null || echo "0")"
    case "$raw" in
      ''|*[!0-9]*) count=0 ;;
      *) count="$raw" ;;
    esac
  fi
  count=$((count + 1))
  printf '%s' "$count" > "$STRIKE_FILE" 2>/dev/null || true
  update_turn_state "$count"
  if [ "$count" -ge "$MAX_RETRIES" ]; then
    printf '[AXN cost-routing] 2-STRIKE ESCALATION HINT (strike %s/%s on %s [%s]): Per config/cost-tiers.yaml, bump reasoning effort first (low -> medium -> high) or escalate T2_builder -> T3_architect.\n' \
      "$count" "$MAX_RETRIES" "$FILE_PATH" "$label" >&2
  fi
}

run_check() {
  local label="$1"
  shift
  local out=""
  if ! out="$("$@" 2>&1)"; then
    printf '[AXN auto-verify-loop] %s failed for %s:\n%s\n' "$label" "$FILE_PATH" "$out" >&2
    record_strike "$label"
    exit 2
  fi
}

case "$FILE_PATH" in
  *.sh|*.bash)
    run_check "bash -n" bash -n "$FILE_PATH"
    if command -v shellcheck >/dev/null 2>&1; then
      run_check "shellcheck" shellcheck -S warning "$FILE_PATH"
    fi
    ;;
  *.py)
    if command -v ruff >/dev/null 2>&1; then
      run_check "ruff check" ruff check "$FILE_PATH"
    elif command -v python3 >/dev/null 2>&1; then
      run_check "py_compile" python3 -m py_compile "$FILE_PATH"
    elif command -v python >/dev/null 2>&1; then
      run_check "py_compile" python -m py_compile "$FILE_PATH"
    fi
    ;;
  *.ts|*.tsx|*.js|*.jsx|*.mjs|*.cjs)
    if [ -f "biome.json" ] || [ -f "biome.jsonc" ]; then
      if command -v npx >/dev/null 2>&1; then
        run_check "biome check" npx --no-install biome check "$FILE_PATH"
      fi
    fi
    if [[ "$FILE_PATH" == *.ts || "$FILE_PATH" == *.tsx ]] && [ -f "tsconfig.json" ]; then
      if [ -x "./node_modules/.bin/tsc" ]; then
        run_check "tsc --noEmit" ./node_modules/.bin/tsc --noEmit
      fi
    fi
    ;;
  *.rs)
    if [ -f "Cargo.toml" ] && command -v cargo >/dev/null 2>&1; then
      run_check "cargo check" cargo check --quiet
    fi
    ;;
  *.go)
    if [ -f "go.mod" ] && command -v go >/dev/null 2>&1; then
      run_check "go vet" go vet ./...
    fi
    ;;
esac

clear_strikes
exit 0
