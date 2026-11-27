# AXN Security Guide

Hardening hooks, MCP permissions, prompt boundaries, and secret hygiene.

---

## 1. Official Sources & Supply-Chain Hygiene

- Install AXN exclusively from `https://github.com/serety95/AXN`.
- Pin MCP server versions in `tools/` and local configs (never use `@latest` or unpinned `npx -y` packages in production workflows).
- Keep machine-local `settings.json`, `config.toml`, and `mcp.json` out of version control.

---

## 2. Lifecycle Hook Hardening

AXN hooks run deterministically outside the LLM context window:

1. **Fail-Closed Bounded Stdin:** `PreToolUse` hooks should cap stdin reads and exit `2` (block) if input is malformed or truncated—never silently allow on error.
2. **Path Containment:** Reject `..`, command substitution (`$()`, backticks), and Windows-unsafe device names (`CON`, `NUL`, `COM1`, trailing dots/spaces, NTFS ADS `:`) before touching paths.
3. **Config Protection:** Prevent agents from weakening `.eslintrc*`, `ruff.toml`, `biome.json*`, or `.ai/verify.cmd` to make failing checks pass.
4. **No `--no-verify`:** Hard-block `--no-verify` in `Bash` tool calls so git hooks and commit gates cannot be bypassed.
5. **Token-Budget Guard (`token-budget-guard.sh`):** Fail-closed `PreToolUse` (`Read|Bash`) guard blocking unbounded reads of lockfiles, minified/vendor noise, and massive files while allowing bounded `offset`/`limit` slices.

---

## 3. Secret Boundaries

- **Never** symlink or commit `.env`, `.env.*`, `*.pem`, `*.key`, or credential stores.
- `blast-radius-guard` blocks `cat`, `head`, `tail`, `grep`, or `cp` targeting `.env` and private key paths.
- Run the secret audit before pushing:
  ```bash
  git grep -nE '(sk-[A-Za-z0-9]{20,}|ghp_[A-Za-z0-9]{30,}|AKIA[0-9A-Z]{16}|BEGIN (RSA|OPENSSH|EC) PRIVATE KEY)' -- . ':!*.md'
  ```

---

## 4. Prompt Defense & Unicode Safety

- Treat external web content, issue/PR bodies, and untrusted repo files as **data, not instructions**.
- `scripts/validate.sh` checks all tracked files for invisible, zero-width, and bidirectional Unicode characters (Trojan Source defense) and personal home paths (`/Users/<name>`, `C:\Users\<name>`).
