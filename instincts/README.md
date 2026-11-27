# AXN Instincts

`instincts/` stores **persistent, cross-session learnings and distilled patterns** extracted from real engineering sessions—recurring bug fixes, runtime quirks, codebase invariants, and tool-usage lessons.

Instead of re-explaining the same lesson in every new chat, capture it once as a lean, high-signal instinct.

---

## Lifecycle: Session → Instinct → Skill

1. **Observe:** A non-obvious failure, workaround, or invariant surfaces during a task (e.g., *"PowerShell 5.1 rejects `&&`"* or *"Never use `@latest` in MCP configs"*).
2. **Record:** Add a concise entry using [TEMPLATE.md](TEMPLATE.md) under `instincts/` (or a domain-specific file like `instincts/windows-shell.md`).
3. **Verify:** Tag the instinct with confidence (`high`, `medium`, `low`) and evidence (command/error observed).
4. **Promote:** When 3+ related instincts accumulate around a workflow, graduate them into a dedicated `skills/<name>/SKILL.md` or deterministic `hooks/` rule.

---

## Rules for Writing Instincts

- **Keep each instinct atomic:** One trigger condition, one verified action, one reason.
- **No machine-local paths or secrets:** Never include `/Users/<name>`, `C:\Users\<name>`, API keys, or private repo names.
- **Prefer deterministic enforcement:** If an instinct can be enforced by a shell hook or `.ai/verify.cmd`, promote it out of prose into `hooks/`.
