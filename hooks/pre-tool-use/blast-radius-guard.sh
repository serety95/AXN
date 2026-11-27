#!/usr/bin/env bash
# AXN PreToolUse Hook: blast-radius-guard.sh
# Hard-blocks destructive Bash commands, --no-verify, secret leaks, path traversal,
# and writes to sensitive/credential files.
# Exit 0 = allow, Exit 2 = hard block (reason on stderr).

set -euo pipefail

MAX_BYTES="${AXN_HOOK_MAX_BYTES:-1048576}"

block() {
  printf '[AXN blast-radius-guard] BLOCKED: %s\n' "$1" >&2
  exit 2
}

# Single-process bounded stdin (1 MiB) + JSON field extraction (Unit Separator \x1f avoids IFS whitespace collapsing)
# Exit codes from extractor: 0 = ok (empty stdout if blank input), 42 = oversized, 2 = malformed JSON
extract_bounded_fields() {
  if command -v jq >/dev/null 2>&1; then
    local payload
    payload="$(head -c $((MAX_BYTES + 1)))"
    [ "${#payload}" -le "$MAX_BYTES" ] || return 42
    [ -z "${payload//[[:space:]]/}" ] && return 0
    printf '%s' "$payload" | jq -r '
      [
        (.tool_name // .toolName // ""),
        (.tool_input.command // .tool_input.CommandLine // .toolInput.command // .toolInput.CommandLine // ""),
        (.tool_input.file_path // .tool_input.path // .tool_input.TargetFile // .tool_input.Path // .toolInput.file_path // .toolInput.path // .toolInput.TargetFile // .toolInput.Path // ""),
        (.tool_input.content // .tool_input.new_string // .toolInput.content // .toolInput.new_string // "")
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
vals = [
    str(d.get("tool_name") or d.get("toolName") or ""),
    str(ti.get("command") or ti.get("CommandLine") or ""),
    str(ti.get("file_path") or ti.get("path") or ti.get("TargetFile") or ti.get("Path") or ""),
    str(ti.get("content") or ti.get("new_string") or ""),
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
const clean = (s) => String(s || "").replace(/[\x1f\r\n]/g, " ");
console.log([
  clean(d.tool_name || d.toolName || ""),
  clean(ti.command || ti.CommandLine || ""),
  clean(ti.file_path || ti.path || ti.TargetFile || ti.Path || ""),
  clean(ti.content || ti.new_string || "")
].join("\x1f") + "\x1f");
' "$MAX_BYTES"
  else
    block "No JSON parser (jq, python3, python, or node) available for safety check."
  fi
}

PARSED=""
RC=0
PARSED="$(extract_bounded_fields)" || RC=$?
if [ "$RC" -eq 42 ]; then
  block "Hook input exceeded ${MAX_BYTES} bytes (fail-closed)."
elif [ "$RC" -ne 0 ]; then
  block "Malformed JSON payload on stdin (fail-closed)."
fi

[ -z "${PARSED//[[:space:]]/}" ] && exit 0

IFS=$'\x1f' read -r TOOL_NAME CMD FILE_PATH CONTENT _ <<< "$PARSED"

# Validate path against traversal, Windows reserved names, and sensitive files
check_safe_path() {
  local p="$1"
  [ -z "$p" ] && return 0

  # Reject null-byte markers or parent traversal escaping root
  if printf '%s' "$p" | grep -qE '(^|[\\/])\.\.([\\/]|$)'; then
    block "Path traversal ('..') is not allowed: $p"
  fi

  # Reject NTFS Alternate Data Streams (colon outside Windows drive prefix C:\)
  local no_drive="${p#[A-Za-z]:}"
  if printf '%s' "$no_drive" | grep -q ':'; then
    block "NTFS Alternate Data Stream or colon in path is not allowed: $p"
  fi

  # Reject Windows reserved device names in any path component
  local base
  base="$(basename "$p")"
  local stem="${base%%.*}"
  if printf '%s' "$stem" | grep -qiE '^(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])$'; then
    block "Windows reserved device name in path: $p"
  fi

  # Reject trailing dot or space in filename
  if printf '%s' "$base" | grep -qE '[. ]$'; then
    block "Trailing dot or space in filename is not allowed: $p"
  fi

  # Block writes to sensitive credential/secret files
  if printf '%s' "$base" | grep -qiE '^(\.env(\..+)?|\.npmrc|\.netrc|\.pypirc|id_rsa|id_ed25519|id_ecdsa|credentials(\.json)?)$'; then
    if ! printf '%s' "$base" | grep -qiE '^\.env\.(example|template|sample)$'; then
      block "Writing to sensitive secret/credential file is forbidden: $p"
    fi
  fi
  if printf '%s' "$base" | grep -qiE '\.(pem|key|p12|pfx|jks)$'; then
    block "Writing to private key/certificate file is forbidden: $p"
  fi

  # Block writes to system directories
  if printf '%s' "$p" | grep -qiE '^(/etc/|/usr/|/bin/|/sbin/|/System/|C:[\\/]Windows[\\/])'; then
    block "Writing to system directory is forbidden: $p"
  fi
}

check_bash_command() {
  local c="$1"
  [ -z "$c" ] && return 0

  # 1. Destructive filesystem commands
  if printf '%s' "$c" | grep -qiE '(^|[;&|`(])[[:space:]]*(sudo[[:space:]]+)?rm[[:space:]]+-[a-zA-Z]*[rR][a-zA-Z]*f[a-zA-Z]*[[:space:]]+(/|/\*|~|\$HOME|\.\.|[A-Za-z]:[\\/]?)[[:space:]]*($|[;&|)])'; then
    block "Destructive recursive delete targeting root, home, or parent directory."
  fi
  if printf '%s' "$c" | grep -qiE '(^|[;&|`(])[[:space:]]*(sudo[[:space:]]+)?rm[[:space:]]+-[a-zA-Z]*f[a-zA-Z]*[rR][a-zA-Z]*[[:space:]]+(/|/\*|~|\$HOME|\.\.|[A-Za-z]:[\\/]?)[[:space:]]*($|[;&|)])'; then
    block "Destructive recursive delete targeting root, home, or parent directory."
  fi
  if printf '%s' "$c" | grep -qiE '(^|[;&|`(])[[:space:]]*(mkfs(\.[a-z0-9]+)?|fdisk|diskpart|format[[:space:]]+[A-Za-z]:)'; then
    block "Disk formatting/partitioning command is forbidden."
  fi
  if printf '%s' "$c" | grep -qiE 'dd[[:space:]]+.*of=/dev/(sd|nvme|hd|vd|disk)'; then
    block "Raw block device write via dd is forbidden."
  fi
  if printf '%s' "$c" | grep -qF ':(){ :|:& };:'; then
    block "Fork bomb detected."
  fi
  if printf '%s' "$c" | grep -qiE 'chmod[[:space:]]+(-R[[:space:]]+)?777[[:space:]]+/'; then
    block "Recursive chmod 777 on root path is forbidden."
  fi

  # 2. Destructive Git & --no-verify bypasses
  if printf '%s' "$c" | grep -qiE 'git[[:space:]]+(commit|push|merge|rebase|cherry-pick)[[:space:]]+.*--no-verify'; then
    block "Bypassing git hooks with --no-verify is forbidden."
  fi
  if printf '%s' "$c" | grep -qiE 'git[[:space:]]+push[[:space:]]+.*([[:space:]]-f([[:space:]]|$)|--force([[:space:]]|$))'; then
    if ! printf '%s' "$c" | grep -qiE -- '--force-with-lease'; then
      block "Force-pushing without --force-with-lease is forbidden."
    fi
  fi
  if printf '%s' "$c" | grep -qiE 'git[[:space:]]+push[[:space:]]+.*--force-with-lease.*\b(main|master)\b'; then
    block "Force-pushing to main/master is forbidden."
  fi
  if printf '%s' "$c" | grep -qiE 'git[[:space:]]+reset[[:space:]]+--hard'; then
    block "git reset --hard is blocked to prevent accidental loss of uncommitted work."
  fi

  # 3. Destructive SQL
  if printf '%s' "$c" | grep -qiE '\b(DROP[[:space:]]+(TABLE|DATABASE|SCHEMA)|TRUNCATE[[:space:]]+TABLE)\b'; then
    block "Destructive SQL (DROP/TRUNCATE) is forbidden via Bash."
  fi

  # 4. Remote code execution pipes
  if printf '%s' "$c" | grep -qiE '(curl|wget)[[:space:]]+[^|]*\|[[:space:]]*(sudo[[:space:]]+)?(ba)?sh\b'; then
    block "Piping remote script directly into shell (curl|sh) is forbidden."
  fi

  # 5. Secret file reads / exfiltration
  if printf '%s' "$c" | grep -qiE '(cat|head|tail|less|more|sed|awk|grep|type|Get-Content)[[:space:]]+.*(\.env(\.local|\.production|\.staging)?\b|id_rsa|id_ed25519|\.aws/credentials|\.netrc)'; then
    if ! printf '%s' "$c" | grep -qiE '\.env\.(example|template|sample)\b'; then
      block "Reading secret/credential files in Bash is forbidden."
    fi
  fi
}

check_secret_content() {
  local txt="$1"
  [ -z "$txt" ] && return 0

  if printf '%s' "$txt" | grep -qE 'AKIA[0-9A-Z]{16}'; then
    block "Potential AWS Access Key ID detected in written content."
  fi
  if printf '%s' "$txt" | grep -qE '(ghp_[A-Za-z0-9]{36}|github_pat_[A-Za-z0-9_]{22,})'; then
    block "Potential GitHub token detected in written content."
  fi
  if printf '%s' "$txt" | grep -qE 'sk-(ant-)?[A-Za-z0-9_-]{24,}'; then
    block "Potential API secret key (sk-...) detected in written content."
  fi
  if printf '%s' "$txt" | grep -qE 'xox[baprs]-[0-9A-Za-z-]{10,}'; then
    block "Potential Slack token detected in written content."
  fi
  if printf '%s' "$txt" | grep -qE -- '-----BEGIN (RSA |EC |OPENSSH |DSA )?PRIVATE KEY-----'; then
    block "Private key material detected in written content."
  fi
}

case "$TOOL_NAME" in
  Bash|bash|run_command|shell)
    check_bash_command "$CMD"
    ;;
  Write|Edit|MultiEdit|write_file|edit_file|replace_file_content|write_to_file)
    check_safe_path "$FILE_PATH"
    check_secret_content "$CONTENT"
    ;;
  Read|read_file|view_file)
    check_safe_path "$FILE_PATH"
    ;;
  *)
    # Also check command/file_path if present on unknown tool names
    check_bash_command "$CMD"
    check_safe_path "$FILE_PATH"
    ;;
esac

exit 0
