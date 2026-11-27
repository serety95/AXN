# Repository Map (`.ai/MAP.md`)

> Compressed architectural index (<1,500 tokens). Update when module boundaries, entry points, or verification commands change.

## Overview
- **Purpose:** `<1-2 sentence summary of what this repository does>`
- **Primary Stack:** `<languages, frameworks, runtime versions>`

## Directory & Module Boundaries
| Path | Responsibility | Key Exports / Entry Points |
| :--- | :--- | :--- |
| `src/` | `<core domain logic>` | `<index.ts / main.py>` |
| `tests/` | `<unit & integration tests>` | `<test runner entry>` |
| `scripts/` | `<build, sync, CI helpers>` | `<validate.sh>` |

## Critical Invariants
- `<Invariant 1: e.g. All external inputs validated at API boundary>`
- `<Invariant 2: e.g. No machine-local paths or secrets in tracked files>`

## Verification Commands
- **Fast check:** `<typecheck / lint command>`
- **Full gate (`.ai/verify.cmd`):** `<test + build command>`
