<div align="center">

```text
    ___   _  __ _   __
   /   | | |/ // | / /
  / /| | |   //  |/ / 
 / ___ |/   |/ /|  /  
/_/  |_/_/|_/_/ |_/   
```

# AXN — Agent eXecution Network

**One harness to steer every coding agent.**  
Sync progressive skills, deterministic safety hooks, and self-healing verification loops across **Claude Code**, **Cursor**, and **Codex CLI** from a single source of truth.

[![Stars](https://img.shields.io/github/stars/<your-username>/AXN?style=flat-square&color=00F0FF&labelColor=0D1117)](https://github.com/<your-username>/AXN/stargazers)
[![License: MIT](https://img.shields.io/badge/license-MIT-white?style=flat-square&labelColor=0D1117)](LICENSE)
[![Claude Code](https://img.shields.io/badge/Claude%20Code-supported-D97757?style=flat-square&labelColor=0D1117)](#runtime-matrix)
[![Cursor](https://img.shields.io/badge/Cursor-supported-00A8E8?style=flat-square&labelColor=0D1117)](#runtime-matrix)
[![Codex CLI](https://img.shields.io/badge/Codex%20CLI-supported-10A37F?style=flat-square&labelColor=0D1117)](#runtime-matrix)

[Quickstart](#quickstart) · [Starter Modules](#starter-modules) · [Runtime Matrix](#runtime-matrix) · [Architecture](#architecture) · [Configuration](#configuration) · [Authoring Guide](#authoring-custom-modules)

</div>

---

<!-- Replace with a 10-second terminal GIF showing one edit syncing to Claude Code, Cursor, and Codex CLI -->
<!-- <p align="center"><img src="assets/demo.gif" alt="AXN Multi-Runtime Sync Demo" width="800" /></p> -->

## Why AXN?

Modern AI coding workflows break down in three predictable ways: configs drift across tools, agents waste tens of thousands of tokens grepping blindly, and LLMs confidently declare *"Done!"* on broken builds.

AXN fixes this at the **harness layer**—not by bloating your system prompts:

* **Zero-Drift Symlink Sync:** Edit a skill, agent persona, or hook once in `~/.axn`. It is immediately live across `~/.claude`, `~/.cursor`, and `~/.codex`.
* **Deterministic Guardrails:** Move safety rules, linters, and test gates out of natural-language prompts and into fast, zero-token shell hooks.
* **Progressive Context Disclosure:** Keep `SKILL.md` files lean (`<500` lines) with on-demand references and compressed `.ai/MAP.md` indexes so your context window stays sharp.
* **Atomic & Reversible:** Existing non-symlink files are automatically backed up before linking, and `--uninstall` cleanly removes only symlinks owned by AXN.

---

## Quickstart

### 1. One-Line Install

```bash
git clone https://github.com/<your-username>/AXN.git ~/.axn && ~/.axn/scripts/sync.sh
```

### 2. Optional CLI Alias

Add this to your `~/.zshrc` or `~/.bashrc` for instant access:

```bash
alias axn="~/.axn/scripts/sync.sh"
```

### 3. Targeted Sync, Preview & Rollback

```bash
# Preview every symlink action without modifying your filesystem
~/.axn/scripts/sync.sh --dry-run

# Sync specific runtimes only
~/.axn/scripts/sync.sh --claude --codex

# Cleanly unlink only symlinks managed by AXN
~/.axn/scripts/sync.sh --uninstall
```

> **Safe by default:** AXN never clobbers existing local files. Any pre-existing non-symlink file or directory at a target path is automatically backed up to `<target>.bak.<timestamp>`.

---

## Starter Modules

AXN ships with **5 battle-tested modules** (3 deterministic lifecycle hooks + 2 high-leverage skills) ready on Day 1:

| Module | Type | Trigger / Invocation | Core Problem Solved |
| :--- | :--- | :--- | :--- |
| **`blast-radius-guard`** | `PreToolUse` Hook | Before `Bash`, `Write`, or `Edit` | Hard-blocks destructive shell commands (`rm -rf /`, `--force` push, `DROP TABLE`, `chmod 777`) before execution. |
| **`auto-verify-loop`** | `PostToolUse` Hook | After `Edit` or `Write` | Runs scoped `tsc`, `biome`, `ruff`, or `cargo check` on modified files and feeds errors back so the agent self-heals in the same turn. |
| **`stop-gate-verifier`** | `Stop` Hook | When agent attempts to finish | Checks `git status` and runs your fast test suite (`.ai/verify.cmd`); blocks completion until tests pass. |
| **`repo-map-compressor`** | Skill | *"Map this repo"* / onboarding | Extracts exported symbols, routes, and boundaries into a `<1,500`-token `.ai/MAP.md` index to slash codebase exploration burn. |
| **`adversarial-diff-audit`** | Skill | *"Audit my diff"* / pre-PR | Zero-praise, staff-level review of `git diff` targeting auth flaws, race conditions, N+1 leaks, and unhandled error paths. |

### How the Self-Healing Loop Works

```text
Agent proposes tool call
        │
        ▼
[PreToolUse]  blast-radius-guard.sh  ──(destructive?)──▶ Exit 2 (Hard Block + Reason)
        │ (safe)
        ▼
Tool executes (Edit / Write / Bash)
        │
        ▼
[PostToolUse] auto-verify-loop.sh    ──(lint/type err)─▶ Feeds stderr back to Agent
        │ (clean)
        ▼
Agent attempts to finish turn
        │
        ▼
[Stop]        stop-gate-verifier.sh  ──(tests fail?)───▶ Exit 2 (Forces fix loop)
        │ (green)
        ▼
Task complete ✓
```

---

## Runtime Matrix

AXN maps a single unified repository layout into the native paths expected by each runtime:

| Monorepo Source | Claude Code (`~/.claude`) | Cursor (`~/.cursor`) | Codex CLI (`~/.codex`) |
| :--- | :--- | :--- | :--- |
| `skills/<name>/` | `~/.claude/skills/<name>` | `~/.cursor/skills/<name>` | `~/.codex/skills/<name>` |
| `agents/<name>.md` | `~/.claude/agents/<name>.md` | `~/.cursor/rules/<name>.mdc` | *(loaded via `AGENTS.md`)* |
| `hooks/` | `~/.claude/hooks` | `~/.cursor/hooks` | *Roadmap* |
| `templates/GLOBAL_AGENTS.md` | `~/.claude/CLAUDE.md` | `~/.cursor/rules/global.mdc` | `~/.codex/AGENTS.md` |

| Capability | Claude Code | Cursor | Codex CLI |
| :--- | :---: | :---: | :---: |
| **Skills (`SKILL.md`)** | Native | Native | Native |
| **Sub-Agents / Rules** | Full | Full | Via `AGENTS.md` |
| **Lifecycle Hooks** | Full | Full | Planned |
| **Global Instructions** | Full | Full | Full |

---

## Architecture

```text
AXN/
├── agents/                     # Sub-agent personas (architect, reviewer, security)
│   ├── architect.md
│   └── reviewer.md
├── skills/                     # Progressive-disclosure skills (<500 lines in SKILL.md)
│   ├── repo-map-compressor/
│   │   ├── SKILL.md
│   │   └── scripts/
│   └── adversarial-diff-audit/
│       └── SKILL.md
├── hooks/                      # Deterministic guardrails organized by lifecycle event
│   ├── pre-tool-use/
│   │   └── blast-radius-guard.sh
│   ├── post-tool-use/
│   │   └── auto-verify-loop.sh
│   └── stop/
│       └── stop-gate-verifier.sh
├── tools/                      # Lightweight stateless CLIs & MCP client configs
│   ├── cli/
│   └── mcp-configs/
├── templates/                  # Shared global instructions & project map templates
│   ├── GLOBAL_AGENTS.md
│   └── MAP.template.md
└── scripts/
    ├── sync.sh                 # Idempotent multi-runtime symlink manager
    └── validate.sh             # CI check: YAML frontmatter, permissions & shellcheck
```

---

## Configuration

### 1. Why Machine-Local Configs Are Not Symlinked
AXN deliberately **does not symlink** `~/.claude/settings.json` or `~/.codex/config.toml`. Those files contain machine-local auth state, model preferences, and permissions. Instead, keep them local and point their hook entries at your synced `~/.claude/hooks/` paths.

### 2. Wiring Hooks in Claude Code (`~/.claude/settings.json`)

```json
{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "Bash|Write|Edit",
        "hooks": [
          {
            "type": "command",
            "command": "~/.claude/hooks/pre-tool-use/blast-radius-guard.sh"
          }
        ]
      }
    ],
    "PostToolUse": [
      {
        "matcher": "Edit|Write",
        "hooks": [
          {
            "type": "command",
            "command": "~/.claude/hooks/post-tool-use/auto-verify-loop.sh"
          }
        ]
      }
    ],
    "Stop": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "~/.claude/hooks/stop/stop-gate-verifier.sh"
          }
        ]
      }
    ]
  }
}
```

### 3. Per-Project Test Gate (`.ai/verify.cmd`)

To enable `stop-gate-verifier` in any repository, drop a single-line command in `.ai/verify.cmd` at the project root:

```bash
# Example for a TypeScript project
npm run typecheck && npm test -- --run

# Example for a Python project
pytest -q
```

---

## Authoring Custom Modules

### Adding a Skill
Create a new folder under `skills/<skill-name>/SKILL.md` with valid YAML frontmatter:

```markdown
---
name: my-skill-name
description: Concise trigger description explaining when the agent should load this skill.
---

# Skill Instructions
Keep SKILL.md under 500 lines. Move heavy reference docs to `references/` and executable logic to `scripts/`.
```

### Adding a Hook
1. Place your script in `hooks/pre-tool-use/`, `hooks/post-tool-use/`, or `hooks/stop/`.
2. Mark it executable in Git so fresh clones work immediately:
   ```bash
   git update-index --chmod=+x hooks/<event>/<your-hook>.sh
   ```
3. Use exit code `0` to allow, or exit code `2` (with an explanation on `stderr`) to hard-block and feed instructions back to the agent.

### Validation
Run the validation suite locally before committing or opening a PR:

```bash
./scripts/validate.sh
```

This checks:
* Valid YAML frontmatter across all `skills/*/SKILL.md` files
* Executable permissions (`+x`) on all scripts under `hooks/` and `scripts/`
* Zero broken symlinks and clean `shellcheck` passes

---

## Roadmap

* [ ] **Project-level sync mode** (`axn --project ./my-app`) for per-repo `.claude/` and `.cursor/` overrides
* [ ] **Manifest-driven selective installs** (`install-plan` / `install-apply` with state tracking)
* [ ] **Additional runtime adapters** for Gemini CLI, OpenCode, and Zed
* [ ] **Continuous learning loop** to extract recurring session fixes into reusable skills

---

## Contributing

Pull requests for new high-signal skills, deterministic hooks, and runtime adapters are welcome.

1. Fork the repository and create your feature branch (`git checkout -b feat/my-skill`).
2. Keep skills focused, tool-agnostic where possible, and under 500 lines.
3. Run `./scripts/validate.sh` and ensure all checks pass.
4. Open a Pull Request describing the exact pain point your module solves.

---

## License

Released under the [MIT License](LICENSE). Fork it, adapt it, and ship faster.
