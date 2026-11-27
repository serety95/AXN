#!/usr/bin/env bash
# AXN PreToolUse Hook: token-budget-guard.sh
# Prevents context-window bloat by blocking unbounded reads of lockfiles,
# minified/vendor/build noise, and massive files (>600 lines or >100 KiB),
# while allowing bounded offset/limit or StartLine/EndLine slices.
# Supports AXN_TOKEN_GUARD_MODE=block (default, exit 2) or warn (exit 0).
# Exit 0 = allow, Exit 2 = hard block (reason on stderr).

set -euo pipefail

MAX_BYTES="${AXN_HOOK_MAX_BYTES:-1048576}"
MAX_READ_LINES="${AXN_MAX_READ_LINES:-600}"
MAX_READ_BYTES="${AXN_MAX_READ_BYTES:-102400}"
MODE="${AXN_TOKEN_GUARD_MODE:-block}"

deny_or_warn() {
  local msg="$1"
  if [ "$MODE" = "warn" ]; then
    printf '[AXN token-budget-guard] WARNING: %s\n' "$msg" >&2
    exit 0
  fi
  printf '[AXN token-budget-guard] BLOCKED: %s\n' "$msg" >&2
  exit 2
}

block_fatal() {
  printf '[AXN token-budget-guard] BLOCKED: %s\n' "$1" >&2
  exit 2
}

