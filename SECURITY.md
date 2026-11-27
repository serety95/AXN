# Security Policy

## Official Sources Only

Install AXN exclusively from the official repository:

- `https://github.com/serety95/AXN`

Third-party forks, mirrors, or unverified skill packs may contain prompt injections, malicious lifecycle hooks, or credential-exfiltrating MCP configurations.

---

## Security Architecture

AXN enforces defense-in-depth at the harness layer:

1. **Deterministic `PreToolUse` Guards:** `blast-radius-guard` blocks destructive shell commands (`rm -rf /`, `git push --force`, `--no-verify`, `DROP TABLE`, `chmod 777`) and `.env` / credential reads before execution.
2. **Machine-Local Secret Isolation:** `~/.claude/settings.json`, `~/.codex/config.toml`, and API keys are never symlinked or committed to version control.
3. **CI & Pre-Commit Validation (`scripts/validate.sh`):**
   - Rejects personal/machine-local home paths (`/Users/<name>`, `C:\Users\<name>`).
   - Rejects invisible, bidirectional, and zero-width Unicode characters (Trojan Source defense).
   - Enforces valid YAML frontmatter and `<500`-line limits on `SKILL.md` files.
   - Scans for common secret/token patterns.
4. **Prompt Defense & Adversarial Diff Audit:** Agent personas and `adversarial-diff-audit` treat external URLs, untrusted repo text, and hidden Unicode as untrusted input.

---

## Secret & Hygiene Audit One-Liners

Run these before committing or sharing a fork:

### Bash / macOS / Linux / Git Bash
```bash
git grep -nE '(sk-[A-Za-z0-9]{20,}|ghp_[A-Za-z0-9]{30,}|AKIA[0-9A-Z]{16}|BEGIN (RSA|OPENSSH|EC) PRIVATE KEY)' -- . ':!*.md'
```

### PowerShell (Windows)
```powershell
git grep -nE '(sk-[A-Za-z0-9]{20,}|ghp_[A-Za-z0-9]{30,}|AKIA[0-9A-Z]{16}|BEGIN (RSA|OPENSSH|EC) PRIVATE KEY)' -- . ':!*.md'
```

---

## Reporting a Vulnerability

If you discover a hook bypass, command injection, path traversal, or secret-leak vector in AXN:

1. **Do not** open a public issue with exploit details.
2. Report it privately to the repository maintainers via GitHub Security Advisories (`Security -> Advisories -> Report a vulnerability`).
3. Include the affected file, reproduction steps, and expected vs. actual exit code/behavior.
