#!/usr/bin/env bash
# AXN CI & Pre-Commit Validation Suite.
# Checks: bash syntax, shellcheck (if available), executable bits, YAML frontmatter,
# <500-line SKILL.md rule, no personal paths, Unicode Trojan Source safety, secrets, and JSON validity.

set -euo pipefail

AXN_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FAILURES=0
WARNINGS=0

pass() { echo "[PASS] $1"; }
fail() { echo "[FAIL] $1" >&2; FAILURES=$((FAILURES + 1)); }
warn() { echo "[WARN] $1"; WARNINGS=$((WARNINGS + 1)); }

PYTHON_BIN=""
if command -v python3 >/dev/null 2>&1; then
  PYTHON_BIN="python3"
elif command -v python >/dev/null 2>&1; then
  PYTHON_BIN="python"
fi

echo "=== AXN Validation Suite ($AXN_ROOT) ==="

# 1. Bash syntax check on all .sh files
sh_files=()
while IFS= read -r -d '' f; do
  sh_files+=("$f")
done < <(find "$AXN_ROOT/scripts" "$AXN_ROOT/hooks" "$AXN_ROOT/skills" -type f -name '*.sh' -print0 2>/dev/null || true)

if [[ ${#sh_files[@]} -gt 0 ]]; then
  syntax_ok=1
  for f in "${sh_files[@]}"; do
    if ! bash -n "$f"; then
      fail "Bash syntax error in $f"
      syntax_ok=0
    fi
  done
  [[ $syntax_ok -eq 1 ]] && pass "Bash syntax valid (${#sh_files[@]} .sh files)"

  # 2. Optional shellcheck
  if command -v shellcheck >/dev/null 2>&1; then
    sc_ok=1
    for f in "${sh_files[@]}"; do
      if ! shellcheck -S warning "$f"; then
        fail "shellcheck failed on $f"
        sc_ok=0
      fi
    done
    [[ $sc_ok -eq 1 ]] && pass "shellcheck passed (${#sh_files[@]} .sh files)"
  else
    warn "shellcheck not installed; skipping static lint"
  fi
else
  warn "No .sh files found under scripts/ or hooks/"
fi

# 3. Git executable mode check (100755) for tracked .sh files
if git -C "$AXN_ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  mode_ok=1
  while IFS= read -r line; do
    mode="${line%% *}"
    path="${line##*$'\t'}"
    if [[ "$mode" != "100755" ]]; then
      fail "Missing executable mode (100755) in git index: $path (got $mode). Run: git update-index --chmod=+x $path"
      mode_ok=0
    fi
  done < <(git -C "$AXN_ROOT" ls-files --stage -- 'scripts/*.sh' 'hooks/*.sh' 'hooks/**/*.sh' 'skills/*.sh' 'skills/**/*.sh' 2>/dev/null || true)
  [[ $mode_ok -eq 1 ]] && pass "Git executable permissions (100755) verified for tracked .sh files"
fi

# 4. Python-powered checks: Frontmatter, <500-line SKILL.md, personal paths, Unicode safety, JSON, secrets
if [[ -n "$PYTHON_BIN" ]]; then
  if "$PYTHON_BIN" - "$AXN_ROOT" <<'PYEOF'
import json
import os
import re
import sys

root = sys.argv[1]
errors = []

# A. Validate skills/*/SKILL.md and agents/*.md
def parse_frontmatter(text):
    if text.startswith("\ufeff"):
        text = text[1:]
    text = text.replace("\r\n", "\n")
    if not text.startswith("---\n"):
        return None, "missing opening '---' YAML frontmatter"
    end = text.find("\n---\n", 4)
    if end == -1:
        return None, "missing closing '---' YAML frontmatter"
    fm_block = text[4:end]
    fields = {}
    for line in fm_block.splitlines():
        if not line.strip() or line.strip().startswith("#"):
            continue
        if ":" in line and not line.startswith(" ") and not line.startswith("\t"):
            k, v = line.split(":", 1)
            fields[k.strip()] = v.strip()
    return fields, None

skills_dir = os.path.join(root, "skills")
if os.path.isdir(skills_dir):
    for entry in sorted(os.listdir(skills_dir)):
        skill_md = os.path.join(skills_dir, entry, "SKILL.md")
        if not os.path.isdir(os.path.join(skills_dir, entry)):
            continue
        if not os.path.isfile(skill_md):
            errors.append(f"skills/{entry}: missing SKILL.md")
            continue
        with open(skill_md, "r", encoding="utf-8", errors="replace") as fh:
            content = fh.read()
        line_count = len(content.splitlines())
        if line_count >= 500:
            errors.append(f"skills/{entry}/SKILL.md: {line_count} lines (must be < 500)")
        fm, err = parse_frontmatter(content)
        if err:
            errors.append(f"skills/{entry}/SKILL.md: {err}")
        else:
            name = fm.get("name", "").strip("'\"")
            desc = fm.get("description", "").strip("'\"")
            if not name:
                errors.append(f"skills/{entry}/SKILL.md: missing 'name:' in frontmatter")
            elif "claude" in name.lower() or "anthropic" in name.lower():
                errors.append(f"skills/{entry}/SKILL.md: 'name' must not contain 'claude' or 'anthropic' ({name})")
            if not desc or desc in ("|", "|-", ">", ">-"):
                errors.append(f"skills/{entry}/SKILL.md: 'description:' must be a non-empty inline scalar")

agents_dir = os.path.join(root, "agents")
valid_agent_tiers = {"T0_local", "T1_scout", "T2_builder", "T3_architect"}
valid_agent_models = {"haiku", "sonnet", "opus", "inherit"}
if os.path.isdir(agents_dir):
    for entry in sorted(os.listdir(agents_dir)):
        if not entry.endswith(".md"):
            continue
        agent_md = os.path.join(agents_dir, entry)
        with open(agent_md, "r", encoding="utf-8", errors="replace") as fh:
            content = fh.read()
        fm, err = parse_frontmatter(content)
        if err:
            errors.append(f"agents/{entry}: {err}")
        else:
            if not fm.get("name", "").strip("'\""):
                errors.append(f"agents/{entry}: missing 'name:' in frontmatter")
            desc = fm.get("description", "").strip("'\"")
            if not desc or desc in ("|", "|-", ">", ">-"):
                errors.append(f"agents/{entry}: 'description:' must be a non-empty inline scalar")
            tier = fm.get("tier", "").strip("'\"")
            model = fm.get("model", "").strip("'\"")
            if tier not in valid_agent_tiers:
                errors.append(f"agents/{entry}: 'tier:' must be one of {sorted(valid_agent_tiers)} (got '{tier}')")
            if model not in valid_agent_models:
                errors.append(f"agents/{entry}: 'model:' must be one of {sorted(valid_agent_models)} (got '{model}')")

# B. Personal path & Unicode Trojan Source & secret checks
personal_re = re.compile(r'(?:/Users/|C:\\\\?Users\\\\?|C:/Users/)([A-Za-z0-9._-]+)')
allowed_users = {"your-username", "username", "user", "name", "example"}
secret_re = re.compile(r'(sk-[A-Za-z0-9]{20,}|ghp_[A-Za-z0-9]{30,}|AKIA[0-9A-Z]{16}|BEGIN (?:RSA|OPENSSH|EC) PRIVATE KEY)')
unsafe_unicode = re.compile(r'[\u200b-\u200f\u202a-\u202e\u2066-\u2069]')

scan_roots = ["skills", "agents", "commands", "rules", "contexts", "schemas", "config", "hooks", "templates", "manifests", "docs", "instincts", "scripts", "tools"]
scan_files = [os.path.join(root, f) for f in ("README.md", "TROUBLESHOOTING.md", "SECURITY.md") if os.path.isfile(os.path.join(root, f))]
for sr in scan_roots:
    p = os.path.join(root, sr)
    if os.path.isdir(p):
        for dirpath, _, filenames in os.walk(p):
            for fn in filenames:
                scan_files.append(os.path.join(dirpath, fn))

for fp in scan_files:
    rel = os.path.relpath(fp, root)
    try:
        with open(fp, "r", encoding="utf-8") as fh:
            text = fh.read()
    except UnicodeDecodeError:
        continue
    for idx, line in enumerate(text.splitlines(), 1):
        for m in personal_re.finditer(line):
            uname = m.group(1).lower()
            if uname not in allowed_users and not uname.startswith("<"):
                errors.append(f"{rel}:{idx}: personal home path leak ('{m.group(0)}')")
        if unsafe_unicode.search(line):
            errors.append(f"{rel}:{idx}: unsafe invisible/bidi Unicode character detected")
        if not rel.endswith(".md") and secret_re.search(line):
            errors.append(f"{rel}:{idx}: potential secret/key pattern detected")

# C. JSON validation
for jdir in ("manifests", "schemas", "tools"):
    jp = os.path.join(root, jdir)
    if os.path.isdir(jp):
        for dirpath, _, filenames in os.walk(jp):
            for fn in filenames:
                if fn.endswith(".json"):
                    fp = os.path.join(dirpath, fn)
                    rel = os.path.relpath(fp, root)
                    try:
                        with open(fp, "r", encoding="utf-8") as fh:
                            json.load(fh)
                    except Exception as exc:
                        errors.append(f"{rel}: invalid JSON ({exc})")

# D. Cost-tiers YAML validation
cost_tiers_path = os.path.join(root, "config", "cost-tiers.yaml")
if not os.path.isfile(cost_tiers_path):
    errors.append("config/cost-tiers.yaml: missing required cost routing config")
else:
    with open(cost_tiers_path, "r", encoding="utf-8") as fh:
        ct_text = fh.read()
    try:
        import yaml
        ct_data = yaml.safe_load(ct_text)
        for k in ("version", "default_execution_tier", "default_subagent_tier", "tiers", "escalation"):
            if not isinstance(ct_data, dict) or k not in ct_data:
                errors.append(f"config/cost-tiers.yaml: missing key '{k}'")
        tiers_obj = ct_data.get("tiers", {}) if isinstance(ct_data, dict) else {}
        for tk in ("T0_local", "T1_scout", "T2_builder", "T3_architect"):
            if tk not in tiers_obj:
                errors.append(f"config/cost-tiers.yaml: missing tier '{tk}'")
    except ImportError:
        for req in ("default_execution_tier:", "default_subagent_tier:", "T0_local:", "T1_scout:", "T2_builder:", "T3_architect:", "escalation:"):
            if req not in ct_text:
                errors.append(f"config/cost-tiers.yaml: missing '{req}'")

if errors:
    for e in errors:
        print(f"[FAIL] {e}", file=sys.stderr)
    sys.exit(1)
print("[PASS] Frontmatter, <500-line, personal-path, Unicode, secret, and JSON checks passed")
PYEOF
  then
    :
  else
    FAILURES=$((FAILURES + 1))
  fi

  # 5. Python syntax compile & learn-router.py self-test
  if [[ -f "$AXN_ROOT/scripts/learn-router.py" ]]; then
    tmp_pycache="$(mktemp -d)"
    if PYTHONPYCACHEPREFIX="$tmp_pycache" "$PYTHON_BIN" -m py_compile "$AXN_ROOT/scripts/learn-router.py"; then
      pass "Python py_compile passed for scripts/learn-router.py"
    else
      fail "Python py_compile failed for scripts/learn-router.py"
    fi
    rm -rf "$tmp_pycache"

    if "$PYTHON_BIN" "$AXN_ROOT/scripts/learn-router.py" --self-test; then
      :
    else
      fail "scripts/learn-router.py --self-test failed"
    fi
  fi
else
  warn "python/python3 not found; skipping frontmatter, Unicode, and JSON checks"
fi

echo "=== Summary: $FAILURES failure(s), $WARNINGS warning(s) ==="
[[ $FAILURES -eq 0 ]]
