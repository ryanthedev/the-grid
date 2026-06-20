---
name: tmux-status
description: "Enumerate all tmux sessions and windows via the claude-mux MCP, AI-summarize each window's state, and atomically write the grid-notify dashboard's JSON status file at $XDG_STATE_HOME/thegrid/tmux-status.json. Use when asked to refresh the tmux dashboard, update or regenerate the tmux status file, or write a status snapshot of all tmux sessions. Not for: listing, attaching to, creating, killing, renaming, or sending keys/commands to tmux sessions or windows — those are direct claude-mux tmux operations, not a status-file write."
---

# Skill: tmux-status

Enumerate every tmux session and window, generate a one-line AI summary of each window's
current state, and atomically write the result to a JSON status file. The file is consumed
by the grid-notify SwiftUI dashboard (Phase 2–5) — callers read sessions→windows without
knowing how tmux state was obtained.

---

## Output Contract

### File path

```
$XDG_STATE_HOME/thegrid/tmux-status.json
```

Default: `~/.local/state/thegrid/tmux-status.json`

Write atomically: write to a temp file (`tmux-status.json.tmp`) in the same directory,
then rename over the target. Never leave a partial file at the real path.

### JSON schema

```json
{
  "generatedAt": 1718500000,
  "sessions": [
    {
      "name": "work",
      "attached": true,
      "activity": 1718499900,
      "windows": [
        {
          "index": 0,
          "name": "nvim",
          "command": "nvim",
          "active": true,
          "statusKind": "active",
          "summary": "editing api.go — cursor in handleRequest() function",
          "target": "work:0"
        }
      ]
    }
  ]
}
```

### Field types

| Field | Type | Description |
|-------|------|-------------|
| `generatedAt` | integer | Unix epoch seconds (NOT milliseconds) at time of write. Get the real value with Bash `date +%s` — never copy the example or guess it. |
| `sessions` | array | All tmux sessions; empty array `[]` if tmux is not running |
| `sessions[].name` | string | Session name as returned by `tmux list-sessions` |
| `sessions[].attached` | boolean | `true` if a client is attached, from `#{session_attached}` (step 2b) — never inferred from pane output |
| `sessions[].activity` | integer | Unix epoch seconds of the session's last activity (`#{session_activity}`). The dashboard ranks sessions by this — newest at the bottom. Omit only if unobtainable; the dashboard treats absent as `0`. |
| `sessions[].windows` | array | All windows in this session |
| `windows[].index` | integer | Window index (0-based) |
| `windows[].name` | string | Window name from tmux |
| `windows[].command` | string | Current foreground command (e.g. `nvim`, `zsh`, `claude`) |
| `windows[].active` | boolean | Whether this is the session's currently active window |
| `windows[].statusKind` | string | See statusKind vocabulary below |
| `windows[].summary` | string | One-line AI summary of what is happening in this window |
| `windows[].target` | string | tmux target in `session:window` form (e.g. `work:0`) for pane capture |

### statusKind vocabulary

Exactly one of these five values — no other strings are valid:

| Value | Meaning |
|-------|---------|
| `active` | Something is visibly happening or recently changed — Claude typing, a build running, a test suite in progress, an editor with recent activity |
| `running` | A long-running process is in the foreground and appears to be executing (e.g. a server, a watcher, a CI loop) but is not actively changing |
| `waiting` | Explicitly waiting for user input — a Claude Code prompt, a shell awaiting a command, a REPL at a prompt — NOTHING is running |
| `idle` | Process appears quiescent — no visible activity, no apparent input prompt (e.g. a shell with a completed command, a paused process) |
| `error` | The pane could not be captured, or an error condition is visible in the pane output |

Choose `waiting` when a Claude Code session is at its input prompt — this is the primary
signal the dashboard highlights for the user (which sessions need attention).

Choose `error` as `statusKind` and use the error description as `summary` when a pane
cannot be read (MCP returns an error for that target).

---

## Execution Steps

### 1. Check if tmux is running

Call `mcp__claude-mux__tmux` with `action: "list"`.

If the result contains `"error: no tmux sessions"` or indicates tmux is not running, write
the empty result immediately and stop:

```json
{ "generatedAt": <current unix epoch seconds>, "sessions": [] }
```

