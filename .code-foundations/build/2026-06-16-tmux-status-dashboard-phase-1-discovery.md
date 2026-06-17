# Discovery + Design: Phase 1 - Skill + data contract

## Files Found

- `/Users/r/repos/theGrid/.claude/worktrees/tmux-status-dashboard/.code-foundations/plans/2026-06-16-tmux-status-dashboard.md` — plan file, read in full
- `/Users/r/.claude.json` — global claude config with MCP server registrations (mcpServers key)
- `/Users/r/repos/claude-mux.mcp/server.js` — claude-mux MCP server source
- `/Users/r/.claude/skills/thegrid/SKILL.md` — existing skill for format reference
- `/Users/r/.local/bin/claude` — real Claude Code binary (Mach-O arm64)
- `~/.config/claude/wrap/claude-theme-wrap.py` — python wrapper alias for `claude` in interactive shells

## Current State

No `.claude/skills/` or `.claude/commands/` directories exist in the worktree yet. The `~/.local/state/thegrid/` directory exists (created). All files for this phase are net-new.

## Gaps

None material. All plan assumptions verified (see Assumption Verification below).

## Code Standards

From `docs/code-standards.md`:
- All logging via `jlog`/`JSONLogger` (JSONL to `~/.local/state/thegrid/`) — not applicable to the skill/command markdown files
- No inline trailing comments — applied in any shell snippets inside the skill
- Comments on their own line above code

From the skill files: comments-first per `code-clarity-and-docs`; every section explains WHY not just what.

## Test Infrastructure

Phase 1 has no Swift code. Validation is:
1. JSON schema hand-sample validated with `python3 -m json.tool` (DW-1.1)
2. Headless `claude -p` run with real tmux sessions (DW-1.2) — manual verification step documented below
3. Headless run with tmux not running (DW-1.3) — manual verification step documented below
4. Manual inspection of skill file for required constants (DW-1.4)

## Assumption Verification

| Assumption | Verified | Finding |
|---|---|---|
| claude-mux registered as `claude-mux` key → tool token `mcp__claude-mux__tmux` | YES | `~/.claude.json` mcpServers has key `"claude-mux"` with `bun /Users/r/repos/claude-mux.mcp/server.js`. MCP server name in server.js: `McpServer({ name: "claude-mux" })`. Tool name: `"tmux"`. Token = `mcp__claude-mux__tmux`. |
| claude binary path | YES | `/Users/r/.local/bin/claude` is a Mach-O arm64 binary (Claude Code). The shell alias `claude` → python wrapper, but wrapper calls `os.execvp("claude", ...)` which resolves to the binary in non-interactive/non-TTY contexts. For headless `-p`, use `/Users/r/.local/bin/claude` directly. |
| Skill trigger via `-p /tmux-status` | NEEDS VERIFICATION | `claude -p` triggers slash-command files from `.claude/commands/`. Skills (SKILL.md) are loaded via `--plugin-dir` and trigger on matching queries, not via `/name` directly. The reliable path for headless invocation: use the command file at `.claude/commands/tmux-status.md` + `claude -p "/tmux-status"`. The skill provides semantic triggering in interactive sessions. |
| claude-mux `tmux` tool exposes pane capture | YES | `server.js` has `read` action (capture-pane, 100 lines), `tail` action (last N lines), `session` action (session with pane previews), `list` action (all sessions/windows). Fully sufficient for summaries. |
| tmux binary | YES | `/opt/homebrew/bin/tmux`, running 10 named sessions. |

## DW Verification

| DW-ID | Done-When Item | Status | Test Cases |
|-------|---------------|--------|------------|
| DW-1.1 | JSON schema (fields, types, `statusKind` enum) documented in skill file | COVERED | Hand-author canonical JSON sample, validate with `python3 -m json.tool`. Schema fields, types, enum values all appear in SKILL.md. |
| DW-1.2 | Headless `claude` run writes schema-valid file matching `tmux ls`/`tmux list-windows` | COVERED (needs-manual-run) | Validate the JSON schema with a hand-authored sample via `python3 -m json.tool`. Full headless run requires manual execution — exact command documented in skill file and discovery. |
| DW-1.3 | With tmux not running, writes `{generatedAt, sessions:[]}` — no crash, valid JSON | COVERED (needs-manual-run) | Validate the no-sessions JSON sample with `python3 -m json.tool`. Full test requires tmux kill + headless run — documented as manual verification step. |
| DW-1.4 | Notification-name constants, lockfile path, invocation recipe recorded in skill file | COVERED | Inspect skill file — confirmed present: `com.thegrid.tmux.toggle`, `com.thegrid.tmux.refresh`, lockfile path, invocation recipe. |

