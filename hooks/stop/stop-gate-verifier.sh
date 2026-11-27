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

BASE_STRIKE_DIR="${AXN_STRIKE_DIR:-${TMPDIR:-/tmp}/axn-strikes}"
REPO_KEY="$(printf '%s' "$REPO_ROOT" | cksum | awk '{print $1"-"$2}')"
STRIKE_DIR="${BASE_STRIKE_DIR}/${REPO_KEY}"
MAX_RETRIES="${AXN_MAX_RETRIES_BEFORE_ESCALATION:-2}"
STRIKE_KEY="$(printf '%s' "stop-gate:${REPO_ROOT}:${VERIFY_CMD}" | cksum | awk '{print $1"-"$2}')"
STRIKE_FILE="${STRIKE_DIR}/${STRIKE_KEY}.count"
TURN_STATE_FILE="${STRIKE_DIR}/turn-state.json"

update_turn_state() {
  local gate_passed="$1"
  local seen_count="$2"
  local fail_sig="${3:-}"
  mkdir -p "$STRIKE_DIR" 2>/dev/null || return 0
  [ -L "$STRIKE_DIR" ] && return 0
  local py_bin=""
  if command -v python3 >/dev/null 2>&1; then
    py_bin="python3"
  elif command -v python >/dev/null 2>&1; then
    py_bin="python"
  fi
  if [ -n "$py_bin" ]; then
    AXN_TURN_STATE="$TURN_STATE_FILE" AXN_GATE_PASSED="$gate_passed" AXN_SEEN="$seen_count" AXN_FAIL_SIG="$fail_sig" "$py_bin" -c '
import json, os, re
fp = os.environ["AXN_TURN_STATE"]
gate = os.environ.get("AXN_GATE_PASSED", "true") == "true"
seen = int(os.environ.get("AXN_SEEN", "0"))
sig = os.environ.get("AXN_FAIL_SIG", "").strip()
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
data["stop_gate_passed"] = gate
sigs = data.get("failure_signatures")
if not isinstance(sigs, list):
    sigs = []
sigs = [s for s in sigs if isinstance(s, str) and re.match(r"^[A-Za-z0-9][A-Za-z0-9._:-]{0,63}$", s)]
if sig and re.match(r"^[A-Za-z0-9][A-Za-z0-9._:-]{0,63}$", sig) and sig not in sigs and len(sigs) < 10:
    sigs.append(sig)
data["failure_signatures"] = sigs[:10]
with open(fp, "w", encoding="utf-8") as f:
    json.dump(data, f, separators=(",", ":"))
' 2>/dev/null || true
  fi
}

clear_strikes() {
  update_turn_state "true" "0" ""
  [ -f "$STRIKE_FILE" ] && rm -f "$STRIKE_FILE" 2>/dev/null || true
}

build_stop_sig() {
  local first_tok
  first_tok="$(printf '%s' "$VERIFY_CMD" | awk '{print $1}')"
  first_tok="$(basename "$first_tok" 2>/dev/null || printf '%s' "$first_tok")"
  first_tok="$(printf '%s' "$first_tok" | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z0-9_-')"
  [ -z "$first_tok" ] && first_tok="custom"
  printf 'stop-gate:%s' "$first_tok"
}

record_strike() {
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
  local fail_sig
  fail_sig="$(build_stop_sig)"
  update_turn_state "false" "$count" "$fail_sig"
  if [ "$count" -ge "$MAX_RETRIES" ]; then
    printf '[AXN cost-routing] 2-STRIKE ESCALATION HINT (strike %s/%s on %s): Per config/cost-tiers.yaml, bump reasoning effort first (low -> medium -> high) or escalate T2_builder -> T3_architect.\n' \
      "$count" "$MAX_RETRIES" "$VERIFY_CMD" >&2
  fi
}

# Run inside repo root
OUT=""
if ! OUT="$(cd "$REPO_ROOT" && bash -c "$VERIFY_CMD" 2>&1)"; then
  printf '[AXN stop-gate-verifier] Verification failed (%s):\n%s\n' "$VERIFY_CMD" "$OUT" >&2
  record_strike
  exit 2
fi

clear_strikes
exit 0