### 2. Enumerate sessions and windows

Parse the `list` output to get every session name. For each session, call
`mcp__claude-mux__tmux` with `action: "session", target: "<session-name>"` to get
the window list with pane previews.

The `list` output format is:
```
session-name/
  :0 window-name (1p)*      ← * marks active window
  :1 other-window (2p)
```

Extract: session name, window index, window name, active marker. (Attached state is NOT
reliably in this output — get it from tmux in step 2b, not by guessing.)

### 2b. Capture each session's activity time and attached state

Get the per-session activity epoch (for recency ranking) AND attached state directly from
tmux — the MCP output does not reliably report either. Run:

```bash
tmux list-sessions -F "#{session_name} #{session_activity} #{session_attached}"
```

Each line is `<session-name> <epoch-seconds> <attached>`, where `<attached>` is `1` when a
client is attached and `0` otherwise. Map both onto the matching session: `activity` = the
epoch; `attached` = (the third field is not `0`). Use these verbatim — never infer `attached`
from pane contents. If `tmux` is not reachable from this run, omit `activity` (the dashboard
defaults absent values to `0`) and set `attached: false` — do not abort the run.

### 3. Capture each window's pane

For each window, call `mcp__claude-mux__tmux` with `action: "tail", target: "<session>:<index>"`.
This returns the last 20 lines of the active pane — sufficient for summarization.

If a `tail` call returns an error for a specific window, set that window's `statusKind`
to `"error"` and use the error message as `summary`. Continue to the next window — do
not abort the entire run.

### 4. Determine command

The foreground command for a window is typically visible in the pane capture (e.g.
`nvim filename`, `npm run dev`, `claude`). Extract it from the pane output or the
window name. If not determinable, use the window name.

### 5. Generate AI summary and statusKind

For each window, synthesize a one-line summary from:
- The window name
- The pane capture (last 20 lines)
- The foreground command

The summary should be ≤80 characters and describe what is happening right now — not
what the window is in general. Examples:
- `"editing api.go — cursor in handleRequest()"`
- `"claude waiting for input at project prompt"`
- `"npm run dev watching — last change 2m ago"`
- `"zsh prompt, last command: git push (exited 0)"`
- `"error: cannot capture pane (target not found)"`

Assign `statusKind` based on the vocabulary above.

### 6. Write atomically

Assemble the full JSON object. Write to a temp file:
```
~/.local/state/thegrid/tmux-status.json.tmp
```

Use the Write tool with the complete JSON content, then rename the temp file to the
final path:

```bash
mv ~/.local/state/thegrid/tmux-status.json.tmp ~/.local/state/thegrid/tmux-status.json
```

The rename is atomic on the same filesystem — the file watcher in grid-notify will
never see a partial write.

---

## Edge Cases

| Situation | Behavior |
|-----------|----------|
| tmux not running / `list` returns error | Write `{"generatedAt": <ts>, "sessions": []}` — never crash |
| A specific pane cannot be captured | That window gets `statusKind: "error"`, error text as `summary`; all other windows proceed normally |
| Session has zero windows | `windows: []` for that session — valid |
| Temp file write fails | Do not rename; the existing file (if any) is preserved; log the error to stdout |
| State dir does not exist | Create `~/.local/state/thegrid/` before writing |

---

## Downstream Seams (for phases 2–6)

These constants are consumed by downstream phases — do not rename without updating all consumers.

### DistributedNotification names

```
com.thegrid.tmux.toggle    — show/hide the dashboard window + start/stop the driver
com.thegrid.tmux.refresh   — trigger an immediate refresh run
```

### Lockfile path

```
$XDG_STATE_HOME/thegrid/tmux-status.lock
```

Default: `~/.local/state/thegrid/tmux-status.lock`

The lockfile is used by `TmuxStatusDriver` (Phase 4) with `flock(2)` (POSIX advisory lock,
`LOCK_EX|LOCK_NB`) to guarantee single-instance execution. macOS has no `flock(1)` binary;
the lock is held by the Swift driver process, not by the skill/headless run itself.

### Output file path

```
$XDG_STATE_HOME/thegrid/tmux-status.json
```

Default: `~/.local/state/thegrid/tmux-status.json`

---

## Invocation Recipe (for Phase 4: TmuxStatusDriver)

