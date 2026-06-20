# tmux-status

Enumerate every tmux session and window, analyze pane content to determine window state,
and write the result atomically to `~/.local/state/thegrid/tmux-status.json`.

This command triggers the skill implementation, which uses `tmux` commands directly
(no MCP) for maximum compatibility and speed.

## Execution

Run the implementation script:

```bash
python3 ~/.claude/skills/tmux-status/tmux-status.py
```

The script:
1. Lists all tmux sessions with metadata (activity, attached state)
2. For each session, lists all windows
3. For each window, captures pane content via `tmux capture-pane`
4. Analyzes pane content to determine: command, statusKind (active/running/waiting/idle/error), summary
5. Writes JSON atomically to ~/.local/state/thegrid/tmux-status.json

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
          "target": "work:0"
        }
      ]
    }
  ]
}
```

## statusKind values

- **active** — something is visibly happening (Claude typing, build running, editor with recent edits)
- **running** — long-running process executing (server, watcher) without active changes
- **waiting** — waiting for user input (Claude prompt, shell prompt, REPL ready)
- **idle** — quiescent, no activity and no input prompt
- **error** — pane capture failed or error condition visible

## Edge cases

- **tmux not running** → write `{"generatedAt": <ts>, "sessions": []}`
- **Pane capture fails for a window** → set `statusKind: "error"` and use error text as `summary`
- **Session has no windows** → valid, `"windows": []` for that session
- **State dir missing** → created automatically by script before writing
