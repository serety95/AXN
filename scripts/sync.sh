#!/usr/bin/env bash
# Idempotent multi-runtime symlink manager for AXN.

if ! eval '[[ 1 == 1 ]]' 2>/dev/null; then
  echo "Error: bash 3.2+ is required." >&2
  exit 1
fi

set -euo pipefail

DRY_RUN=0
UNINSTALL=0
SYNC_CLAUDE=0
SYNC_CURSOR=0
SYNC_CODEX=0
PROFILE="full"

usage() {
  cat <<'EOF'
Usage: sync.sh [OPTIONS]

Options:
  --dry-run           Preview symlink actions without modifying the filesystem
  --uninstall         Remove only symlinks managed by this AXN repository
  --claude            Sync Claude Code (~/.claude)
  --cursor            Sync Cursor (~/.cursor)
  --codex             Sync Codex CLI (~/.codex)
  --profile <name>    Profile: minimal | core | developer | security | full (default: full)
  -h, --help          Show this help message
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)    DRY_RUN=1; shift ;;
    --uninstall)  UNINSTALL=1; shift ;;
    --claude)     SYNC_CLAUDE=1; shift ;;
    --cursor)     SYNC_CURSOR=1; shift ;;
    --codex)      SYNC_CODEX=1; shift ;;
    --profile)
      if [[ $# -lt 2 ]]; then
        echo "Error: --profile requires an argument." >&2
        exit 1
      fi
      PROFILE="$2"
      shift 2
      ;;
    -h|--help)    usage; exit 0 ;;
    *)
      echo "Error: Unknown option '$1'" >&2
      usage >&2
      exit 1
      ;;
  esac
done

case "$PROFILE" in
  minimal|core|developer|security|full) ;;
  *)
    echo "Error: Invalid profile '$PROFILE'. Expected: minimal, core, developer, security, full." >&2
    exit 1
    ;;
esac

if [[ $SYNC_CLAUDE -eq 0 && $SYNC_CURSOR -eq 0 && $SYNC_CODEX -eq 0 ]]; then
  SYNC_CLAUDE=1
  SYNC_CURSOR=1
  SYNC_CODEX=1
fi