The driver spawns headless Claude Code with the slash command. All arguments are
hardcoded constants — never interpolate config strings into the argument list.

```bash
/Users/r/.local/bin/claude \
  -p "/tmux-status" \
  --mcp-config '{"mcpServers":{"claude-mux":{"command":"bun","args":["/Users/r/repos/claude-mux.mcp/server.js"]}}}' \
  --allowedTools "mcp__claude-mux__tmux Write" \
  --permission-mode bypassPermissions \
  --plugin-dir /path/to/repo/.claude
```

### Notes on the recipe

- **Binary**: `/Users/r/.local/bin/claude` — the real Claude Code binary (Mach-O arm64).
  Do not use the shell alias `claude` (which resolves to a python wrapper in interactive
  shells). Resolve via `which claude` in a non-interactive shell (`/bin/zsh -c "which claude"`),
  or hardcode the known path and verify at startup.

- **`-p "/tmux-status"`**: invokes the `.claude/commands/tmux-status.md` slash command.
  This is the deterministic headless trigger — more reliable than relying on skill
  semantic matching under `-p`.

- **`--mcp-config`**: supplies the claude-mux MCP server inline as a JSON string.
  This is required because headless runs don't load `~/.claude.json` MCP servers by default
  (use `--strict-mcp-config` to suppress other servers if isolation is needed).

- **`--allowedTools "mcp__claude-mux__tmux Write"`**: minimum required permissions.
  `mcp__claude-mux__tmux` for reading tmux state; `Write` for writing the output file.
  Bash is not required (the mv rename is done via the Write tool + Bash, or inline via
  Bash if Write doesn't support rename — add `Bash(mv:*)` if needed).

- **`--permission-mode bypassPermissions`**: required for headless operation so the run
  does not prompt for approvals. Only safe because the allowed tools list is narrow.

- **`--plugin-dir /path/to/repo/.claude`**: loads the skill from the worktree's `.claude`
  directory. The driver should substitute the repo's absolute path here (known at compile
  time / config time). Without this, the `-p "/tmux-status"` slash command resolves to
  the command file (`.claude/commands/tmux-status.md`) but the skill's SKILL.md is not
  loaded — the command file is self-contained so this is acceptable.

- **cwd**: run from the repo root (`/Users/r/repos/theGrid` or the worktree path) so that
  the `.claude/commands/` directory is found and CLAUDE.md context is loaded.

### Minimal invocation (command-only, no skill loading)

If `--plugin-dir` is not available or the skill fails to load, the command file at
`.claude/commands/tmux-status.md` is self-contained and sufficient:

```bash
/Users/r/.local/bin/claude \
  -p "/tmux-status" \
  --mcp-config '{"mcpServers":{"claude-mux":{"command":"bun","args":["/Users/r/repos/claude-mux.mcp/server.js"]}}}' \
  --allowedTools "mcp__claude-mux__tmux Write Bash" \
  --permission-mode bypassPermissions
```

(Add `Bash` to `--allowedTools` to allow the `mv` rename step.)

---

## Sample Output (canonical)

Schema-valid JSON for testing decoders (Phase 2):

```json
{
  "generatedAt": 1718500000,
  "sessions": [
    {
      "name": "work",
      "attached": true,
      "activity": 1718499990,
      "windows": [
        {
          "index": 0,
          "name": "nvim",
          "command": "nvim",
          "active": true,
          "statusKind": "active",
          "summary": "editing api.go — cursor in handleRequest() function",
          "target": "work:0"
        },
        {
          "index": 1,
          "name": "server",
          "command": "npm",
          "active": false,
          "statusKind": "running",
          "summary": "npm run dev watching on port 3000 — no recent changes",
          "target": "work:1"
        }
      ]
    },
    {
      "name": "claude-mux",
      "attached": false,
      "activity": 1718499500,
      "windows": [
        {
          "index": 0,
          "name": "claude",
          "command": "claude",
          "active": true,
          "statusKind": "waiting",
          "summary": "claude waiting for input at prompt",
          "target": "claude-mux:0"
        }
      ]
    }
  ]
}
```

Empty-sessions sample (tmux not running):

```json
{
  "generatedAt": 1718500000,
  "sessions": []
}
```
