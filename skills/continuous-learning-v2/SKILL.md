---
name: continuous-learning-v2
description: Extracts recurring bug fixes, codebase conventions, and architectural decisions from sessions into durable, confidence-scored instincts in instincts/ for cross-session reuse. Use after solving non-trivial bugs, receiving user corrections, or distilling session lessons.
---

# Continuous Learning v2 (Instincts Loop)

Convert ephemeral session lessons into durable, reusable instincts stored in `instincts/` so agents stop repeating the same mistakes across sessions.

## When to use

- After resolving a non-trivial root cause or environment quirk
- After a user corrects an approach, naming convention, or workflow assumption
- At the end of a feature or debugging session when a repeatable pattern emerged

## Instinct Lifecycle

1. **Observe:** Identify a specific trigger, failure mode, or convention that was not obvious from reading a single file.
2. **Distill:** Write a concise instinct entry (trigger, rule/action, rationale, evidence) into `instincts/`.
3. **Score Confidence:**
   - `0.5` (Provisional): Observed once; verify before generalizing.
   - `0.8` (Confirmed): Verified across 2+ occurrences or explicitly confirmed by the user/tests.
   - `1.0` (Canonical): Promoted into a skill, hook, or `GLOBAL_AGENTS.md` rule.
4. **Promote or Decay:**
   - When an instinct reaches `0.8+` and applies broadly, promote it into a deterministic hook (`hooks/`) or skill (`skills/`).
   - Prune or lower confidence on instincts invalidated by codebase changes.

## Instinct Entry Format

```markdown
---
id: <kebab-case-id>
confidence: 0.8
scope: <repo|language|global>
---
- **Trigger:** When <condition>
- **Rule:** Do <action> instead of <anti-pattern>
- **Evidence:** <file:line or command/test result>
```

## Rules

- Never store secrets, PII, or machine-local absolute paths in instincts.
- Keep each instinct atomic (one trigger, one actionable rule).