# Single-process bounded stdin (1 MiB) + JSON field extraction (Unit Separator \x1f)
extract_bounded_fields() {
  if command -v jq >/dev/null 2>&1; then
    local payload
    payload="$(head -c $((MAX_BYTES + 1)))"
    [ "${#payload}" -le "$MAX_BYTES" ] || return 42
    [ -z "${payload//[[:space:]]/}" ] && return 0
    printf '%s' "$payload" | jq -r '
      def ti: (.tool_input // .toolInput // {});
      def slice_limit:
        if (ti.limit != null) then (ti.limit | tostring)
        elif (ti.StartLine != null and ti.EndLine != null) then
          (((ti.EndLine | tonumber) - (ti.StartLine | tonumber) + 1) | tostring)
        else "" end;
      [
        (.tool_name // .toolName // ""),
        (ti.file_path // ti.path // ti.TargetFile // ti.Path // ""),
        slice_limit,
        (ti.command // ti.CommandLine // "")
      ] | map(tostring | gsub("[\u001f\r\n]"; " ")) | join("\u001f") + "\u001f"
    ' || return 2
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
if not isinstance(d, dict):
    sys.exit(2)
ti = d.get("tool_input") or d.get("toolInput") or {}
if not isinstance(ti, dict):
    ti = {}
lim = ti.get("limit")
if lim is None and ti.get("StartLine") is not None and ti.get("EndLine") is not None:
    try:
        lim = int(ti["EndLine"]) - int(ti["StartLine"]) + 1
    except Exception:
        lim = ""
vals = [
    str(d.get("tool_name") or d.get("toolName") or ""),
    str(ti.get("file_path") or ti.get("path") or ti.get("TargetFile") or ti.get("Path") or ""),
    "" if lim is None else str(lim),
    str(ti.get("command") or ti.get("CommandLine") or ""),
]
vals = [v.replace("\x1f", " ").replace("\n", " ").replace("\r", "") for v in vals]
print("\x1f".join(vals) + "\x1f")
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
if (!d || typeof d !== "object") process.exit(2);
const ti = (d.tool_input && typeof d.tool_input === "object") ? d.tool_input :
           (d.toolInput && typeof d.toolInput === "object") ? d.toolInput : {};
let lim = ti.limit;
if (lim == null && ti.StartLine != null && ti.EndLine != null) {
  const s = Number(ti.StartLine), e = Number(ti.EndLine);
  if (Number.isFinite(s) && Number.isFinite(e)) lim = e - s + 1;
}
const clean = (s) => String(s == null ? "" : s).replace(/[\x1f\r\n]/g, " ");
console.log([
  clean(d.tool_name || d.toolName || ""),
  clean(ti.file_path || ti.path || ti.TargetFile || ti.Path || ""),
  clean(lim == null ? "" : lim),
  clean(ti.command || ti.CommandLine || "")
].join("\x1f") + "\x1f");
' "$MAX_BYTES"
  else
    block_fatal "No JSON parser (jq, python3, python, or node) available for safety check."
  fi
}

PARSED=""
RC=0
PARSED="$(extract_bounded_fields)" || RC=$?
if [ "$RC" -eq 42 ]; then
  block_fatal "Hook input exceeded ${MAX_BYTES} bytes (fail-closed)."
elif [ "$RC" -ne 0 ]; then
  block_fatal "Malformed JSON payload on stdin (fail-closed)."
fi

[ -z "${PARSED//[[:space:]]/}" ] && exit 0

IFS=$'\x1f' read -r TOOL_NAME RAW_PATH LIMIT_VAL CMD _ <<< "$PARSED"

# Normalize Windows backslashes to forward slashes for consistent regex matching
NORM_PATH="${RAW_PATH//\\//}"

LOCKFILE_REGEX='(^|/)(package-lock\.json|pnpm-lock\.yaml|yarn\.lock|bun\.lockb|Cargo\.lock|poetry\.lock|composer\.lock|Gemfile\.lock|go\.sum)$'
NOISE_REGEX='(^|/)(node_modules|dist|build|\.next|\.nuxt|target|vendor|coverage|__pycache__|\.git)/|\.(min\.js|min\.css|map|bundle\.js|chunk\.js)$'

is_bounded_slice() {
  case "$LIMIT_VAL" in
    ''|*[!0-9]*) return 1 ;;
  esac
  [ "$LIMIT_VAL" -ge 1 ] && [ "$LIMIT_VAL" -le "$MAX_READ_LINES" ]
}

check_read_target() {
  local p="$1"
  [ -z "$p" ] && return 0

  if printf '%s' "$p" | grep -qiE "$LOCKFILE_REGEX"; then
    deny_or_warn "Reading lockfile '$p' wastes context tokens. Use targeted grep/jq queries instead."
  fi

  if printf '%s' "$p" | grep -qiE "$NOISE_REGEX"; then
    deny_or_warn "Reading generated/vendor/minified path '$p' wastes context tokens. Inspect source files instead."
  fi

  if [ -f "$p" ]; then
    # Allow bounded offset/limit or StartLine/EndLine slices
    if is_bounded_slice; then
      return 0
    fi

    local byte_count line_count
    byte_count="$(wc -c < "$p" 2>/dev/null || echo 0)"
    line_count="$(wc -l < "$p" 2>/dev/null || echo 0)"

    if [ "$line_count" -gt "$MAX_READ_LINES" ] || [ "$byte_count" -gt "$MAX_READ_BYTES" ]; then
      deny_or_warn "Unbounded read of '$p' (${line_count} lines, ${byte_count} bytes) exceeds budget (${MAX_READ_LINES} lines / ${MAX_READ_BYTES} bytes). Pass offset/limit or StartLine/EndLine (<= ${MAX_READ_LINES} lines), or use rg/grep."
    fi
  fi
}

check_bash_read() {
  local c="$1"
  [ -z "$c" ] && return 0

  local norm_cmd="${c//\\//}"
  # Ignore heredoc writes (e.g. cat <<EOF)
  if printf '%s' "$norm_cmd" | grep -qE '^[[:space:]]*cat[[:space:]]+<<'; then
    return 0
  fi

  # Block raw cat/head/tail/less/more/type/Get-Content dumps of lockfiles or vendor/minified noise
  if printf '%s' "$norm_cmd" | grep -qiE '(^|[;&|`(])[[:space:]]*(cat|head|tail|less|more|type|Get-Content)[[:space:]]+'; then
    if printf '%s' "$norm_cmd" | grep -qiE '(package-lock\.json|pnpm-lock\.yaml|yarn\.lock|bun\.lockb|Cargo\.lock|poetry\.lock|composer\.lock|Gemfile\.lock|go\.sum)\b'; then
      deny_or_warn "Dumping lockfile via shell reader wastes context tokens. Use rg/grep/jq instead."
    fi
    if printf '%s' "$norm_cmd" | grep -qiE '(^|[[:space:]/])(node_modules|dist|build|\.next|\.nuxt|target|vendor|coverage|__pycache__)/|\.(min\.js|min\.css|map|bundle\.js|chunk\.js)\b'; then
      deny_or_warn "Dumping generated/vendor/minified file via shell reader wastes context tokens."
    fi
  fi
}

case "$TOOL_NAME" in
  Read|View|read_file|view_file)
    check_read_target "$NORM_PATH"
    ;;
  Bash|bash|run_command|shell)
    check_bash_read "$CMD"
    ;;
esac

exit 0
