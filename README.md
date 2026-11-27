<div align="center">

```text
    ___   _  __ _   __
   /   | | |/ // | / /
  / /| | |   //  |/ / 
 / ___ |/   |/ /|  /  
/_/  |_/_/|_/_/ |_/   
```

# AXN — Agent eXecution Network

**The multi-runtime agent harness operating system.**  
*Your agent can write code, but AXN gives it a coordinated engineering system: it plans before it builds, verifies every edit, blocks destructive actions, and persists instincts across sessions.*

[![Stars](https://img.shields.io/github/stars/<your-username>/AXN?style=flat-square&color=00F0FF&labelColor=0D1117)](https://github.com/<your-username>/AXN/stargazers)
[![Forks](https://img.shields.io/github/forks/<your-username>/AXN?style=flat-square&color=white&labelColor=0D1117)](https://github.com/<your-username>/AXN/network/members)
[![License: MIT](https://img.shields.io/badge/license-MIT-white?style=flat-square&labelColor=0D1117)](LICENSE)
[![Claude Code](https://img.shields.io/badge/Claude%20Code-native-D97757?style=flat-square&labelColor=0D1117)](#runtime-matrix)
[![Cursor](https://img.shields.io/badge/Cursor-native-00A8E8?style=flat-square&labelColor=0D1117)](#runtime-matrix)
[![Codex CLI](https://img.shields.io/badge/Codex%20CLI-native-10A37F?style=flat-square&labelColor=0D1117)](#runtime-matrix)

[Quickstart](#-quickstart) · [The AXN Loop](#-the-axn-engineering-loop) · [Starter Modules](#-starter-modules) · [Security & Shield](#-security--agent-shield) · [Runtime Matrix](#-runtime-matrix) · [Architecture](#-architecture) · [Guides](#-guides--docs)

</div>

---

> [!WARNING]
> **Official sources only.** Install AXN exclusively from `github.com/<your-username>/AXN`. Third-party re-uploads and unofficial mirrors are not maintained or reviewed and may contain malicious hooks or prompt injections.

---

## Why AXN?

Modern AI coding workflows break down in four predictable ways: configs drift across tools, agents burn tens of thousands of tokens grepping blindly, LLMs declare *"Done!"* on broken builds, and hard-won session lessons vanish the moment you close the chat.

AXN solves this at the **harness layer**—optimizing your active context window while persisting skills, instincts, memory, and deterministic verification outside ephemeral chat history:

*   **Zero-Drift Symlink Sync:** Edit a skill, agent persona, or hook once in `~/.axn`. It is immediately live across `~/.claude`, `~/.cursor`, and `~/.codex`.
*   **Deterministic Guardrails:** Move safety rules, linters, secret scans, and test gates out of natural-language prompts and into fast, zero-token shell hooks.
*   **Continuous Learning & Instincts:** Extract recurring bug fixes, codebase conventions, and architectural decisions into durable, reusable instincts instead of re-prompting from scratch.
*   **Progressive Context Disclosure:** Keep `SKILL.md` files lean (`<500` lines) with on-demand references and compressed `.ai/MAP.md` indexes so your context window stays sharp.
*   **Atomic & Reversible:** Existing non-symlink files are automatically backed up before linking, and `--uninstall` cleanly removes only symlinks owned by AXN.

---

## The AXN Engineering Loop

AXN standardizes autonomous development around a closed, self-healing workflow:

```text
plan ──▶ test ──▶ implement ──▶ review ──▶ verify ──▶ remember ──▶ improve
```

1.  **Plan:** Map repository boundaries (`.ai/MAP.md`) and design before writing a single line.
2.  **Test:** Define acceptance criteria and failing test cases up front.
3.  **Implement:** Execute edits under `PreToolUse` blast-radius protection and `PostToolUse` scoped typechecks.
4.  **Review:** Run `adversarial-diff-audit` to catch auth flaws, race conditions, and memory leaks.
5.  **Verify:** Enforce `stop-gate-verifier`—the agent cannot finish until builds and tests are green.
6.  **Remember & Improve:** Distill recurring fixes into durable skills and instincts for future sessions.

---

## Quickstart

### 1. One-Line Install

```bash
git clone https://github.com/<your-username>/AXN.git ~/.axn && ~/.axn/scripts/sync.sh
```

### 2. Optional CLI Alias

Add this to your `~/.zshrc` or `~/.bashrc`:

```bash
alias axn="~/.axn/scripts/sync.sh"
```

### 3. Targeted Sync, Dry-Run & Safe Rollback

```bash
# Preview every symlink action without modifying your filesystem
axn --dry-run

# Sync specific runtimes only
axn --claude --codex

# Cleanly unlink only symlinks managed by AXN
axn --uninstall
```

> [!NOTE]
> **Avoid stacking duplicate installs.** Choose either AXN's symlink sync or a native runtime plugin—do not stack a manual copy on top of a symlinked target. Existing non-symlink files are automatically backed up to `<target>.bak.<timestamp>`.

---

## Starter Modules

AXN ships with **5 battle-tested modules** (3 deterministic lifecycle hooks + 2 high-leverage skills) ready on Day 1:

| Module | Type | Trigger / Invocation | Core Problem Solved |
| :--- | :--- | :--- | :--- |
| **`blast-radius-guard`** | `PreToolUse` Hook | Before `Bash`, `Write`, or `Edit` | Hard-blocks destructive shell commands (`rm -rf /`, `--force` push, `DROP TABLE`, `chmod 777`) and `.env` leaks before execution. |
| **`auto-verify-loop`** | `PostToolUse` Hook | After `Edit` or `Write` | Runs scoped `tsc`, `biome`, `ruff`, or `cargo check` on modified files and feeds errors back so the agent self-heals in the same turn. |
| **`stop-gate-verifier`** | `Stop` Hook | When agent attempts to finish | Checks `git status` and runs your fast test suite (`.ai/verify.cmd`); blocks completion until tests pass. |
| **`repo-map-compressor`** | Skill | *"Map this repo"* / onboarding | Extracts exported symbols, routes, and boundaries into a `<1,500`-token `.ai/MAP.md` index to slash codebase exploration burn. |
| **`adversarial-diff-audit`** | Skill | *"Audit my diff"* / pre-PR | Zero-praise, staff-level review of `git diff` targeting auth flaws, race conditions, N+1 leaks, and unhandled error paths. |

### How the Self-Healing Hook Loop Works

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

## Security & Agent Shield

Autonomous agents with shell and MCP access expand your attack surface. AXN enforces security by default:

*   **Zero-Token Command Blocking:** `blast-radius-guard` intercepts destructive commands and secret reads deterministically before they hit your OS.
*   **Config & MCP Hygiene:** Keep machine-local `settings.json`, `config.toml`, and API keys out of version control; pin MCP server versions instead of using `@latest`.
*   **Pre-Merge Security Audits:** `adversarial-diff-audit` scans staged diffs for injection vectors, broken auth checks, and leaked credentials before code leaves your machine.

---

## Runtime Matrix

AXN maps a single unified repository layout into the native paths expected by each runtime:

| Monorepo Source | Claude Code (`~/.claude`) | Cursor (`~/.cursor`) | Codex CLI (`~/.codex`) |
| :--- | :--- | :--- | :--- |
| `skills/<name>/` | `~/.claude/skills/<name>` | `~/.cursor/skills/<name>` | `~/.codex/skills/<name>` |
| `agents/<name>.md` | `~/.claude/agents/<name>.md` | `~/.cursor/rules/<name>.mdc` | *(loaded via `AGENTS.md`)* |
| `hooks/` | `~/.claude/hooks` | `~/.cursor/hooks` | *Roadmap* |
| `templates/GLOBAL_AGENTS.md` | `~/.claude/CLAUDE.md` | `~/.cursor/rules/global.mdc` | `~/.codex/AGENTS.md` |

| Harness | Skills (`SKILL.md`) | Sub-Agents / Rules | Lifecycle Hooks | Status |
| :--- | :---: | :---: | :---: | :--- |
| **Claude Code** | Native | Full | Full | **Supported** |
| **Cursor** | Native | Full (`.mdc`) | Full | **Supported** |
| **Codex CLI** | Native | Via `AGENTS.md` | Planned | **Supported** |
| **Gemini CLI / OpenCode / Zed** | Planned | Planned | Planned | **Roadmap** |

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
├── instincts/                  # Persistent cross-session learnings & distilled patterns
├── manifests/                  # Selective install profiles & runtime capability maps
├── tools/                      # Lightweight stateless CLIs & pinned MCP client configs
├── templates/                  # Shared GLOBAL_AGENTS.md and .ai/MAP.md templates
└── scripts/
    ├── sync.sh                 # Idempotent multi-runtime symlink manager
    └── validate.sh             # CI check: YAML frontmatter, permissions & shellcheck
```

---

## Configuration

### 1. Why Machine-Local Configs Are Not Symlinked

AXN deliberately **does not symlink** `~/.claude/settings.json` or `~/.codex/config.toml`. Those files contain machine-local auth state, model preferences, and permissions. Keep them local and point their hook entries at your synced `~/.claude/hooks/` paths.

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

Drop a single-line verification command in `.ai/verify.cmd` at any repository root to activate `stop-gate-verifier`:

```bash
# TypeScript / Node
npm run typecheck && npm test -- --run

# Python
pytest -q

# Rust
cargo test --quiet
```

---

## Authoring Custom Modules

### Adding a Skill

Create `skills/<skill-name>/SKILL.md` with valid YAML frontmatter:

```markdown
---
name: my-skill-name
description: Concise trigger description explaining when the agent should load this skill.
---

# Skill Instructions
Keep SKILL.md under 500 lines. Move heavy reference docs to `references/` and executable logic to `scripts/`.
```

### Adding a Hook

1.  Place your script in `hooks/pre-tool-use/`, `hooks/post-tool-use/`, or `hooks/stop/`.
2.  Mark it executable in Git so fresh clones work immediately:
    ```bash
    git update-index --chmod=+x hooks/<event>/<your-hook>.sh
    ```
3.  Exit `0` to allow, or exit `2` (with a clear reason on `stderr`) to hard-block and feed instructions back to the agent.

### Validation

Run the validation suite locally before committing or opening a PR:

```bash
./scripts/validate.sh
```

---

## Guides & Docs

*   `docs/shortform-guide.md` — 5-minute setup and daily workflow cheat sheet
*   `docs/security-guide.md` — Hardening hooks, MCP permissions, and secret boundaries
*   `TROUBLESHOOTING.md` — Resolving symlink conflicts, hook exit codes, and runtime quirks

---

## Roadmap

*   [ ] **Manifest-driven selective installs** (`install-plan` / `install-apply` + `doctor` / `repair` state tracking)
*   [ ] **Project-level sync mode** (`axn --project ./my-app`) for per-repo `.claude/` and `.cursor/` overrides
*   [ ] **Continuous learning pipeline** to automatically extract recurring session fixes into `instincts/`
*   [ ] **Expanded harness adapters** for Gemini CLI, OpenCode, Zed, and GitHub Copilot
*   [ ] **Built-in Security Scanner** (`axn shield`) to audit prompts, hooks, and MCP configs for leaks

---

## Contributing

Pull requests for new high-signal skills, deterministic hooks, and runtime adapters are welcome.

1.  Fork the repository and create your feature branch (`git checkout -b feat/my-skill`).
2.  Keep skills focused, tool-agnostic where possible, and under 500 lines.
3.  Run `./scripts/validate.sh` and ensure all checks pass.
4.  Open a Pull Request describing the exact pain point your module solves.

## License

Released under the [MIT License](LICENSE). Open-source forever—fork it, adapt it, and ship faster.
