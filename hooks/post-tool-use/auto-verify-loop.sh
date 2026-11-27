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

run_check() {
  local label="$1"
  shift
  local out=""
  if ! out="$("$@" 2>&1)"; then
    printf '[AXN auto-verify-loop] %s failed for %s:\n%s\n' "$label" "$FILE_PATH" "$out" >&2
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

exit 0
