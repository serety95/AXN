#!/usr/bin/env bash
# AXN PreToolUse Hook: config-protection.sh
# Blocks modifications to existing linter, formatter, and ignore configuration files
# so agents fix code issues rather than weakening checks.
# Allows first-time creation when the target file does not yet exist.
# Override intentionally with AXN_ALLOW_CONFIG_EDIT=1.
# Exit 0 = allow, Exit 2 = hard block.

set -euo pipefail

if [ "${AXN_ALLOW_CONFIG_EDIT:-0}" = "1" ]; then
  exit 0
fi

MAX_BYTES="${AXN_HOOK_MAX_BYTES:-1048576}"

block() {
  printf '[AXN config-protection] BLOCKED: %s\n' "$1" >&2
  exit 2
}

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
  block "Hook input exceeded ${MAX_BYTES} bytes (fail-closed)."
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
    sys.exit(2)
ti = (d.get("tool_input") or d.get("toolInput") or {}) if isinstance(d, dict) else {}
print(str(ti.get("file_path") or ti.get("path") or "") if isinstance(ti, dict) else "")
'
  elif command -v node >/dev/null 2>&1; then
    printf '%s' "$PAYLOAD" | node -e '
const fs = require("fs");
let d;
try { d = JSON.parse(fs.readFileSync(0, "utf8")); } catch { process.exit(2); }
const ti = (d && (d.tool_input || d.toolInput)) || {};
console.log(String(ti.file_path || ti.path || ""));
'
  else
    block "No JSON parser available."
  fi
}

FILE_PATH=""
if ! FILE_PATH="$(extract_file_path)"; then
  block "Malformed JSON payload on stdin (fail-closed)."
fi

[ -z "$FILE_PATH" ] && exit 0

BASE="$(basename "$FILE_PATH")"

is_protected_config=0
case "$BASE" in
  .eslintrc|.eslintrc.*|eslint.config.*|.eslintignore|\
  .prettierrc|.prettierrc.*|prettier.config.*|.prettierignore|\
  biome.json|biome.jsonc|\
  ruff.toml|.ruff.toml|.flake8|.pylintrc|\
  .stylelintrc|.stylelintrc.*|\
  .shellcheckrc|.markdownlint*|.editorconfig|\
  verify.cmd)
    is_protected_config=1
    ;;
esac

if [ "$is_protected_config" -eq 1 ] && [ -e "$FILE_PATH" ]; then
  block "Editing existing linter/formatter config '$BASE' is blocked. Fix the code instead of weakening checks (or set AXN_ALLOW_CONFIG_EDIT=1 if intentional)."
fi

exit 0
