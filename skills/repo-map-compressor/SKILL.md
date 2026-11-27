---
name: repo-map-compressor
description: Extracts exported symbols, routes, and module boundaries into a compressed under-1500-token .ai/MAP.md index to eliminate blind codebase grepping. Use when onboarding to a repository, before planning large changes, or when the user asks to map a repo.
---

# Repo Map Compressor

Generate a compact, high-signal `.ai/MAP.md` (`< 1,500` tokens) so agents navigate directly to the right files instead of burning context grepping blindly.

## When to use

- First time working in a repository or unfamiliar module
- Before architectural planning or multi-file refactors
- When `.ai/MAP.md` is missing or stale after major structural changes

## Workflow

1. **Run the map generator** (or inspect manually if Python is unavailable):
   ```bash
   python ~/.axn/skills/repo-map-compressor/scripts/generate-map.py . --out .ai/MAP.md
   ```
2. **Verify token budget**: Keep `.ai/MAP.md` under ~1,500 tokens (~6,000 characters / ~120 lines). Trim noisy leaf files, generated artifacts, and test fixtures; keep entry points, public APIs, routes, schemas, and boundaries.
3. **Annotate boundaries**: Ensure the map clearly marks:
   - Entry points & CLI/server bootstraps
   - Core modules & owned responsibilities
   - Data/API/route boundaries & external integrations
   - Verification command (`.ai/verify.cmd` if present)
4. **Read `.ai/MAP.md` first** in subsequent turns before opening deep implementation files.

## Rules

- Never include secrets, `.env` values, or machine-local absolute paths in `.ai/MAP.md`.
- Prefer `path: SymbolA, SymbolB` one-liners over prose paragraphs.
- Regenerate rather than hand-maintaining stale symbol lists.
