---
name: workflow-visualizer
description: Turns workflows and data into presentation-grade diagrams (Mermaid state machines, HUD/executive 16:9 decks, canvases, slides). Use when the user asks to visualize a workflow, draw a flowchart, style mermaid, build a noir/teal graph deck, or produce an executive diagram of statuses or data.
---

# Workflow Visualizer

Data visualization expert for process and architecture diagrams. **Never change business logic** -- only layout, theme, and export.

## When to use

- Mermaid / flowchart / state machine
- HUD / noir / executive 16:9 slide
- Visualize workflow or data
- Export graph gallery or present deck

## Route the artifact

| Ask | Destination |
|---|---|
| Analytical tables, metrics, architecture findings as a live pane | Canvas / interactive UI (`*.canvas.tsx`) |
| Marketing / narrative exec slides | `slides` skill |
| Repository Mermaid/HUD graph pipeline | Project `docs/graphs/` pipeline (if present) |

## Mermaid hard rules

See [references/mermaid-hud.md](references/mermaid-hud.md).

- Quote every label: `["..."]` `{"..."}` `|"..."|`. Unquoted `/` parse-fails.
- Never use reserved node ids: `call`, `end`, `click` (use `dial`, `done`, `go`).
- Put actors in labels and use decision diamonds for real gates.
- If using bilingual/localized labels (e.g., `"EN\nAR"`), source translated labels from the project's glossary or `i18n-ux-copy` skill.
- Use subgraphs for layout grouping only.

## Dual Theme Pipeline (Docs vs Presentation)

When a repository maintains a dual Mermaid export pipeline (e.g., `docs/graphs/theme.json` for light/teal docs gallery and `docs/graphs/theme-noir.json` for dark 16:9 decks):
- Keep shared `.mmd` files structure-only (quoted labels + `class id hud*` + preview `%%{init}%%` with `htmlLabels: false`, no hardcoded dark `classDef` hex).
- Let the exporter strip init and inject theme `classDef`s.
- Regenerate only the requested surface; do not overwrite docs gallery SVGs unless asked.

## HUD accents

- Cyan `#22D3EE` -- hub, active/success states
- Amber `#F59E0B` -- pending / specialist review
- Crimson `#E11D48` -- blocked / SLA breach / reject / 4xx
- Mist `#94A3B8` -- decision diamonds
- Gray `#8B949E` -- secondary / stay-open flags

Edges >= 2.75px; arrowheads high-contrast for projection.

## Workflow

1. Confirm logic with `business-analyst` or canonical doc -- do not invent edges.
2. Edit `.mmd` structure + stacked labels + `class hud*` only (quotes, subgraphs, ids).
3. Regenerate the matching export if an export pipeline exists.
