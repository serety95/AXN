# AXN Lifecycle Hooks

Deterministic, zero-token shell guardrails organized by agent lifecycle event.

## Directory Layout

- `pre-tool-use/blast-radius-guard.sh` — `PreToolUse` (`Bash|Write|Edit|Read`): hard-blocks destructive shell commands, `--no-verify`, path traversal, secret file reads/writes, and hardcoded secret leaks.
- `pre-tool-use/config-protection.sh` — `PreToolUse` (`Write|Edit`): blocks modifications to *existing* linter, formatter, ignore, and `.ai/verify.cmd` configs so agents fix code rather than weakening checks (allows first-time creation; override with `AXN_ALLOW_CONFIG_EDIT=1`).
- `pre-tool-use/token-budget-guard.sh` — `PreToolUse` (`Read|View|Bash`): blocks unbounded reads/`cat` of lockfiles, minified/vendor/build noise, and massive files (`>600` lines or `>100 KiB`), while allowing bounded `offset`/`limit` or `StartLine`/`EndLine` slices (`AXN_TOKEN_GUARD_MODE=warn` to warn instead of block).
- `post-tool-use/auto-verify-loop.sh` — `PostToolUse` (`Edit|Write`): runs scoped syntax/lint/typecheck (`biome`, `tsc`, `ruff`, `cargo check`, `go vet`, `bash -n`/`shellcheck`) on the modified file and feeds errors back via `stderr` + exit `2`.
- `stop/stop-gate-verifier.sh` — `Stop`: runs repo-root `.ai/verify.cmd` (when present and inside repo boundaries) before allowing the agent to finish; exits `2` on failure and respects `stop_hook_active` to prevent infinite loops.
- `stop/orchestrator-feedback.sh` — `Stop`: fail-open (`exit 0`) telemetry collector that prioritizes `last_assistant_message` over `transcript_path`, rejects `<...>`/`|` placeholders, derives deterministic `passed` and `retries` from repo-scoped `${AXN_STRIKE_DIR}/${REPO_KEY}/turn-state.json` + `.count` files, and pipes JSON via stdin to `scripts/learn-router.py --ingest-stdin`.
- `pre-submit-prompt/route-skills.mjs` — `beforeSubmitPrompt` (Cursor / prompt-router): fail-open keyword router injecting relevant AXN skill/agent suggestions.
- **ECC Hook Superset (`hooks.json`, `hooks.metadata.json`, `codex-hooks.json`, `antigravity-hooks.json`, `qoder-hooks.json`, `memory-persistence/`, `hermes/`, `scripts/hooks/`, `scripts/lib/`)**: Full ECC cross-runtime hook manifests and Node/shell hook library imported alongside AXN's zero-dependency `.sh` guardrails (`ecc-README.md` documents the ECC layout).

## Hook Contract

| Exit Code | Meaning | Effect |
| :--- | :--- | :--- |
| `0` | Allow / Clean | Tool call or turn proceeds |
| `2` | Hard Block | Action blocked; `stderr` is fed back to the agent |

## Security Guarantees

1. **Fail-Closed Bounded Input:** Guard hooks cap `stdin` at `AXN_HOOK_MAX_BYTES` (default `1048576` = 1 MiB) and exit `2` on truncated or unparseable safety payloads.
2. **Zero Command Injection:** Tool inputs are parsed via `jq`, `python3`/`python`, or `node` reading `stdin`/env—never interpolated into `eval` or shell strings.
3. **Path Containment:** Rejects null bytes, `..` traversal escaping the workspace, NTFS Alternate Data Streams (`:`), and Windows reserved device names (`CON`, `NUL`, `COM1`–`COM9`, `LPT1`–`LPT9`).
