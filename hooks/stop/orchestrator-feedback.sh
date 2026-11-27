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

# Extract AXN_TELEMETRY JSON and attach deterministic passed ground truth
TELEMETRY_JSON="$(printf '%s' "$PAYLOAD" | AXN_STRIKE_DIR="$STRIKE_DIR" "$PY_BIN" -c '
import json, os, re, sys

try:
    payload = json.load(sys.stdin)
except Exception:
    sys.exit(0)
if not isinstance(payload, dict):
    sys.exit(0)

candidates = []
for k in ("last_assistant_message", "assistant_message", "response", "message", "output"):
    v = payload.get(k)
    if isinstance(v, str) and v:
        candidates.append(v)

tp = payload.get("transcript_path")
if isinstance(tp, str) and tp and os.path.isfile(tp) and not os.path.islink(tp):
    try:
        with open(tp, "rb") as f:
            f.seek(0, os.SEEK_END)
            size = f.tell()
            f.seek(max(0, size - 65536))
            candidates.append(f.read().decode("utf-8", errors="replace"))
    except Exception:
        pass

text = "\n".join(candidates)
matches = re.findall(r"AXN_TELEMETRY:\s*(\{[^\r\n]*\})", text)
if not matches:
    sys.exit(0)

try:
    telemetry = json.loads(matches[-1])
except Exception:
    sys.exit(0)
if not isinstance(telemetry, dict):
    sys.exit(0)

# Deterministic ground truth: check env override or active strike counters
passed = True
env_gate = os.environ.get("AXN_STOP_GATE_PASSED", "").strip().lower()
if env_gate == "false":
    passed = False
elif env_gate != "true":
    strike_dir = os.environ.get("AXN_STRIKE_DIR", "")
    if strike_dir and os.path.isdir(strike_dir) and not os.path.islink(strike_dir):
        try:
            for name in os.listdir(strike_dir):
                if not name.endswith(".count"):
                    continue
                fp = os.path.join(strike_dir, name)
                if os.path.islink(fp) or not os.path.isfile(fp):
                    continue
                raw = open(fp, "r", encoding="utf-8", errors="replace").read().strip()
                if raw.isdigit() and int(raw) > 0:
                    passed = False
                    break
        except Exception:
            pass

telemetry["passed"] = passed
print(json.dumps(telemetry, separators=(",", ":")))
' 2>/dev/null || true)"

[ -z "$TELEMETRY_JSON" ] && exit 0

# Locate learn-router.py safely (reject symlinks)
REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
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
