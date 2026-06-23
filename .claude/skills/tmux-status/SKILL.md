# Skill: tmux-status

Enumerate every tmux session and window, generate a one-line AI summary of each window's current state, and atomically write the result to a JSON status file.

## Implementation

This skill:
1. Lists all tmux sessions with activity timestamp and attached state
2. For each session, enumerates windows with their command and activity time
3. Captures the active pane for each window and analyzes its state
4. Generates a one-line summary and classifies the window status
5. Applies a staleness rule: windows idle >300s are downgraded to `idle`
6. Writes the result atomically to `$XDG_STATE_HOME/thegrid/tmux-status.json`

Output schema:
- `generatedAt`: Unix epoch timestamp
- `sessions`: Array of session objects
  - `name`: Session name
  - `attached`: Boolean (client attached)
  - `activity`: Unix epoch of last activity
  - `windows`: Array of window objects
    - `index`: Window index (0-based)
    - `name`: Window name
    - `command`: Current foreground command
    - `active`: Is this the active window
    - `statusKind`: One of `active`, `running`, `waiting`, `idle`, `error`
    - `summary`: One-line description (≤80 chars)
    - `activity`: Unix epoch of last pane output
    - `target`: Tmux target `session:window`

If tmux is not running or has no sessions, writes `{"generatedAt": <ts>, "sessions": []}`.
