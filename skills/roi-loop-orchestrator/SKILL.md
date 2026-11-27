---
name: roi-loop-orchestrator
description: Autonomous ROI loop for implementing planned tasks, checking PR/CI/merge status, fixing issues, and enforcing usage/quota/context limits. Use when asked to work through planned tasks or manage PRs in a loop.
---

# ROI Loop Orchestrator

Follow AXN's `GLOBAL_AGENTS.md` alongside the repository's own `AGENTS.md` / `CLAUDE.md`:

1. **Phase 0 (Limits & Quota Preflight):** Check `gh api rate_limit`; check `runner-health` if `.github/workflows/runner-health.yml` exists; respect runtime usage-limit notices; never tight-loop on 429/quota errors; use the runtime's fastest/lowest-cost model tier for read-only lookups; cap tasks per run (`N = 5`) and fix retries (`<= 2`); compact context between iterations.
2. **Phase 1 (PR & CI Loop):** Detect the repo's default base branch, fetch `origin/<base>`, list `--author @me` open PRs, fix conflicts/failures (max 2 retries; avoid `&&` in Windows PowerShell 5.1), and merge via `gh pr merge` when green and permitted by repo policy.
3. **Phase 2 (ROI Selection):** Locate the repo's backlog/task tracker if present, verify task status against actual code, skip owner-blocked/parked tasks, rank by accuracy, speed, and performance ROI, and record decision impact.
4. **Phase 3 (Implement & Measure):** Measure baseline first, implement behind default-off flags if hot-path reads change, measure paired after-state, and enforce the 0-loss rule (or retire refuted hypotheses).
5. **Phase 4 (Docs, Gates & Repeat):** Update docs/diagrams/CHANGELOG, run verification gates fast-to-slow, commit cleanly, open PR (1 at a time), and return to Phase 0.