# Resolve AXN_ROOT safely even if invoked via symlink
SCRIPT_PATH="${BASH_SOURCE[0]}"
while [[ -L "$SCRIPT_PATH" ]]; do
  SCRIPT_DIR="$(cd -P "$(dirname "$SCRIPT_PATH")" && pwd)"
  LINK_TARGET="$(readlink "$SCRIPT_PATH")"
  [[ "$LINK_TARGET" != /* ]] && SCRIPT_PATH="$SCRIPT_DIR/$LINK_TARGET" || SCRIPT_PATH="$LINK_TARGET"
done
AXN_ROOT="$(cd -P "$(dirname "$SCRIPT_PATH")/.." && pwd)"
TIMESTAMP="$(date +%Y%m%d%H%M%S)"

if [[ "${OSTYPE:-}" == msys* || "${OSTYPE:-}" == cygwin* ]]; then
  if [[ "${MSYS:-}" != *"winsymlinks:nativestrict"* ]]; then
    echo "[warn] Windows Git Bash detected without MSYS=winsymlinks:nativestrict." >&2
    echo "       ln -s may copy files instead of creating native symlinks. Consider scripts/sync.ps1." >&2
  fi
fi

log_action() {
  if [[ $DRY_RUN -eq 1 ]]; then
    echo "[dry-run] $1"
  else
    echo "$1"
  fi
}

resolve_abs() {
  local p="$1"
  if [[ -d "$p" ]]; then
    (cd -P "$p" 2>/dev/null && pwd)
  elif [[ -e "$p" ]]; then
    local d b
    d="$(cd -P "$(dirname "$p")" 2>/dev/null && pwd)"
    b="$(basename "$p")"
    echo "$d/$b"
  else
    echo "$p"
  fi
}

link_item() {
  local src="$1"
  local dst="$2"

  if [[ ! -e "$src" ]]; then
    return 0
  fi

  local dst_dir
  dst_dir="$(dirname "$dst")"

  if [[ -L "$dst" ]]; then
    local cur_target
    cur_target="$(readlink "$dst")"
    if [[ "$cur_target" == "$src" ]]; then
      echo "[ok] already linked: $dst"
      return 0
    fi
    if [[ "$cur_target" == "$AXN_ROOT"* ]]; then
      log_action "[update] $dst -> $src"
      if [[ $DRY_RUN -eq 0 ]]; then
        rm -f "$dst"
        ln -s "$src" "$dst"
      fi
      return 0
    fi
    local bak="${dst}.bak.${TIMESTAMP}"
    log_action "[backup] $dst -> $bak"
    if [[ $DRY_RUN -eq 0 ]]; then
      mv "$dst" "$bak"
    fi
  elif [[ -e "$dst" ]]; then
    local bak="${dst}.bak.${TIMESTAMP}"
    log_action "[backup] $dst -> $bak"
    if [[ $DRY_RUN -eq 0 ]]; then
      mv "$dst" "$bak"
    fi
  fi

  log_action "[link] $dst -> $src"
  if [[ $DRY_RUN -eq 0 ]]; then
    mkdir -p "$dst_dir"
    ln -s "$src" "$dst"
  fi
}

unlink_item() {
  local dst="$1"
  if [[ -L "$dst" ]]; then
    local cur_target
    cur_target="$(readlink "$dst")"
    if [[ "$cur_target" == "$AXN_ROOT"* ]]; then
      log_action "[unlink] $dst"
      if [[ $DRY_RUN -eq 0 ]]; then
        rm -f "$dst"
      fi
    else
      echo "[skip] not managed by AXN: $dst -> $cur_target"
    fi
  fi
}

include_agents() {
  [[ "$PROFILE" == "core" || "$PROFILE" == "developer" || "$PROFILE" == "full" ]]
}

include_skills() {
  [[ "$PROFILE" != "minimal" ]]
}

skill_allowed() {
  local skill_name="$1"
  if [[ "$PROFILE" == "core" ]]; then
    [[ "$skill_name" == "repo-map-compressor" || "$skill_name" == "adversarial-diff-audit" || "$skill_name" == "roi-loop-orchestrator" || "$skill_name" == "software-architect" ]]
    return $?
  elif [[ "$PROFILE" == "security" ]]; then
    [[ "$skill_name" == "repo-map-compressor" || "$skill_name" == "adversarial-diff-audit" || "$skill_name" == "agent-security-hardening" ]]
    return $?
  fi
  return 0
}

sync_runtime_skills() {
  local target_dir="$1"
  if ! include_skills && [[ $UNINSTALL -eq 0 ]]; then
    return 0
  fi
  if [[ -d "$AXN_ROOT/skills" ]]; then
    local skill_dir skill_name
    for skill_dir in "$AXN_ROOT/skills"/*/; do
      [[ -d "$skill_dir" ]] || continue
      skill_name="$(basename "$skill_dir")"
      if [[ $UNINSTALL -eq 1 ]]; then
        unlink_item "$target_dir/$skill_name"
      elif skill_allowed "$skill_name"; then
        link_item "${skill_dir%/}" "$target_dir/$skill_name"
      fi
    done
  fi
}

sync_runtime_agents() {
  local target_dir="$1"
  local ext="$2"
  if ! include_agents && [[ $UNINSTALL -eq 0 ]]; then
    return 0
  fi
  if [[ -d "$AXN_ROOT/agents" ]]; then
    local agent_file base_name
    for agent_file in "$AXN_ROOT/agents"/*.md; do
      [[ -f "$agent_file" ]] || continue
      base_name="$(basename "$agent_file" .md)"
      if [[ $UNINSTALL -eq 1 ]]; then
        unlink_item "$target_dir/${base_name}.${ext}"
      else
        link_item "$agent_file" "$target_dir/${base_name}.${ext}"
      fi
    done
  fi
}

sync_claude() {
  local base="$HOME/.claude"
  echo "=== Claude Code ($base) ==="
  if [[ $UNINSTALL -eq 1 ]]; then
    unlink_item "$base/CLAUDE.md"
    unlink_item "$base/hooks"
    unlink_item "$base/commands"
    unlink_item "$base/rules"
    unlink_item "$base/contexts"
    sync_runtime_skills "$base/skills"
    sync_runtime_agents "$base/agents" "md"
  else
    link_item "$AXN_ROOT/templates/GLOBAL_AGENTS.md" "$base/CLAUDE.md"
    link_item "$AXN_ROOT/hooks" "$base/hooks"
    if [[ "$PROFILE" == "developer" || "$PROFILE" == "full" ]]; then
      link_item "$AXN_ROOT/commands" "$base/commands"
    fi
    if [[ "$PROFILE" != "minimal" ]]; then
      link_item "$AXN_ROOT/rules" "$base/rules"
    fi
    if [[ "$PROFILE" == "core" || "$PROFILE" == "developer" || "$PROFILE" == "full" ]]; then
      link_item "$AXN_ROOT/contexts" "$base/contexts"
    fi
    sync_runtime_skills "$base/skills"
    sync_runtime_agents "$base/agents" "md"
  fi
}

sync_cursor() {
  local base="$HOME/.cursor"
  echo "=== Cursor ($base) ==="
  if [[ $UNINSTALL -eq 1 ]]; then
    unlink_item "$base/rules/global.mdc"
    unlink_item "$base/hooks"
    unlink_item "$base/commands"
    sync_runtime_skills "$base/skills"
    sync_runtime_agents "$base/rules" "mdc"
  else
    link_item "$AXN_ROOT/templates/GLOBAL_AGENTS.md" "$base/rules/global.mdc"
    link_item "$AXN_ROOT/hooks" "$base/hooks"
    if [[ "$PROFILE" == "developer" || "$PROFILE" == "full" ]]; then
      link_item "$AXN_ROOT/commands" "$base/commands"
    fi
    sync_runtime_skills "$base/skills"
    sync_runtime_agents "$base/rules" "mdc"
  fi
}

sync_codex() {
  local base="$HOME/.codex"
  echo "=== Codex CLI ($base) ==="
  if [[ $UNINSTALL -eq 1 ]]; then
    unlink_item "$base/AGENTS.md"
    sync_runtime_skills "$base/skills"
  else
    link_item "$AXN_ROOT/templates/GLOBAL_AGENTS.md" "$base/AGENTS.md"
    sync_runtime_skills "$base/skills"
  fi
}

echo "AXN Root: $AXN_ROOT (profile=$PROFILE, dry_run=$DRY_RUN, uninstall=$UNINSTALL)"
[[ $SYNC_CLAUDE -eq 1 ]] && sync_claude
[[ $SYNC_CURSOR -eq 1 ]] && sync_cursor
[[ $SYNC_CODEX -eq 1 ]] && sync_codex
echo "Done."
