# AXN Instincts Index

> Quick lookup index of active cross-session instincts. Add new entries using [TEMPLATE.md](TEMPLATE.md) and see [README.md](README.md) for the promotion lifecycle.

| ID | Category | Confidence | Summary |
| :--- | :--- | :---: | :--- |
| `ps51-no-and-chaining` | `shell` | `high` | Windows PowerShell 5.1 rejects `&&`; use separate lines or `; if ($LASTEXITCODE -eq 0)`. |
| `mcp-pin-versions` | `security` | `high` | Pin MCP server package versions in `tools/mcp-servers.json`; never use `@latest`. |
| `bounded-slice-reads` | `runtime` | `high` | Use `offset`/`limit` or `StartLine`/`EndLine` on large files; avoid reading lockfiles or minified assets. |
