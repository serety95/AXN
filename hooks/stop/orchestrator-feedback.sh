#!/usr/bin/env bash
# AXN Stop Hook: orchestrator-feedback.sh
# Extracts advisory AXN_TELEMETRY JSON from the Stop payload, injects
# deterministic pass/fail ground truth from AXN strike state (never trusting
# LLM self-reported passed=true), and pipes it via stdin to learn-router.py.
# Always fails open (exit 0) so telemetry never blocks task completion.

set -euo pipefail

MAX_BYTES="${AXN_HOOK_MAX_BYTES:-1048576}"
STRIKE_DIR="${AXN_STRIKE_DIR:-${TMPDIR:-/tmp}/axn-strikes}"

warn() {
  printf '[AXN orchestrator-feedback] WARN: %s\n' "$1" >&2
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
  warn "Hook input exceeded ${MAX_BYTES} bytes; skipping telemetry."
  exit 0
fi

[ -z "${PAYLOAD//[[:space:]]/}" ] && exit 0

# Respect stop_hook_active=true to avoid duplicate runs during retry loops
STOP_ACTIVE="false"
if command -v jq >/dev/null 2>&1; then
  STOP_ACTIVE="$(printf '%s' "$PAYLOAD" | jq -r '(.stop_hook_active // false) | tostring' 2>/dev/null || echo "false")"
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
' 2>/dev/null || echo "false")"
elif command -v node >/dev/null 2>&1; then
  STOP_ACTIVE="$(printf '%s' "$PAYLOAD" | node -e '
const fs = require("fs");
try {
  const d = JSON.parse(fs.readFileSync(0, "utf8"));
  console.log(d && d.stop_hook_active === true ? "true" : "false");
} catch { console.log("false"); }
' 2>/dev/null || echo "false")"
fi

if [ "$STOP_ACTIVE" = "true" ]; then
  exit 0
fi

# Determine python binary for extraction and learn-router.py execution
PY_BIN=""
if command -v python3 >/dev/null 2>&1; then
  PY_BIN="python3"
elif command -v python >/dev/null 2>&1; then
  PY_BIN="python"
else
  exit 0
fi

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
REPO_KEY="$(printf '%s' "$REPO_ROOT" | cksum | awk '{print $1"-"$2}')"
REPO_STRIKE_DIR="${STRIKE_DIR}/${REPO_KEY}"

# Extract AXN_TELEMETRY JSON (prioritizing direct message fields over transcript_path,
# rejecting <...> / | placeholders) and attach deterministic passed/retries ground truth.
TELEMETRY_JSON="$(printf '%s' "$PAYLOAD" | AXN_REPO_STRIKE_DIR="$REPO_STRIKE_DIR" "$PY_BIN" -c '
import json, os, re, sys

try:
    payload = json.load(sys.stdin)
except Exception:
    sys.exit(0)
if not isinstance(payload, dict):
    sys.exit(0)

def parse_valid_telemetry(text):
    if not text:
        return None
    matches = re.findall(r"AXN_TELEMETRY:\s*(\{[^\r\n]*\})", text)
    for raw in reversed(matches):
        try:
            obj = json.loads(raw)
        except Exception:
            continue
        if not isinstance(obj, dict):
            continue
        # Reject documentation/template placeholders like <explore|...> or T2|T3
        has_placeholder = False
        for v in obj.values():
            if isinstance(v, str) and ("<" in v or ">" in v or "|" in v):
                has_placeholder = True
                break
        if has_placeholder:
            continue
        if not isinstance(obj.get("task_type"), str) or not obj.get("task_type"):
            continue
        return obj
    return None

telemetry = None
direct_texts = []
for k in ("last_assistant_message", "assistant_message", "response", "message", "output"):
    v = payload.get(k)
    if isinstance(v, str) and v:
        direct_texts.append(v)

telemetry = parse_valid_telemetry("\n".join(direct_texts))

if telemetry is None:
    tp = payload.get("transcript_path")
    if isinstance(tp, str) and tp and os.path.isfile(tp) and not os.path.islink(tp):
        try:
            with open(tp, "rb") as f:
                f.seek(0, os.SEEK_END)
                size = f.tell()
                f.seek(max(0, size - 65536))
                telemetry = parse_valid_telemetry(f.read().decode("utf-8", errors="replace"))
        except Exception:
            telemetry = None

if telemetry is None:
    sys.exit(0)

# Deterministic ground truth from repo-scoped turn-state.json + active .count files
passed = True
max_strikes_seen = 0
repo_strike_dir = os.environ.get("AXN_REPO_STRIKE_DIR", "")
turn_state_file = os.path.join(repo_strike_dir, "turn-state.json") if repo_strike_dir else ""

if repo_strike_dir and os.path.isdir(repo_strike_dir) and not os.path.islink(repo_strike_dir):
    if turn_state_file and os.path.isfile(turn_state_file) and not os.path.islink(turn_state_file):
        try:
            ts = json.load(open(turn_state_file, "r", encoding="utf-8"))
            if isinstance(ts, dict):
                if isinstance(ts.get("max_strikes_seen"), int):
                    max_strikes_seen = max(0, ts["max_strikes_seen"])
                if ts.get("stop_gate_passed") is False:
                    passed = False
        except Exception:
            pass
        # Consume & reset turn-state.json for next turn
        try:
            os.unlink(turn_state_file)
        except Exception:
            pass

    try:
        for name in os.listdir(repo_strike_dir):
            if not name.endswith(".count"):
                continue
            fp = os.path.join(repo_strike_dir, name)
            if os.path.islink(fp) or not os.path.isfile(fp):
                continue
            raw = open(fp, "r", encoding="utf-8", errors="replace").read().strip()
            if raw.isdigit() and int(raw) > 0:
                passed = False
                max_strikes_seen = max(max_strikes_seen, int(raw))
    except Exception:
        pass

env_gate = os.environ.get("AXN_STOP_GATE_PASSED", "").strip().lower()
if env_gate == "false":
    passed = False
elif env_gate == "true":
    passed = True

try:
    llm_retries = int(telemetry.get("retries") or 0)
except Exception:
    llm_retries = 0

telemetry["passed"] = passed
telemetry["retries"] = max(llm_retries, max_strikes_seen)
if "escalated_effort" not in telemetry:
    telemetry["escalated_effort"] = False

print(json.dumps(telemetry, separators=(",", ":")))
' 2>/dev/null || true)"

[ -z "$TELEMETRY_JSON" ] && exit 0

# Locate learn-router.py safely (reject symlinks)
LEARN_ROUTER=""
for candidate in "${REPO_ROOT}/scripts/learn-router.py" "${AXN_ROOT:-$HOME/.axn}/scripts/learn-router.py"; do
  if [ -f "$candidate" ] && [ ! -L "$candidate" ]; then
    LEARN_ROUTER="$candidate"
    break
  fi
done

if [ -z "$LEARN_ROUTER" ]; then
  exit 0
fi

if ! printf '%s\n' "$TELEMETRY_JSON" | "$PY_BIN" "$LEARN_ROUTER" --ingest-stdin >/dev/null 2>&1; then
  warn "learn-router.py returned non-zero; continuing fail-open."
fi

exit 0
