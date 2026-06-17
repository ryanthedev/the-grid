# Tmux Status Dashboard

The tmux status dashboard is a floating SwiftUI panel in GridNotify that shows all tmux
sessions and windows, each with an AI-generated one-line summary. A headless Claude Code
process writes `~/.local/state/thegrid/tmux-status.json` on a configurable interval; the
dashboard reads that file and displays it. Toggle and refresh are driven by
`thegrid tmux toggle` / `thegrid tmux refresh`, which relay through grid-server RPC and
post DistributedNotifications consumed by GridNotify.

---

## How It Works

1. **Toggle** (`thegrid tmux toggle`) → grid-server posts `com.thegrid.tmux.toggle` →
   GridNotify shows/hides the dashboard window and starts/stops the background driver.

2. **Driver** (`TmuxStatusDriver` in GridNotify) spawns headless Claude Code on a
   configurable interval. Claude enumerates tmux sessions via the `claude-mux` MCP server,
   generates summaries, and atomically writes `tmux-status.json`.

3. **Refresh** (`thegrid tmux refresh`) → grid-server posts `com.thegrid.tmux.refresh` →
   GridNotify tells the driver to run immediately, bypassing the normal interval.

4. **Dashboard view** watches `tmux-status.json` for changes via a file-system event
   watcher and updates the SwiftUI view on every write.

---

## notify.yaml Configuration

GridNotify reads its config from `~/.config/thegrid/notify.yaml` (with optional
`notify.local.yaml` override). The `tmux:` block controls the status driver:

```yaml
# ~/.config/thegrid/notify.yaml

tmux:
  # Master enable switch. Set to true to start the driver when the dashboard is shown.
  enabled: true

  # Interval in seconds between automatic refresh runs.
  # Minimum: 30. Recommended: 60–300.
  interval: 60

  # Absolute path to the git repo root where the .claude/commands/tmux-status.md
  # slash command lives. The driver runs headless Claude from this directory.
  repoDir: /Users/r/repos/theGrid

  # Claude model for the headless summarization run.
  # Use a fast, cheap model — summaries are short and the context is small.
  model: claude-haiku-4-5
```

### Local override example

```yaml
# ~/.config/thegrid/notify.local.yaml

tmux:
  interval: 120
  repoDir: /Users/yourname/repos/theGrid
```

---

## BFD Hotkey Configuration

Add these entries to `~/.config/thegrid/bfd.yaml` to bind hotkeys for the dashboard:

```yaml
# ~/.config/thegrid/bfd.yaml

vars:
  grid: ~/.local/bin/thegrid

hotkeys:
  # Toggle the tmux status dashboard (show/hide + start/stop driver)
  cmd+shift-t: "${grid} tmux toggle"

  # Force an immediate refresh of tmux status
  cmd+shift-r: "${grid} tmux refresh"
```

Save and reload BFD (or restart theGrid) for hotkeys to take effect.

---

## Manual Setup and Verification

### Step 1: Enable in notify.yaml

Add the `tmux:` block above to `~/.config/thegrid/notify.yaml`. At minimum, set `repoDir`
to the absolute path of your theGrid repo clone.

### Step 2: Verify grid-server RPC is registered

```bash
thegrid ping
```

Expected: `ok` — confirms grid-server is running and the socket is up.

### Step 3: Toggle the dashboard

```bash
thegrid tmux toggle
```

Expected: GridNotify opens (or comes to front) and shows the tmux dashboard panel.

### Step 4: Force a refresh

```bash
thegrid tmux refresh
```

Expected: the dashboard updates within a few seconds (headless Claude run completes).

### Step 5: Verify the status file was written

```bash
cat ~/.local/state/thegrid/tmux-status.json | python3 -m json.tool | head -20
```

Expected: valid JSON with `generatedAt` (Unix timestamp) and `sessions` array.

### Step 6: Toggle off

```bash
thegrid tmux toggle
```

Expected: the dashboard panel hides and the driver stops.

---

## Status File Schema

Written to `~/.local/state/thegrid/tmux-status.json`:

```json
{
  "generatedAt": 1718500000,
  "sessions": [
    {
      "name": "work",
      "attached": true,
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

`statusKind` is one of: `active`, `running`, `waiting`, `idle`, `error`.

---

## Troubleshooting

| Symptom | Check |
|---------|-------|
| `thegrid tmux toggle` returns error | `thegrid ping` — is grid-server running? `make run` to rebuild and restart. |
| Dashboard shows but never updates | Check `notify.yaml` `tmux.enabled: true` and `repoDir` path. Run `thegrid tmux refresh` manually. |
| Status file missing after refresh | Verify headless Claude path: `/Users/r/.local/bin/claude`. Check `~/.local/state/thegrid/thegrid-server.json` for `tmux.driver.*` log events. |
| BFD hotkeys not working | Run `thegrid config show` to verify BFD config loaded. Check `bfd.yaml` syntax. |
