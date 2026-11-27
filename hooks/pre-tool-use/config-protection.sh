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

extract_bounded_file_path() {
  if command -v jq >/dev/null 2>&1; then
    local payload
    payload="$(head -c $((MAX_BYTES + 1)))"
    [ "${#payload}" -le "$MAX_BYTES" ] || return 42
    [ -z "${payload//[[:space:]]/}" ] && return 0
    printf '%s' "$payload" | jq -r '(.tool_input.file_path // .tool_input.path // .tool_input.TargetFile // .tool_input.Path // .toolInput.file_path // .toolInput.path // .toolInput.TargetFile // .toolInput.Path // "")' || return 2
  elif command -v python3 >/dev/null 2>&1 || command -v python >/dev/null 2>&1; then
    local py_bin="python3"
    command -v python3 >/dev/null 2>&1 || py_bin="python"
    "$py_bin" -c '
import json, sys
max_b = int(sys.argv[1])
data = sys.stdin.buffer.read(max_b + 1)
if len(data) > max_b:
    sys.exit(42)
text = data.decode("utf-8", errors="replace").strip()
if not text:
    sys.exit(0)
try:
    d = json.loads(text)
except Exception:
    sys.exit(2)
ti = (d.get("tool_input") or d.get("toolInput") or {}) if isinstance(d, dict) else {}
print(str(ti.get("file_path") or ti.get("path") or ti.get("TargetFile") or ti.get("Path") or "") if isinstance(ti, dict) else "")
' "$MAX_BYTES"
  elif command -v node >/dev/null 2>&1; then
    node -e '
const fs = require("fs");
const maxB = Number(process.argv[1]);
const buf = fs.readFileSync(0);
if (buf.length > maxB) process.exit(42);
const text = buf.toString("utf8").trim();
if (!text) process.exit(0);
let d;
try { d = JSON.parse(text); } catch { process.exit(2); }
const ti = (d && (d.tool_input || d.toolInput)) || {};
console.log(String(ti.file_path || ti.path || ti.TargetFile || ti.Path || ""));
' "$MAX_BYTES"
  else
    block "No JSON parser available."
  fi
}

FILE_PATH=""
RC=0
FILE_PATH="$(extract_bounded_file_path)" || RC=$?
if [ "$RC" -eq 42 ]; then
  block "Hook input exceeded ${MAX_BYTES} bytes (fail-closed)."
elif [ "$RC" -ne 0 ]; then
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
