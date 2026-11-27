# AXN Tools & Pinned MCP Starter Configs

Stateless tool references and **version-pinned, placeholder-only** MCP server configurations (`mcp-servers.json`).

## MCP Hygiene Rules

1. **Never use `@latest`:** Every `npx` and `uvx` MCP server in `mcp-servers.json` is pinned to an explicit, reviewed version to prevent supply-chain drift.
2. **Never commit secrets or machine-local paths:** All credentials and local directories use `YOUR_*_HERE` placeholders. Inject real values only in your machine-local runtime config (`~/.claude.json`, `~/.cursor/mcp.json`, or `~/.codex/config.toml`) or via OS keychain / environment variables.
3. **Least-privilege scoping:**
   - For `filesystem`, pass only the specific workspace directory you are working in—never `/` or `~`.
   - For `github`, use a fine-grained PAT scoped to the target repositories only.
   - For `deja-vu`, keep `DEJA_OFFLINE=1` enabled when using local session recall.

## Using These Configs

Copy only the server entries you actually need into your runtime's local config file and replace `YOUR_*_HERE` placeholders:

- **Claude Code:** `~/.claude.json` (`mcpServers`)
- **Cursor:** `~/.cursor/mcp.json` (`mcpServers`)
- **Codex CLI:** `~/.codex/config.toml` (`[mcp_servers.<name>]`)
