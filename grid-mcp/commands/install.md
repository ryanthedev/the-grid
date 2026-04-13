---
description: Set up grid-mcp after plugin install. Checks for bun, installs dependencies, verifies MCP server.
argument-hint: (no arguments)
---

Set up grid-mcp in `${CLAUDE_PLUGIN_ROOT}`. Grid MCP uses **bun** as runtime. MCP server is declared in `.claude-plugin/plugin.json` — Claude Code wires it up automatically. This command handles dependency installation and verification.

## Steps

1. **Check for bun.** Run `command -v bun`.

2. **If bun is missing**, use AskUserQuestion:
   - "Install bun" — run `curl -fsSL https://bun.sh/install | bash` and tell user to restart shell (`exec $SHELL`)
   - "Cancel" — abort with message "Install bun from https://bun.sh and re-run /grid-mcp:install"

3. **Install dependencies** in plugin root:
   ```bash
   cd "${CLAUDE_PLUGIN_ROOT}" && bun install
   ```

4. **Verify MCP is reachable** by calling the `ping` MCP tool (no args). If tool returns successfully, MCP is healthy.
   If it fails, tell user to restart Claude Code so plugin registration is picked up.

5. **Print summary**: bun version, deps installed status (newly installed vs already up-to-date), MCP server status (healthy/unreachable).

## When to run

- Right after `/plugin install grid-mcp@rtd` (first install).
- After `claude plugin update grid-mcp@rtd` (the cached plugin path changes — `bun install` needs to run in the new directory).
- If the MCP server stops responding.
