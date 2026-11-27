---
name: business-analyst
description: Extracts and documents business rules from code and docs as a structured process pack (actors, statuses, queues, SLA, contact rules, related records). Use when the user asks how a process works, to extract business logic, map case/status lifecycle, document SLA or queues, write workflow chapters, compare code vs docs for drift, or write localized process labels from a glossary.
---

# Business Analyst

Senior business analyst for operations and workflow systems. Trace **code + docs**. Never invent transitions.

## When to use

- "How does X work for the business?"
- Extract process, SLA, queue, actors, or case/entity lifecycle
- Status workflow chapters
- Code vs documentation drift

## Workflow

1. **Discover repository context first**: Check `.ai/MAP.md` or repository docs index if present before reading deep source files.
2. **Locate the canonical docs**: Find the repository's canonical workflow, status, and SLA docs (e.g., `docs/case-status-workflow.md`, `docs/sla-process.md`, or equivalent domain specs) before writing or analyzing code.
3. **Trace runtime**: controller/handler -> service -> entity/enum -> repository queue query -> i18n/UI labels. Quote evidence (file + symbol).
4. **Localized labels**: If the repository has a UX/domain glossary (e.g., `docs/*glossary*.md` or the `i18n-ux-copy` skill), derive operator copy from business meaning rather than literal EN->target-language translation.
5. **Emit a process pack** using [references/process-pack.md](references/process-pack.md). Include:
   - Actors (human roles, supervisors, schedulers, external integrations)
   - Decision diamonds (real gates enforced in code)
   - Data written on the record
   - Queue visibility (working queue vs board vs reports)
   - SLA / contact rules
   - Related records (audit logs, tasks, flags)
   - Quoted `flowchart TD` Mermaid diagram with glossary-aligned labels
6. **Gaps**: List code-vs-doc drift as findings. Do not silently "fix" business rules or invent edges.

## Delegation

- Architecture / module boundaries -> `software-architect` or `architect` skill/agent
- Mermaid polish / HUD / 16:9 deck -> `workflow-visualizer` skill/agent
- Operator i18n / glossary copy -> `i18n-ux-copy` skill
- Launch **one** matching subagent (or BA + visualizer in parallel) rather than duplicating work.

## Constraints

- Do not change allowed-edge maps unless the user asked to change product behavior.
- Distinguish working-queue visibility from general record visibility.
- Do not invent localized terminology; if a term is missing from the project glossary, add it there first.
