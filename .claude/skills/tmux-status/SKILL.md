---
name: tmux-status
description: "Enumerate all tmux sessions and windows, analyze pane content, and generate a dashboard JSON with activity classification and staleness detection."
---

# /tmux-status

Scan all tmux sessions and windows, analyze each pane's content, and write a JSON status dashboard to `~/.local/state/thegrid/tmux-status.json`.

## Usage

```
/tmux-status              # scan all sessions and update tmux-status.json
```

## Output Schema

Writes to `$XDG_STATE_HOME/thegrid/tmux-status.json` (default: `~/.local/state/thegrid/tmux-status.json`):

- `generatedAt`: Unix timestamp when the scan completed
- `sessions`: Array of session objects
  - `name`: Session name
  - `attached`: Boolean (whether a client is attached)
  - `activity`: Unix epoch of last activity
  - `windows`: Array of window objects
    - `index`: Window index (0-based)
    - `name`: Window name
    - `command`: Detected command (parsed from window name or pane content)
    - `active`: Boolean (is this the active window)
    - `statusKind`: One of `active`, `running`, `waiting`, `idle`, `error`
      - `active`: Something visibly happening (editor typing, build running)
      - `running`: Long-running process (server, watcher) without active changes
      - `waiting`: Waiting for user input (prompt visible, editor in input mode)
      - `idle`: Quiescent, no activity for >300 seconds
      - `error`: Error visible in pane output
    - `summary`: One-line human description (≤80 chars)
    - `activity`: Unix epoch of last pane output
    - `target`: Tmux target for this window (`session:window`)

## Staleness Rule

Windows with no pane output for longer than 300 seconds (STALENESS_THRESHOLD) are downgraded to `idle` status, regardless of what their scrollback text reads. This prevents stale content from masking inactive windows.

If tmux is not running or has no sessions, writes `{"generatedAt": <ts>, "sessions": []}`.

## Implementation

The skill:
1. Lists all tmux sessions with metadata (activity, attached state)
2. For each session, enumerates windows and their metadata
3. Captures the active pane for each window
4. Analyzes pane content to classify window status and extract a command
5. Applies staleness rules to downgrade old active/running windows to `idle`
6. Writes result atomically (temp → rename) to the state directory
