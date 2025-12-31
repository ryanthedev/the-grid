# Click Focus Border Sync

## Problem

Borders only update when focus changes via CLI commands (`thegrid focus left`, etc.). When users click windows directly, the OS changes focus but borders don't update because the CLI isn't involved in the loop.

## Solution

Server detects external (non-CLI) focus changes and invokes the CLI to sync borders.

## Flow

```
Click on window
    ↓
OS focuses window
    ↓
AXObserver fires (kAXFocusedWindowChangedNotification)
    ↓
Server checks: trigger != .cliCommand?
    ↓ yes
Server spawns: thegrid event focus <windowID>
    ↓
CLI determines if tileable, calls borders.updateFocus if needed
    ↓
Border updates
```

## Loop Prevention

When CLI calls `window.focus` RPC, server marks the resulting focus event with trigger `.cliCommand`. Server only invokes CLI for non-CLI triggers (`.windowActivated`, `.appActivated`).

## Server Changes

### 1. Add `.cliCommand` trigger

In `StateModels.swift`, extend the trigger enum:

```swift
enum FocusTrigger: String, Codable {
    case windowActivated
    case appActivated
    case cliCommand      // marks CLI-initiated focus
}
```

### 2. Mark CLI focus with new trigger

In `MessageHandler.swift`, when handling `window.focus` RPC, set trigger to `.cliCommand` before routing the focus event.

### 3. CLI invocation on external focus

In `StateManager.swift`, when handling focus changes:
- Check if trigger is NOT `.cliCommand`
- If external, spawn `thegrid event focus <windowID>` asynchronously
- Log result, don't wait/retry on failure

### 4. Config for CLI path

Add to server config:

```swift
var cliPath: String = "thegrid"  // default assumes in PATH
```

Configurable via `~/.config/thegrid/config.yaml`:

```yaml
server:
  cliPath: /custom/path/to/thegrid
```

## CLI Changes

### 1. New `event` command group

```
thegrid event focus <windowID>
```

Extensible for future server→CLI events.

### 2. `event focus` implementation

```go
func eventFocusCmd(windowID uint32) {
    // 1. Get current state from server
    snapshot := client.GetSnapshot()

    // 2. Find window, check if tileable
    window := snapshot.FindWindow(windowID)
    if window == nil || !window.IsTileable() {
        return  // silently ignore non-tileable
    }

    // 3. Sync borders for this window
    reconcile.SyncBorderFocus(ctx, client, window.DisplayUUID, windowID, cfg)
}
```

### 3. Reuses existing logic

`reconcile.SyncBorderFocus()` already exists and calls `borders.updateFocus` on the server. No new RPC methods required.

## Error Handling

- CLI invocation failures are logged and ignored (fire-and-forget)
- Border not updating on click is non-critical; user can trigger manually
- No retries to avoid complexity

## Files to Modify

**Server (Swift):**
- `grid-server/Sources/GridServer/StateModels.swift` - add `.cliCommand` trigger
- `grid-server/Sources/GridServer/MessageHandler.swift` - mark CLI focus events
- `grid-server/Sources/GridServer/StateManager.swift` - invoke CLI on external focus
- `grid-server/Sources/GridServer/Config.swift` - add `cliPath` config

**CLI (Go):**
- `grid-cli/cmd/grid/main.go` - add `event focus` subcommand
- `grid-cli/internal/event/focus.go` (new) - event focus implementation
