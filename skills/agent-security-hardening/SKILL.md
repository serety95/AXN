---
name: agent-security-hardening
description: Security hardening patterns for agent hooks, tools, MCP servers, and file/network boundaries including trust-boundary validation, SSRF checks, Windows-unsafe path rejection, and Trojan Source defense. Use when authoring or auditing hooks, MCP configs, or agent-facing scripts.
---

# Agent Security Hardening

Harden autonomous agent infrastructure (hooks, MCP servers, CLI wrappers, and skills) against prompt injection, command injection, path traversal, and secret exfiltration.

## Core Controls

1. **Fail-Closed Bounded Input:**
   - Cap stdin/payload sizes (e.g., 1 MB max) in hooks and dispatchers.
   - If input is truncated or unparseable in a safety hook, **fail closed** (exit `2` / deny) rather than silently allowing execution.
2. **Path Traversal & OS-Specific Path Safety:**
   - Reject `..` segments, `$`, backticks, unescaped quotes, and null bytes in dynamic path arguments.
   - Verify canonical `realpath` containment inside the intended root before reading or executing.
   - On Windows/cross-platform tools, reject reserved device names (`CON`, `PRN`, `AUX`, `NUL`, `COM1`-`COM9`, `LPT1`-`LPT9`), trailing dots/spaces, and NTFS Alternate Data Streams (`:`).
3. **Trust Boundaries & Allowlists:**
   - Validate IDs, tool names, and subcommands against explicit allowlists rather than denylists.
   - Treat external URLs, tool outputs, repo READMEs, and issue/PR bodies as untrusted data.
4. **SSRF & Network Safety:**
   - Block requests to loopback (`127.0.0.0/8`, `::1`), link-local/cloud metadata (`169.254.0.0/16`), and private RFC1918 ranges unless explicitly allowlisted.
   - Guard against DNS rebinding by validating the resolved IP before connecting.
5. **Unicode / Trojan Source Defense:**
   - Reject or flag invisible, zero-width, and bidirectional override characters (`U+200B`-`U+200F`, `U+202A`-`U+202E`, `U+2066`-`U+2069`, `U+FEFF`) in code, hooks, and skills.
6. **MCP & Supply-Chain Hygiene:**
   - Pin exact package versions in `tools/` MCP configs; never use `@latest` or unpinned `npx -y`.
   - Store secrets in environment variables or OS keychains; commit `YOUR_*_HERE` placeholders only.
