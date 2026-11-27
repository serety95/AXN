#!/usr/bin/env bash
# Idempotent multi-runtime symlink manager for AXN.

if ! eval '[[ 1 == 1 ]]' 2>/dev/null; then
  echo "Error: bash 3.2+ is required." >&2
  exit 1
fi

set -euo pipefail

DRY_RUN=0
UNINSTALL=0
WIRE_HOOKS=0
SYNC_CLAUDE=0
SYNC_CURSOR=0
SYNC_CODEX=0
PROFILE="core"

usage() {
  cat <<'EOF'
Usage: sync.sh [OPTIONS]

Options:
  --dry-run           Preview symlink/settings actions without modifying the filesystem
  --uninstall         Remove only symlinks (and wired hooks with --wire-hooks) managed by AXN
  --wire-hooks        Safely merge all 6 AXN lifecycle hooks into ~/.claude/settings.json
  --claude            Sync Claude Code (~/.claude)
  --cursor            Sync Cursor (~/.cursor)
  --codex             Sync Codex CLI (~/.codex)
  --profile <name>    Profile: minimal | core | developer | security | full (default: core)
  -h, --help          Show this help message
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)    DRY_RUN=1; shift ;;
    --uninstall)  UNINSTALL=1; shift ;;
    --wire-hooks) WIRE_HOOKS=1; shift ;;
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

PYTHON_BIN=""
if command -v python3 >/dev/null 2>&1; then
  PYTHON_BIN="python3"
elif command -v python >/dev/null 2>&1; then
  PYTHON_BIN="python"
fi

# Resolve active modules & skill list from manifests/ (with safe static fallback)
MANIFEST_MODULES="|"
MANIFEST_SKILLS_MODE="none"
MANIFEST_SKILLS="|"

load_manifest_plan() {
  local profiles_json="$AXN_ROOT/manifests/install-profiles.json"
  local modules_json="$AXN_ROOT/manifests/install-modules.json"
  if [[ -n "$PYTHON_BIN" && -f "$profiles_json" && -f "$modules_json" ]]; then
    local plan
    plan="$("$PYTHON_BIN" - "$profiles_json" "$modules_json" "$PROFILE" <<'PYEOF'
import json, sys

profiles_path, modules_path, profile_name = sys.argv[1:4]
profiles_doc = json.load(open(profiles_path, "r", encoding="utf-8"))
modules_doc = json.load(open(modules_path, "r", encoding="utf-8"))

profile_obj = profiles_doc.get("profiles", {}).get(profile_name)
if not isinstance(profile_obj, dict):
    sys.exit(1)

active_mods = list(profile_obj.get("modules", []))
mod_map = {m.get("id"): m for m in modules_doc.get("modules", []) if isinstance(m, dict)}

skills_mode = "none"
allowed_skills = []
for mid in active_mods:
    mod = mod_map.get(mid, {})
    if mid == "all-skills" or "skills/" in mod.get("paths", []):
        skills_mode = "all"
    elif mod.get("kind") == "skill":
        if skills_mode != "all":
            skills_mode = "list"
        for p in mod.get("paths", []):
            if isinstance(p, str) and p.startswith("skills/"):
                sname = p[len("skills/"):].strip("/")
                if sname and sname not in allowed_skills:
                    allowed_skills.append(sname)

print("MODULES=|" + "|".join(active_mods) + "|")
print("SKILLS_MODE=" + skills_mode)
print("SKILLS=|" + "|".join(allowed_skills) + "|")
PYEOF
    )" || true
    if [[ -n "$plan" ]]; then
      while IFS= read -r line; do
        line="${line%$'\r'}"
        case "$line" in
          MODULES=*)     MANIFEST_MODULES="${line#MODULES=}" ;;
          SKILLS_MODE=*) MANIFEST_SKILLS_MODE="${line#SKILLS_MODE=}" ;;
          SKILLS=*)      MANIFEST_SKILLS="${line#SKILLS=}" ;;
        esac
      done <<< "$plan"
      return 0
    fi
  fi

  case "$PROFILE" in
    minimal)
      MANIFEST_MODULES="|core-templates|core-hooks|"
      MANIFEST_SKILLS_MODE="none"
      ;;
    core)
      MANIFEST_MODULES="|core-templates|core-hooks|core-skills|core-agents|core-rules|core-contexts|"
      MANIFEST_SKILLS_MODE="list"
      MANIFEST_SKILLS="|repo-map-compressor|adversarial-diff-audit|roi-loop-orchestrator|software-architect|"
      ;;
    security)
      MANIFEST_MODULES="|core-templates|core-hooks|core-rules|security-skills|"
      MANIFEST_SKILLS_MODE="list"
      MANIFEST_SKILLS="|repo-map-compressor|adversarial-diff-audit|agent-security-hardening|"
      ;;
    developer|full)
      MANIFEST_MODULES="|core-templates|core-hooks|core-agents|core-commands|core-rules|core-contexts|all-skills|"
      MANIFEST_SKILLS_MODE="all"
      ;;
  esac
}

