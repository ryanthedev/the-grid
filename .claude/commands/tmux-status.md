# tmux-status

Read every tmux session and window, generate a one-line AI summary of each window's
current state, and write the result atomically to `~/.local/state/thegrid/tmux-status.json`.

This command is the headless-invocation entry point for the grid-notify tmux dashboard
driver. It is self-contained — all logic is here so it works with or without the skill
file loaded.

---

## Instructions

### Step 1 — Check if tmux is running

Call `mcp__claude-mux__tmux` with `action: "list"`.

If the result contains `"error: no tmux sessions"` or otherwise indicates tmux is not
running, write the empty result and stop:

```json
{ "generatedAt": <current_unix_epoch_seconds>, "sessions": [] }
```

Write to `~/.local/state/thegrid/tmux-status.json.tmp` using the Write tool, then
rename to `~/.local/state/thegrid/tmux-status.json` using Bash `mv`. This two-step
atomic write ensures the file watcher never sees a partial file.

### Step 2 — Enumerate sessions and windows

Parse the `list` output. For each named session, call
`mcp__claude-mux__tmux` with `action: "session", target: "<session-name>"` to get the
window list with single-line pane previews.

### Step 3 — Capture each window's pane

For each window in each session, call `mcp__claude-mux__tmux` with
`action: "tail", target: "<session>:<window-index>"`.

If `tail` returns an error for a window, set that window's `statusKind` to `"error"`,
use the error message as `summary`, and continue to the next window.

### Step 4 — Build the JSON

For each window, produce a JSON object with these fields:

| Field | Type | Description |
|-------|------|-------------|
| `index` | integer | Window index (0-based) |
| `name` | string | Window name from tmux |
| `command` | string | Foreground command visible in pane (or window name if unclear) |
| `active` | boolean | Whether this is the session's active window (`*` marker in list output) |
| `statusKind` | string | Exactly one of: `active`, `running`, `waiting`, `idle`, `error` |
| `summary` | string | One-line description of what is happening now (≤80 chars) |
| `target` | string | `"<session>:<index>"` — e.g. `"work:0"` |

**statusKind values:**
- `active` — something is visibly happening (Claude typing, build running, editor with recent edits)
- `running` — a long-running process is in the foreground and executing (server, watcher)
- `waiting` — waiting for user input: a Claude Code prompt, a shell `$` prompt, a REPL ready for input
- `idle` — quiescent, no visible activity and no input prompt
- `error` — pane could not be captured; error text goes in `summary`

Use `waiting` for any Claude Code session showing its input prompt — this is the primary
signal the dashboard highlights.

### Step 5 — Write atomically

Assemble the complete JSON:

```json
{
  "generatedAt": <unix_epoch_seconds_integer>,
  "sessions": [...]
}
```

1. Create `~/.local/state/thegrid/` if it does not exist.
2. Write the JSON to `~/.local/state/thegrid/tmux-status.json.tmp` using the Write tool.
3. Run `mv ~/.local/state/thegrid/tmux-status.json.tmp ~/.local/state/thegrid/tmux-status.json` via Bash.

The `mv` is atomic on the same filesystem. Never leave a partial file at the final path.

---

## Edge Cases

- **tmux not running**: write `{"generatedAt": <ts>, "sessions": []}` — do not crash
- **Pane capture fails for one window**: set `statusKind: "error"`, error text as `summary`; continue
- **Session has no windows**: `"windows": []` for that session — valid
- **State dir missing**: create it with `mkdir -p ~/.local/state/thegrid/` before writing
