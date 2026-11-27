---
name: gateguard
description: "PreToolUse fact-forcing gate that denies the first Edit/Write/Bash (including MultiEdit and NotebookEdit) attempt until the agent presents concrete facts (importers, data schemas, verbatim user instruction), then allows retry; A/B-tested at +2.25 quality points. Use when enabling or configuring the GateGuard hook, exempting paths via env vars, or handling first-touch denials."
metadata:
  origin: community
---

# GateGuard — Fact-Forcing Pre-Action Gate

A PreToolUse hook that forces Claude to investigate before editing. Instead of self-evaluation ("are you sure?"), it demands concrete facts. The act of investigation creates awareness that self-evaluation never did.

## When to Activate

- Working on any codebase where file edits affect multiple modules
- Projects with data files that have specific schemas or date formats
- Teams where AI-generated code must match existing patterns
- Any workflow where Claude tends to guess instead of investigating

## Core Concept

LLM self-evaluation doesn't work. Ask "did you violate any policies?" and the answer is always "no." This is verified experimentally.

But asking "list every file that imports this module" forces the LLM to run Grep and Read. The investigation itself creates context that changes the output.

**Three-stage gate:**

```
1. DENY  — block the first Edit/Write/Bash attempt
2. FORCE — tell the model exactly which facts to gather
3. ALLOW — permit retry after facts are presented
```

No competitor does all three. Most stop at deny.

## Evidence

Two independent A/B tests, identical agents, same task:

| Task | Gated | Ungated | Gap |
| --- | --- | --- | --- |
| Analytics module | 8.0/10 | 6.5/10 | +1.5 |
| Webhook validator | 10.0/10 | 7.0/10 | +3.0 |
| **Average** | **9.0** | **6.75** | **+2.25** |

Both agents produce code that runs and passes tests. The difference is design depth.

## Gate Types

### Edit / MultiEdit Gate (first edit per file)

MultiEdit is handled identically — each file in the batch is gated individually;
entries without their own `file_path` are gated as the call's `file_path`.
NotebookEdit is gated as an Edit of its `notebook_path`: same class, checked
key, credit and cap rules, the full questions (the cell change is not read),
and never a comment-only pass.

