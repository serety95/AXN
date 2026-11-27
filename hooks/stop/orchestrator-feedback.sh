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

# Determine python binary for single-process stdin cap + extraction + learn-router.py
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

# Single-process bounded stdin (1 MiB) + stop_hook_active check + AXN_TELEMETRY extraction
# (prioritizing direct message fields over transcript_path, rejecting <...> / | placeholders)
# + deterministic passed/retries ground truth.
TELEMETRY_JSON="$(AXN_MAX_BYTES="$MAX_BYTES" AXN_REPO_STRIKE_DIR="$REPO_STRIKE_DIR" "$PY_BIN" -c '
import json, os, re, sys

max_b = int(os.environ.get("AXN_MAX_BYTES", "1048576"))
data = sys.stdin.buffer.read(max_b + 1)
if len(data) > max_b:
    sys.stderr.write(f"[AXN orchestrator-feedback] WARN: Hook input exceeded {max_b} bytes; skipping telemetry.\n")
    sys.exit(0)

raw_text = data.decode("utf-8", errors="replace").strip()
if not raw_text:
    sys.exit(0)

try:
    payload = json.loads(raw_text)
except Exception:
    sys.exit(0)
if not isinstance(payload, dict):
    sys.exit(0)

if payload.get("stop_hook_active") is True:
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
SAFE_ID_RE = re.compile(r"^[a-z0-9][a-z0-9_-]{0,63}$")
SAFE_SIG_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._:-]{0,63}$")

passed = True
max_strikes_seen = 0
failure_signatures = []
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
                raw_sigs = ts.get("failure_signatures")
                if isinstance(raw_sigs, list):
                    for s in raw_sigs:
                        if isinstance(s, str) and SAFE_SIG_RE.match(s) and s not in failure_signatures:
                            failure_signatures.append(s)
                            if len(failure_signatures) >= 10:
                                break
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

raw_instincts = telemetry.get("instincts_used")
instincts_used = []
if isinstance(raw_instincts, list):
    for item in raw_instincts:
        if isinstance(item, str) and SAFE_ID_RE.match(item) and item not in instincts_used:
            instincts_used.append(item)
            if len(instincts_used) >= 16:
                break

telemetry["passed"] = passed
telemetry["retries"] = max(llm_retries, max_strikes_seen)
if "escalated_effort" not in telemetry:
    telemetry["escalated_effort"] = False
telemetry["instincts_used"] = instincts_used
telemetry["failure_signatures"] = failure_signatures

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