load_manifest_plan

has_module() {
  [[ "$MANIFEST_MODULES" == *"|$1|"* ]]
}

log_action() {
  if [[ $DRY_RUN -eq 1 ]]; then
    echo "[dry-run] $1"
  else
    echo "$1"
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

skill_allowed() {
  local skill_name="$1"
  if [[ "$MANIFEST_SKILLS_MODE" == "all" ]]; then
    return 0
  elif [[ "$MANIFEST_SKILLS_MODE" == "list" ]]; then
    [[ "$MANIFEST_SKILLS" == *"|${skill_name}|"* ]]
    return $?
  fi
  return 1
}

sync_runtime_skills() {
  local target_dir="$1"
  if [[ "$MANIFEST_SKILLS_MODE" == "none" && $UNINSTALL -eq 0 ]]; then
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
  if ! has_module "core-agents" && [[ $UNINSTALL -eq 0 ]]; then
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

wire_claude_hooks() {
  local settings_path="$HOME/.claude/settings.json"
  if [[ -z "$PYTHON_BIN" ]]; then
    echo "[warn] python/python3 not found; skipping --wire-hooks for $settings_path" >&2
    return 0
  fi
  if [[ -L "$settings_path" ]]; then
    echo "[warn] Refusing to modify symlinked $settings_path" >&2
    return 1
  fi
  "$PYTHON_BIN" - "$settings_path" "$UNINSTALL" "$DRY_RUN" "$TIMESTAMP" <<'PYEOF'
import json, os, shutil, sys, tempfile

settings_path, uninstall_flag, dry_run_flag, ts = sys.argv[1:5]
uninstall = uninstall_flag == "1"
dry_run = dry_run_flag == "1"

AXN_HOOKS = [
    ("PreToolUse", "Bash|Write|Edit|Read", "~/.claude/hooks/pre-tool-use/blast-radius-guard.sh"),
    ("PreToolUse", "Write|Edit", "~/.claude/hooks/pre-tool-use/config-protection.sh"),
    ("PreToolUse", "Read|Bash", "~/.claude/hooks/pre-tool-use/token-budget-guard.sh"),
    ("PostToolUse", "Edit|Write", "~/.claude/hooks/post-tool-use/auto-verify-loop.sh"),
    ("Stop", None, "~/.claude/hooks/stop/stop-gate-verifier.sh"),
    ("Stop", None, "~/.claude/hooks/stop/orchestrator-feedback.sh"),
]
AXN_COMMANDS = {cmd for _, _, cmd in AXN_HOOKS}

if os.path.isfile(settings_path):
    with open(settings_path, "r", encoding="utf-8") as fh:
        data = json.load(fh)
    if not isinstance(data, dict):
        raise ValueError(f"{settings_path} must contain a JSON object")
else:
    if uninstall:
        print(f"[ok] no settings.json to unwire: {settings_path}")
        sys.exit(0)
    data = {}

hooks_obj = data.setdefault("hooks", {})
if not isinstance(hooks_obj, dict):
    raise ValueError(f"{settings_path} 'hooks' must be a JSON object")

changed = 0

if uninstall:
    for event in ("PreToolUse", "PostToolUse", "Stop"):
        entries = hooks_obj.get(event)
        if not isinstance(entries, list):
            continue
        kept_entries = []
        for entry in entries:
            if not isinstance(entry, dict) or not isinstance(entry.get("hooks"), list):
                kept_entries.append(entry)
                continue
            new_hooks = [
                h for h in entry["hooks"]
                if not (isinstance(h, dict) and h.get("command") in AXN_COMMANDS)
            ]
            if len(new_hooks) != len(entry["hooks"]):
                changed += len(entry["hooks"]) - len(new_hooks)
            if new_hooks:
                updated = dict(entry)
                updated["hooks"] = new_hooks
                kept_entries.append(updated)
        if kept_entries:
            hooks_obj[event] = kept_entries
        else:
            hooks_obj.pop(event, None)
    if not hooks_obj:
        data.pop("hooks", None)
    action_label = "unwired"
else:
    for event, matcher, cmd in AXN_HOOKS:
        entries = hooks_obj.setdefault(event, [])
        if not isinstance(entries, list):
            raise ValueError(f"{settings_path} hooks.{event} must be a list")
        exists = any(
            isinstance(entry, dict)
            and any(isinstance(h, dict) and h.get("command") == cmd for h in entry.get("hooks", []))
            for entry in entries
        )
        if exists:
            continue
        if matcher is None:
            stop_entry = next(
                (e for e in entries if isinstance(e, dict) and "matcher" not in e and isinstance(e.get("hooks"), list)),
                None,
            )
            hook_item = {"type": "command", "command": cmd}
            if stop_entry is not None:
                stop_entry["hooks"].append(hook_item)
            else:
                entries.append({"hooks": [hook_item]})
        else:
            entries.append({
                "matcher": matcher,
                "hooks": [{"type": "command", "command": cmd}],
            })
        changed += 1
    action_label = "wired"

if changed == 0:
    print(f"[ok] hooks already {action_label}: {settings_path}")
    sys.exit(0)

prefix = "[dry-run] " if dry_run else ""
if os.path.isfile(settings_path):
    bak_path = f"{settings_path}.bak.{ts}"
    print(f"{prefix}[backup] {settings_path} -> {bak_path}")
    if not dry_run:
        shutil.copy2(settings_path, bak_path)

print(f"{prefix}[wire-hooks] {action_label} {changed} hook(s) in {settings_path}")
if not dry_run:
    parent = os.path.dirname(settings_path)
    os.makedirs(parent, exist_ok=True)
    fd, tmp_path = tempfile.mkstemp(prefix=".settings-", suffix=".tmp", dir=parent)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            json.dump(data, fh, indent=2)
            fh.write("\n")
        os.replace(tmp_path, settings_path)
    except Exception:
        if os.path.exists(tmp_path):
            os.unlink(tmp_path)
        raise
PYEOF
}

sync_claude() {
  local base="$HOME/.claude"
  echo "=== Claude Code ($base) ==="
  if [[ $UNINSTALL -eq 1 ]]; then
    unlink_item "$base/CLAUDE.md"
    unlink_item "$base/cost-tiers.yaml"
    unlink_item "$base/hooks"
    unlink_item "$base/commands"
    unlink_item "$base/rules"
    unlink_item "$base/contexts"
    sync_runtime_skills "$base/skills"
    sync_runtime_agents "$base/agents" "md"
  else
    link_item "$AXN_ROOT/templates/GLOBAL_AGENTS.md" "$base/CLAUDE.md"
    link_item "$AXN_ROOT/config/cost-tiers.yaml" "$base/cost-tiers.yaml"
    link_item "$AXN_ROOT/hooks" "$base/hooks"
    has_module "core-commands" && link_item "$AXN_ROOT/commands" "$base/commands"
    has_module "core-rules" && link_item "$AXN_ROOT/rules" "$base/rules"
    has_module "core-contexts" && link_item "$AXN_ROOT/contexts" "$base/contexts"
    sync_runtime_skills "$base/skills"
    sync_runtime_agents "$base/agents" "md"
  fi
  if [[ $WIRE_HOOKS -eq 1 ]]; then
    wire_claude_hooks
  fi
}

sync_cursor() {
  local base="$HOME/.cursor"
  echo "=== Cursor ($base) ==="
  if [[ $UNINSTALL -eq 1 ]]; then
    unlink_item "$base/rules/global.mdc"
    unlink_item "$base/cost-tiers.yaml"
    unlink_item "$base/hooks"
    unlink_item "$base/commands"
    sync_runtime_skills "$base/skills"
    sync_runtime_agents "$base/rules" "mdc"
  else
    link_item "$AXN_ROOT/templates/GLOBAL_AGENTS.md" "$base/rules/global.mdc"
    link_item "$AXN_ROOT/config/cost-tiers.yaml" "$base/cost-tiers.yaml"
    link_item "$AXN_ROOT/hooks" "$base/hooks"
    has_module "core-commands" && link_item "$AXN_ROOT/commands" "$base/commands"
    sync_runtime_skills "$base/skills"
    sync_runtime_agents "$base/rules" "mdc"
  fi
}

sync_codex() {
  local base="$HOME/.codex"
  echo "=== Codex CLI ($base) ==="
  if [[ $UNINSTALL -eq 1 ]]; then
    unlink_item "$base/AGENTS.md"
    unlink_item "$base/cost-tiers.yaml"
    sync_runtime_skills "$base/skills"
  else
    link_item "$AXN_ROOT/templates/GLOBAL_AGENTS.md" "$base/AGENTS.md"
    link_item "$AXN_ROOT/config/cost-tiers.yaml" "$base/cost-tiers.yaml"
    sync_runtime_skills "$base/skills"
  fi
}

sync_cli_shims() {
  local bin_dir="$HOME/.local/bin"
  if [[ $UNINSTALL -eq 1 ]]; then
    unlink_item "$bin_dir/axn-router"
  else
    link_item "$AXN_ROOT/scripts/learn-router.py" "$bin_dir/axn-router"
  fi
}

print_routing_hints() {
  echo ""
  echo "=== 4-Tier Multi-Provider Cost Routing Hints (optional shell setup) ==="
  echo "  Claude Code : alias cc=\"claude --model opusplan\" && export CLAUDE_CODE_SUBAGENT_MODEL=\"haiku\""
  echo "  Codex CLI   : T1=gpt-6-luna | T2=gpt-6-sol (default) | T3=gpt-6-astra"
  echo "  Cursor      : T1=cost (Composer 2.5) | T2=balance (sonnet) | T3=intelligence (opus / Grok 4.7)"
  echo "  Gemini CLI  : T1=flash-lite/flash | T2=pro/medium | T3=pro/deep"
  echo "  OpenCode    : T1=fast | T2=standard | T3=frontier"
  echo "  Local (\$0)  : MLX / LM Studio Qwen3.5-9B or Ollama (http://localhost:1234/v1)"
}

echo "AXN Root: $AXN_ROOT (profile=$PROFILE, dry_run=$DRY_RUN, uninstall=$UNINSTALL, wire_hooks=$WIRE_HOOKS)"
[[ $SYNC_CLAUDE -eq 1 ]] && sync_claude
[[ $SYNC_CURSOR -eq 1 ]] && sync_cursor
[[ $SYNC_CODEX -eq 1 ]] && sync_codex
sync_cli_shims
[[ $UNINSTALL -eq 0 ]] && print_routing_hints
echo "Done."