The questions depend on the target's class (see
[Questions by target class](#questions-by-target-class)). For **code**
targets the Edit gate asks:

```
Before editing {file_path}, present these facts:

1. List ALL files that import/require this file (search the tree — Glob/Grep, or find/grep via Bash)
2. List the public functions/classes affected by this change
3. If this file reads/writes data files, show field names, structure,
   and date format (use redacted or synthetic values, not raw production data)
4. Quote the user's current instruction verbatim
```

These four are the full set, asked whenever the change cannot be read with
confidence. When it can (see [Questions fit the change](#questions-fit-the-change)),
an edit that touches no public declaration asks instead for the call sites in
the file or its module that rely on the changed behaviour, and item 3 is
dropped when the change handles no data.

### Write Gate (first new file creation)

For **code** targets the Write gate asks:

```
Before creating {file_path}, present these facts:

1. Name the file(s) and line(s) that will call this new file
2. Confirm no existing file serves the same purpose (search the tree — Glob/Grep, or find/grep via Bash)
3. If this file reads/writes data files, show field names, structure,
   and date format (use redacted or synthetic values, not raw production data)
4. Quote the user's current instruction verbatim
```

Item 3 is dropped when the new content handles no data.

### Questions fit the change

For **code** targets the gate reads the change it is about to allow (Edit
`old_string`/`new_string`, every MultiEdit entry for the file, Write
`content`) and decides three things:

- **Public surface:** a line on either side declares or exposes a public name.
  JS/TS: `export`, `exports`, `public`, `declare` (`.d.ts` files always); Python:
  `def`/`class` not starting with `_`, dunders, `__all__`, a module-level public
  assignment such as `BASE_URL = ...` (`__init__.py` always); Go: capitalised
  `func`/`type`/`var`/`const` names, `package`, lines starting with a capital;
  Rust: `pub`, `impl`, `trait`, `extern`, `#[macro_export]`, `#[derive]`,
  `#[repr]`, `#[no_mangle]`; shell: function definitions,
  `export`, `declare -x`; PowerShell: `function`, `filter`, `param`,
  `Export-ModuleMember`, `[CmdletBinding`. A member of an exported container
  counts too, judged from the file: lines inside an exported interface, enum,
  type, object or export list, member declarations of an exported class,
  `__all__` entries, public class attributes and dataclass fields, and members
  of a `pub` enum, struct, trait or `use` list. Java, Kotlin, C#, C, C++ and batch
  files, and every Write, always count as touching it. Touching it keeps questions 1 and 2; otherwise both are
  replaced by "List the call sites in this file or its module that rely on the
  changed behaviour".
- **Data:** words for file I/O, formats (`json`, `csv`, `yaml`, …),
  serialisation, encodings, schemas, SQL, data stores, browser storage, dates
  and clock reads on either side; in shell scripts also
  redirection to a file, `curl`, `wget`, `jq` and PowerShell file and web
  cmdlets. Without them the data
  question is dropped. With `GATEGUARD_EXTERNAL_CONTRACT_QUESTION` on, a
  change that keeps the data question is also asked what outside the
  repository decides its format or semantics.
- **Trivial:** see [Comment and whitespace-only edits](#comment-and-whitespace-only-edits).

Supported extensions: `.js .mjs .cjs .jsx .ts .tsx .mts .cts .py .pyi .go .rs
.java .kt .kts .cs .c .h .cc .cpp .cxx .hpp .hh .hxx .sh .bash .zsh .ps1 .psm1
.bat .cmd`. Any other extension, a
missing or non-string field, more than 64 MultiEdit entries, a side over
64 KiB, or 256 KiB in total means the full questions, word for word: the
original four (importers, public API, data schemas, the user's instruction),
or five with `GATEGUARD_EXTERNAL_CONTRACT_QUESTION` on. Sensitive
and hard-linked targets and NotebookEdit calls always get the full questions. Other classes keep their class
questions. Each question has a stable id (`importers`, `public-api`,
`local-callers`, `callers`, `no-duplicate`, `data-schema`,
`external-contract` when opted in, `quote-instruction`, and one per class
question), listed in `docs/gateguard/change-profile.md`.

### Questions by target class

The code questions carry no signal for a `SKILL.md`, a README, a test, or a
YAML file, so the first-touch gate classifies the target first.

Classification uses the target's path relative to the project root
(`CLAUDE_PROJECT_DIR`, then the payload `cwd`, then the process directory),
so a project that lives under, say, `~/work/tests/` does not turn every file
into a test. A leading `.claude/worktrees/<name>/` is stripped, since a
worktree mirrors the project, but only when
`<root>/.claude/worktrees/<name>/.git` exists; otherwise the path stays under
`.claude`. On Windows-style paths (and any segment containing `::$`), trailing
dots/spaces and a `:stream` suffix are dropped first, so `CLAUDE.md.` and
`CLAUDE.md::$DATA` classify as `CLAUDE.md`. Targets outside the root are
classified by their absolute path. The path is lowercased and `/`-separated,
and the first match wins:

1. **instruction** — basename `CLAUDE.md`, `AGENTS.md`, `AGENT.md`,
   `GEMINI.md`, `SKILL.md`, `copilot-instructions.md`, `.cursorrules`, or
   `.windsurfrules`; any `.mdc` file; a `.md`/`.mdx`/`.txt` file under a
   `.claude`, `agents`, `commands`, `skills`, `rules`, `hooks`, `.cursor`,
   `.codex`, or `.opencode` directory; or a `*instructions*.md` file under
   `.github/`
2. **test** — `*.test.*`, `*.spec.*`, `test_*.py`, `*_test.py`, `*_test.go`,
   or anything under a `tests`, `test`, or `__tests__` directory
3. **prose** — `.md`, `.mdx`, `.txt`, `.rst`, `.adoc`
4. **config** — `.json`, `.jsonc`, `.yaml`, `.yml`, `.toml`, `.ini`, or a
   `.env` / `.env.*` file that does not end in a code extension (`.env.local`
   is config; `.env.example.ts` and `.envrc` are code)
5. **code** — everything else (a `.js` under `hooks/` or `skills/` is code)

Every class ends with "Quote the user's current instruction verbatim", keeps
the batch-sibling warning, and uses the same questions for Edit, MultiEdit,
and Write unless noted. Items marked *(search)* carry the suffix
"(search the tree — Glob/Grep, or find/grep via Bash)".

| Class | Questions |
|---|---|
| instruction | Name the harness/loader that reads this file (Claude Code, Codex, Cursor, OpenCode, …) and when it loads it · Describe what agent behaviour changes as a result · Confirm no existing instruction, skill, or agent file already covers this *(search)* |
| test | Name what behaviour is under test and which module/function it exercises · Name the existing test file(s) covering this module, or confirm none exist *(search)* |
| prose (Write) | Name any existing doc this supersedes or duplicates *(search)* · State where it will be linked or referenced from · Explain why a new file rather than editing an existing one |
| prose (Edit) | List other docs or code that reference the section being changed *(search)* · State what the change corrects or adds |
| config | Name which process/tool reads this file and when · Describe the effect of the change · Confirm no secrets or credentials are being written in plain text |

Condensed denials (after `GATEGUARD_FACT_FORCE_FULL_DENIALS`) carry a
one-line hint for the same class. For code targets the hint names the same
questions as the full denial, one short phrase each; an Edit whose change
cannot be read keeps the fixed hint (importers/callers, affected API, data
schemas if any) when the external-contract question is off. Opting in adds
its external-contract phrase. Besides the message text, the class only
decides [sibling collapse](#same-turn-sibling-creation-collapse): which files
may collapse, and that a sibling must share the first file's class.

### Destructive Bash Gate (every destructive command)

Triggers on: `rm -rf`, `git reset --hard`, `git push --force`, `drop table`, `drop database`, `drop schema`, `alter table ... drop column`, etc.

```
1. List all files/data this command will modify or delete
2. Write a one-line rollback procedure
3. Quote the user's current instruction verbatim
```

### Routine Bash Gate (once per session)

```
1. The current user request in one sentence
2. What this specific command verifies or produces
```

Read-only introspection does not use this gate up: until it fires, a command
whose every `;`, `|`, `&&` or `||` segment is `ls`, `pwd`, `cat`, `head`,
`tail`, `wc`, `grep`, `rg`, `find`, `fd`, `tree`, or `git status`/`log`/
`diff`/`show`/`ls-files`/`rev-parse`/`branch` with read-only options (in
PowerShell: `Get-ChildItem`, `Get-Content`, `Select-String`, `Get-Location`,
their aliases, `rg`, `git`) passes and is counted in
`routine_readonly_passes`. The first other command is still gated. Any
redirection, `tee`, substitution, backtick, variable, environment
assignment, wrapper (`env`, `sudo`, `xargs`, `sh -c`), unknown command,
`find -exec`/`-delete`, `fd -x`, `rg --pre`/`-z`, `tree -o`, `git` global option or
write/execute option, or PowerShell `$`, `@`, `(`, `{` or `--%` makes the
command ordinary. Destructive detection runs first, unchanged.

Session state expires after 8 idle hours when it is keyed by a session id or
transcript path, and after 30 idle minutes when it falls back to the project
directory.

## Parallel Batches and Partial Application

The first-touch gate evaluates each tool call independently. When the pending
call's own `tool_use_id` appears in the transcript, the gate can correlate
that call with its assistant message and record a same-file batch lock with
the first-touch denial. Later Edit, Write, MultiEdit entries and NotebookEdit
calls to that file are denied when their own pending `tool_use_id` identifies
the same assistant batch. These sibling denials use the `batch-deny` metric
and do not consume another first-touch denial from the denial budget.

Present the requested facts, then resend every denied edit to that file in a
new assistant message. A retry in another message keeps the usual checked-file
behavior. The lock does not make edits to different files transactional, and
nothing that already applied is rolled back.

The correlation requires evidence for the pending call. If its `tool_use_id`
is absent, the transcript is unavailable, or the pending call cannot be found,
the gate does not guess the newest assistant message or enforce a batch lock.
It retains the warning that sibling edits may already have applied. A checked
file can then pass through without a same-batch denial, so partial application
remains possible. Treat that warning literally:

- Send dependent edits to a not-yet-touched file sequentially when the harness
  cannot provide pending-call correlation. A definition and its first use, or
  an import and its call site, need reliable ordering.
- After a first-touch denial, present the facts, retry the denied edits, and
  re-read the file before building on anything else from the batch.


## Extended Reference

Detailed patterns, examples, and checklists were moved to [references/extended-guide.md](references/extended-guide.md) to keep `SKILL.md` under 500 lines.
