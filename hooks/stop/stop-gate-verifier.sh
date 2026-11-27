#!/usr/bin/env bash
# AXN Stop Hook: stop-gate-verifier.sh
# Runs the repository's .ai/verify.cmd before allowing the agent to finish.
# Respects stop_hook_active=true to prevent infinite retry loops.
# Exit 0 = verified (or no .ai/verify.cmd), Exit 2 = verification failed.

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
  printf '[AXN stop-gate-verifier] Hook input exceeded %s bytes.\n' "$MAX_BYTES" >&2
  exit 2
fi

# Prevent infinite loop if a stop hook already triggered a retry
if [ -n "${PAYLOAD//[[:space:]]/}" ]; then
  STOP_ACTIVE="false"
  if command -v jq >/dev/null 2>&1; then
    STOP_ACTIVE="$(printf '%s' "$PAYLOAD" | jq -r '(.stop_hook_active // false) | tostring')"
  elif command -v python3 >/dev/null 2>&1 || command -v python >/dev/null 2>&1; then
    local_py="python3"
    command -v python3 >/dev/null 2>&1 || local_py="python"
    STOP_ACTIVE="$(printf '%s' "$PAYLOAD" | "$local_py" -c '
import json, sys
try:
    d = json.load(sys.stdin)
    print("true" if isinstance(d, dict) and d.get("stop_hook_active") is True else "false")
except Exception:
    print("false")
')"
  elif command -v node >/dev/null 2>&1; then
    STOP_ACTIVE="$(printf '%s' "$PAYLOAD" | node -e '
const fs = require("fs");
try {
  const d = JSON.parse(fs.readFileSync(0, "utf8"));
  console.log(d && d.stop_hook_active === true ? "true" : "false");
} catch { console.log("false"); }
')"
  fi

  if [ "$STOP_ACTIVE" = "true" ]; then
    exit 0
  fi
fi

# Locate repo root
REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
VERIFY_FILE="${REPO_ROOT}/.ai/verify.cmd"

if [ ! -f "$VERIFY_FILE" ]; then
  exit 0
fi

# Security: reject symlinks pointing outside repo root
if [ -L "$VERIFY_FILE" ]; then
  printf '[AXN stop-gate-verifier] BLOCKED: .ai/verify.cmd must not be a symlink.\n' >&2
  exit 2
fi

# Extract first non-empty, non-comment line
VERIFY_CMD=""
while IFS= read -r line || [ -n "$line" ]; do
  # Strip CR if CRLF
  line="${line%$'\r'}"
  # Skip blank lines and comments
  case "$line" in
    ""|"#"*) continue ;;
  esac
  VERIFY_CMD="$line"
  break
done < "$VERIFY_FILE"

if [ -z "$VERIFY_CMD" ]; then
  exit 0
fi

# Run inside repo root
OUT=""
if ! OUT="$(cd "$REPO_ROOT" && bash -c "$VERIFY_CMD" 2>&1)"; then
  printf '[AXN stop-gate-verifier] Verification failed (%s):\n%s\n' "$VERIFY_CMD" "$OUT" >&2
  exit 2
fi

exit 0
