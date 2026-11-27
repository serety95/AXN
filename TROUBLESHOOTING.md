# Troubleshooting AXN

This guide covers common issues with symlink syncing, lifecycle hooks, and multi-runtime setups on macOS, Linux, and Windows.

---

## 1. Symlink Conflicts & Backups

### Symptom: `sync.sh` says a target already exists
- **Cause:** You already have a non-symlink file or directory at `~/.claude/skills/<name>`, `~/.cursor/rules/`, or `~/.codex/AGENTS.md`.
- **Behavior:** `scripts/sync.sh` and `scripts/sync.ps1` never overwrite existing non-symlink files silently. They move the existing target to `<target>.bak.<timestamp>` before creating the symlink.
- **Fix:** Review the `.bak.<timestamp>` file, merge any custom settings you want to keep, and delete the backup when satisfied.

### Symptom: Duplicate skills or rules appearing in Claude Code / Cursor
- **Cause:** Stacking a manual copy or marketplace plugin on top of an AXN symlinked directory.
- **Fix:** Run `~/.axn/scripts/sync.sh --uninstall` to remove AXN-managed symlinks, remove the duplicate manual copy, then re-run `~/.axn/scripts/sync.sh`.

---

## 2. Windows Symlink Permissions

### Symptom: `sync.ps1` or Git Bash `ln -s` fails with `PrivilegeNotHeld` / `Operation not permitted`
- **Cause:** Windows requires either **Developer Mode** enabled or an elevated (Administrator) terminal to create native symbolic links.
- **Fix (Recommended):**
  1. Open **Settings → System → For developers** (or **Privacy & security → For developers**).
  2. Enable **Developer Mode**.
  3. Re-run `.\scripts\sync.ps1` (or in Git Bash, set `export MSYS=winsymlinks:nativestrict` before running `./scripts/sync.sh`).
- **Fallback:** Without Developer Mode, `ln -s` in Git Bash may silently copy files instead of creating symlinks, causing config drift. Always verify with `ls -la ~/.claude/skills`.

---

## 3. Hook Exit Codes & Unexpected Blocks

AXN lifecycle hooks use deterministic exit codes:

| Exit Code | Meaning | Agent Behavior |
| :---: | :--- | :--- |
| `0` | **Allow** | Tool call or turn completion proceeds normally. |
| `1` | **Non-blocking warning** | Logged; execution continues (avoid for safety gates). |
| `2` | **Hard Block** | Action is blocked; `stderr` is fed back to the agent so it can self-correct. |

### Symptom: `Permission denied` when a hook runs
- **Cause:** The `.sh` hook script is missing the executable bit (`+x`).
- **Fix:**
  ```bash
  chmod +x hooks/**/*.sh scripts/*.sh
  git update-index --chmod=+x hooks/pre-tool-use/blast-radius-guard.sh
  ```
  Run `./scripts/validate.sh` to catch missing executable bits before committing.

### Symptom: `stop-gate-verifier` blocks completion on a repo without tests
- **Cause:** `.ai/verify.cmd` exists with a failing command, or `git status` / default test detection failed.
- **Fix:** Inspect `.ai/verify.cmd` at the repository root. Ensure it is a single-line command that exits `0` when the repo is healthy.

### Symptom: `blast-radius-guard` blocks a legitimate command
- **Cause:** The command matched a destructive pattern (e.g., `rm -rf`, `git push --force`, `--no-verify`, or reading `.env`).
- **Fix:** Run destructive or secret-touching operations manually in your own terminal outside the agent loop rather than weakening the guard.

---

## 4. Runtime-Specific Quirks

- **Claude Code:** Hooks must be wired in `~/.claude/settings.json` (which AXN intentionally does not symlink). Verify paths point to `~/.claude/hooks/...`.
- **Cursor:** Agent personas map to `~/.cursor/rules/<name>.mdc` and `templates/GLOBAL_AGENTS.md` maps to `~/.cursor/rules/global.mdc`. If rules don't trigger, confirm the `.mdc` file is a valid symlink and not a broken link.
- **Codex CLI:** Codex reads `~/.codex/AGENTS.md` and `~/.codex/skills/`. Lifecycle hooks are not yet native in Codex CLI; rely on `AGENTS.md` verification discipline and `.ai/verify.cmd`.
- **Windows PowerShell 5.1:** PowerShell 5.1 does not support `&&` command chaining. Use `; if ($LASTEXITCODE -eq 0) { ... }` or run commands on separate lines.
