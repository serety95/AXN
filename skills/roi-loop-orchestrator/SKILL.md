---
name: roi-loop-orchestrator
description: Autonomous macro ROI loop for ranking planned tasks, managing PR/CI/merge cycles, enforcing usage/quota/retry limits, and feeding the 7-stage AXN learning cycle. Use when asked to work through planned tasks or manage PRs in a loop.
---

# ROI Loop Orchestrator

Implements the macro `Preflight -> Rank` stages of AXN's unified 7-stage ROI loop (`Preflight -> Rank -> Route -> Verify -> Escalate -> Attribute -> Distill/Prune`), delegating per-task execution to `axn-orchestrator` and end-of-loop instinct distillation to `continuous-learning-v2`.

1. **Preflight (Limits, Quota & State):** Check `gh api rate_limit`; check `runner-health` only if `.github/workflows/runner-health.yml` exists; respect runtime usage-limit notices; never tight-loop on 429/quota errors; cap tasks per run (`N = 5`) and fix retries (`<= 2`); read `.ai/MAP.md` and `instincts/INDEX.md`.
2. **PR & CI Hygiene:** Detect the repo's default base branch, fetch `origin/<base>`, list `--author @me` open PRs, fix conflicts/failures (max 2 retries; avoid `&&` in Windows PowerShell 5.1), and merge via `gh pr merge` when green and permitted by repo policy.
3. **Rank (ROI Selection):** Locate the repo's backlog/task tracker if present, verify task status against actual code, skip owner-blocked/parked tasks, and rank by expected accuracy, speed, and cost ROI.
4. **Route, Verify, Escalate & Attribute:** Delegate each selected task to `axn-orchestrator` (`learn-router.py --recommend`, `config/cost-tiers.yaml`, Effort-Before-Tier, 2-Strike Escalation, and `AXN_TELEMETRY`). Measure paired before/after state on hot-path changes and enforce the 0-loss rule.
5. **Distill/Prune & Repeat:** Run `python scripts/learn-router.py --roi-report` (or `python3`) via `continuous-learning-v2` to promote recurring failure signatures and prune unused instincts, update docs/CHANGELOG, compact context, and return to Preflight.
