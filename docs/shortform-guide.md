# AXN Shortform Guide (5-Minute Setup & Cheat Sheet)

Get AXN running across Claude Code, Cursor, and Codex CLI in under 5 minutes.

---

## 1. Install & Sync

### macOS / Linux / Git Bash
```bash
git clone https://github.com/serety95/AXN.git ~/.axn
~/.axn/scripts/sync.sh --dry-run --wire-hooks   # preview symlinks + hook wiring
~/.axn/scripts/sync.sh --wire-hooks             # apply core profile + wire Claude hooks + axn-router
```

### Windows PowerShell
```powershell
git clone https://github.com/serety95/AXN.git "$HOME\.axn"
& "$HOME\.axn\scripts\sync.ps1" -DryRun -WireHooks
& "$HOME\.axn\scripts\sync.ps1" -WireHooks
```
> **Windows Tip:** Enable **Developer Mode** in Windows Settings so symlinks can be created without Administrator elevation.

---

## 2. Common Sync Commands

```bash
# Default profile is 'core' (templates, hooks, core skills, agents, rules, contexts)
~/.axn/scripts/sync.sh --claude --codex --wire-hooks

# Sync the full 350+ skill and command catalog
~/.axn/scripts/sync.sh --profile full --wire-hooks

# Sync minimal profile (GLOBAL_AGENTS.md + hooks only)
~/.axn/scripts/sync.sh --profile minimal --wire-hooks

# Cleanly remove AXN symlinks and unwire AXN hooks
~/.axn/scripts/sync.sh --uninstall --wire-hooks
```

---

## 3. Daily 7-Stage ROI Loop

```text
Preflight -> Rank -> Route -> Verify -> Escalate -> Attribute -> Distill/Prune
```

1. **Preflight:** Ask your agent to run `repo-map-compressor` for `.ai/MAP.md` (<1,500 tokens) and check `instincts/INDEX.md`.
2. **Rank & Gate:** Copy `templates/project/.ai/verify.cmd` to your repo's `.ai/verify.cmd` and set your fast test/typecheck command.
3. **Route:** Query `axn-router --recommend --task-type <type> --stack <stack>` (or `python3 ~/.axn/scripts/learn-router.py --recommend ...`).
4. **Verify & Escalate:**
   - `blast-radius-guard` + `config-protection` + `token-budget-guard` (`PreToolUse`) guard shell/config/context budgets.
   - `auto-verify-loop` (`PostToolUse`) runs scoped typecheck/lint after edits.
   - `stop-gate-verifier` (`Stop`) blocks task completion until `.ai/verify.cmd` passes.
   - Step reasoning effort (`low -> medium -> high`) before upgrading tier after 2 failed strikes.
5. **Attribute & Distill:** `orchestrator-feedback.sh` logs telemetry and sanitized failure signatures; run `axn-router --roi-report` to promote recurring failures into `instincts/` or `hooks/` and prune unused instincts.

---

## 4. Validate & Test Before Committing

```bash
./scripts/validate.sh
```
On Windows PowerShell:
```powershell
.\scripts\validate.ps1
```
