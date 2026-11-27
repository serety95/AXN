# AXN Shortform Guide (5-Minute Setup & Cheat Sheet)

Get AXN running across Claude Code, Cursor, and Codex CLI in under 5 minutes.

---

## 1. Install & Sync

### macOS / Linux / Git Bash
```bash
git clone https://github.com/serety95/AXN.git ~/.axn
~/.axn/scripts/sync.sh --dry-run   # preview symlinks
~/.axn/scripts/sync.sh             # apply symlinks
```

### Windows PowerShell
```powershell
git clone https://github.com/serety95/AXN.git "$HOME\.axn"
& "$HOME\.axn\scripts\sync.ps1" -DryRun
& "$HOME\.axn\scripts\sync.ps1"
```
> **Windows Tip:** Enable **Developer Mode** in Windows Settings so symlinks can be created without Administrator elevation.

---

## 2. Common Sync Commands

```bash
# Sync only Claude Code and Codex CLI
~/.axn/scripts/sync.sh --claude --codex

# Sync minimal profile (GLOBAL_AGENTS.md + hooks only)
~/.axn/scripts/sync.sh --profile minimal

# Cleanly remove only symlinks managed by AXN
~/.axn/scripts/sync.sh --uninstall
```

---

## 3. Daily Engineering Loop

```text
plan -> test -> implement -> review -> verify -> remember -> improve
```

1. **Onboard a repo:** Ask your agent to run `repo-map-compressor` to generate `.ai/MAP.md` (<1,500 tokens).
2. **Set a test gate:** Copy `templates/project/.ai/verify.cmd` to your repo's `.ai/verify.cmd` and set your fast test/typecheck command.
3. **Code with guardrails:**
   - `blast-radius-guard` (`PreToolUse`) blocks destructive shell commands and `.env` reads.
   - `auto-verify-loop` (`PostToolUse`) runs scoped typecheck/lint after edits.
   - `stop-gate-verifier` (`Stop`) blocks task completion until `.ai/verify.cmd` passes.
4. **Pre-PR review:** Ask your agent to run `adversarial-diff-audit` on your staged diff.
5. **Capture lessons:** Save recurring fixes or quirks in `instincts/` using `instincts/TEMPLATE.md`.

---

## 4. Validate Before Committing

```bash
./scripts/validate.sh
```
On Windows PowerShell:
```powershell
.\scripts\validate.ps1
```
