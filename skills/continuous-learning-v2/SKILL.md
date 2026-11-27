---
name: continuous-learning-v2
description: Extracts recurring bug fixes, failure signatures, codebase conventions, and architectural decisions into durable, confidence-scored instincts in instincts/ and prunes stale entries using learn-router.py --roi-report. Use after solving non-trivial bugs, receiving corrections, or reviewing ROI telemetry.
---

# Continuous Learning v2 (Instincts Loop)

Implements the `Distill/Prune` stage of AXN's 7-stage ROI loop (`Preflight -> Rank -> Route -> Verify -> Escalate -> Attribute -> Distill/Prune`), turning recurring session lessons and telemetry into durable instincts in `instincts/`.

## When to use

- After resolving a non-trivial root cause or environment quirk
- After a user corrects an approach, naming convention, or workflow assumption
- When `axn-router --roi-report` (or `python ~/.axn/scripts/learn-router.py --roi-report`) surfaces recurring `failure_signatures` (`count >= 2`) or unused `instincts/INDEX.md` entries

## Instinct Lifecycle

1. **Observe & Query Telemetry:** Run `axn-router --roi-report` (or `python ~/.axn/scripts/learn-router.py --roi-report`, if state exists) to inspect:
   - Recurring `failure_signatures` (`count >= 2`) ready for codification
   - `instinct_stats` pass-rate lift vs unused `instincts/INDEX.md` bloat candidates
2. **Distill:** Write an atomic instinct entry (valid ID `^[a-z0-9][a-z0-9_-]{0,63}$`) into `instincts/` and register it in `instincts/INDEX.md`.
3. **Score Confidence:**
   - `0.5` (Provisional): Observed once or from a recurring failure signature; verify before generalizing.
   - `0.8` (Confirmed): Verified across 2+ occurrences or positive pass-rate lift in `--roi-report`.
   - `1.0` (Canonical): Promoted into a deterministic hook (`hooks/`), skill (`skills/`), or `GLOBAL_AGENTS.md`.
4. **Promote or Prune:**
   - Promote high-lift (`0.8+`) instincts into deterministic hooks or skills.
   - Prune or archive `instincts/INDEX.md` entries flagged as unused bloat or negative-lift in `--roi-report` so prompt context stays lean.

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

- Never store secrets, PII, raw stderr dumps, or machine-local absolute paths in instincts.
- Keep each instinct atomic (one trigger, one actionable rule) and keep `instincts/INDEX.md` concise.