**All items COVERED:** YES (DW-1.2 and DW-1.3 have a documented manual-verification component per the dispatch prompt's note on nested headless runs)

## Design: tmux-status skill and command contract

### Approaches Considered

1. **Skill-only** — SKILL.md in `.claude/skills/tmux-status/`, triggered via semantic matching in interactive sessions. Headless `-p` invocation relies on skill resolution + `--plugin-dir`.
2. **Command-only** — `.claude/commands/tmux-status.md` slash command. Headless `-p "/tmux-status"` is deterministic but the full prompt lives only in the command file.
3. **Skill + command fallback (chosen)** — skill carries the rich AI-facing documentation and is the canonical reference; command carries the literal prompt for deterministic headless invocation. Plan's chosen approach.

### Comparison

| Criterion | Skill-only | Command-only | Skill + Command |
|-----------|-----------|-------------|-----------------|
| Headless determinism | LOW — skill trigger not guaranteed with `-p` | HIGH — `/command-name` is deterministic | HIGH — command is fallback |
| Interactive discoverability | HIGH — surfaces in skill system | LOW — must know command name | HIGH — both paths work |
| Information hiding | HIGH — callers don't know how tmux was read | HIGH | HIGH |
| Single source of truth | YES | YES | MEDIUM — must keep both in sync |

### Choice: Skill + Command (Approach 3)
Rationale: Command file is the driver-facing interface (P4 uses it for the `-p` invocation); skill is the documentation layer for interactive use and for downstream phases to read the contract. Both live in the same worktree. The command file can be minimal and reference the skill for full docs.

### Depth Check
- The skill exposes a single behavioral contract: "read tmux, summarize, write JSON atomically"
- Hidden details: how sessions are enumerated, how panes are captured, how summaries are generated, atomic write mechanics
- Caller interface: just the output file path and JSON schema
- Common case complexity: simple — callers read one file, get structured data

## Prerequisites

- [x] Required files will be created (none exist yet)
- [x] `~/.claude.json` has `claude-mux` MCP server registered
- [x] `/Users/r/.local/bin/claude` binary verified
- [x] `/opt/homebrew/bin/tmux` binary verified
- [x] `~/.local/state/thegrid/` state directory exists

## Recommendation

BUILD
- Create `.claude/skills/tmux-status/SKILL.md` with full schema, recipe, constants
- Create `.claude/commands/tmux-status.md` with literal prompt for headless invocation
- Validate JSON samples with `python3 -m json.tool`
- Document manual headless verification commands

## Manual Verification Steps (for DW-1.2 and DW-1.3)

### DW-1.2: Headless run with tmux running
```bash
cd /Users/r/repos/theGrid/.claude/worktrees/tmux-status-dashboard
/Users/r/.local/bin/claude -p "/tmux-status" \
  --mcp-config '{"mcpServers":{"claude-mux":{"command":"bun","args":["/Users/r/repos/claude-mux.mcp/server.js"]}}}' \
  --allowedTools "mcp__claude-mux__tmux Write" \
  --permission-mode bypassPermissions \
  --plugin-dir /Users/r/repos/theGrid/.claude/worktrees/tmux-status-dashboard/.claude

# Then verify:
python3 -m json.tool ~/.local/state/thegrid/tmux-status.json
tmux ls | awk -F: '{print $1}' | sort
python3 -c "import json; d=json.load(open(os.path.expanduser('~/.local/state/thegrid/tmux-status.json'))); print([s['name'] for s in d['sessions']])"
```

### DW-1.3: Headless run without tmux
```bash
# Stop tmux (all sessions)
tmux kill-server 2>/dev/null || true
/Users/r/.local/bin/claude -p "/tmux-status" \
  --mcp-config '{"mcpServers":{"claude-mux":{"command":"bun","args":["/Users/r/repos/claude-mux.mcp/server.js"]}}}' \
  --allowedTools "mcp__claude-mux__tmux Write" \
  --permission-mode bypassPermissions \
  --plugin-dir /Users/r/repos/theGrid/.claude/worktrees/tmux-status-dashboard/.claude

# Then verify:
python3 -m json.tool ~/.local/state/thegrid/tmux-status.json
# Expected: {"generatedAt": <ts>, "sessions": []}
```
