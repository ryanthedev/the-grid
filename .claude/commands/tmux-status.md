# tmux-status

Enumerate every tmux session and window, analyze pane content to determine window state,
and write the result atomically to `$XDG_STATE_HOME/thegrid/tmux-status.json`.

This command runs the tmux-status skill, which uses `tmux` commands directly
(no MCP) for maximum compatibility and speed. See `.claude/skills/tmux-status/SKILL.md` for implementation details.

## Execution

The skill implementation runs automatically, performing these steps:

1. Lists all tmux sessions with metadata (activity timestamp, attached state)
2. For each session, enumerates all windows with their metadata
3. For each window, captures pane content via `tmux capture-pane`
4. Analyzes pane content to determine: command, statusKind, and summary
5. Applies staleness rule (>300s idle = downgrade to idle status)
6. Writes JSON atomically to `~/.local/state/thegrid/tmux-status.json`

## Output format

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
          "activity": 1718499995,
          "target": "work:0"
        }
      ]
    }
  ]
}
```

Each `windows[]` object carries an integer `activity` (`#{window_activity}`, the
Unix epoch of the window's last pane output). The dashboard renders it as a
relative age; an absent/`0` value means unknown (no age shown).

## statusKind values

- **active** — something is visibly happening (Claude typing, build running, editor with recent edits)
- **running** — long-running process executing (server, watcher) without active changes
- **waiting** — waiting for user input (Claude prompt, shell prompt, REPL ready)
- **idle** — quiescent, no activity and no input prompt
- **error** — pane capture failed or error condition visible

### Staleness gate (time-aware)

A window's `statusKind` is **downgraded to `idle`** when `generatedAt - activity > 300`
(no pane output for over 300 seconds), even if its scrollback text would otherwise read
`active`/`running`. The summary becomes `"idle — no output for <age>"`. Only `active`/`running`
are ever downgraded — `error`, `waiting`, and `idle` are never touched, and a missing/`0`
`activity` never triggers a downgrade. This keeps long-idle Claude sessions from spuriously
reading `active` and from flipping into `waiting` (which would trip the notification feature).

## Edge cases

- **tmux not running** → write `{"generatedAt": <ts>, "sessions": []}`
- **Pane capture fails for a window** → set `statusKind: "error"` and use error text as `summary`
- **Session has no windows** → valid, `"windows": []` for that session
- **State dir missing** → created automatically by script before writing
