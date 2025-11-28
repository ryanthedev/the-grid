# User Cell Focus Sync

## Overview

When executing focus commands in the CLI (e.g., `grid focus left`, `grid focus next`), the system should understand when the user has manually changed focus to a different cell by clicking on a window in that cell.

This ensures the CLI's local focus state stays synchronized with the actual OS-level window focus.

## User Story

As a user, when I click on a window in a different cell (outside of using grid commands), subsequent `grid focus` commands should operate relative to that newly focused cell, not the cell I was previously in.

## Architecture

### Data Flow

```
User clicks window in Cell B
        │
        ▼
macOS sends kAXFocusedWindowChangedNotification
        │
        ▼
ApplicationObserver receives notification
        │
        ▼
StateManager.handleWindowFocused(windowID)
        │
        ▼
state.metadata.focusedWindowID = windowID
        │
        ▼
CLI calls `dump` to get server state
        │
        ▼
snapshot.FocusedWindowID parsed from metadata
        │
        ▼
reconcile.Sync() calls syncFocus()
        │
        ▼
syncFocus() finds cell containing focused window
        │
        ▼
Local state FocusedCell/FocusedWindow updated
```

### Components

#### Server Side (grid-server)

| File | Component | Purpose |
|------|-----------|---------|
| `StateManager.swift` | `handleWindowFocused(_:)` | Updates `metadata.focusedWindowID` when window focus changes |
| `ApplicationObserver.swift` | AX notification handler | Receives `kAXFocusedWindowChangedNotification` and routes to StateManager |
| `MessageHandler.swift` | `window.focus` handler | Immediately updates focus state after programmatic focus (doesn't wait for AX notification) |
| `StateModels.swift` | `Metadata` struct | Contains `focusedWindowID` field exposed in dump response |

#### CLI Side (grid-cli)

| File | Component | Purpose |
|------|-----------|---------|
| `internal/server/snapshot.go` | `Snapshot.FocusedWindowID` | Parses focused window ID from server dump |
| `internal/reconcile/reconcile.go` | `syncFocus()` | Syncs local focus state to match OS focus |
| `internal/state/state.go` | `SpaceState.FocusedCell` | Tracks which cell is currently focused |
| `internal/state/state.go` | `SpaceState.FocusedWindow` | Tracks which window index within the cell is focused |
| `internal/focus/focus.go` | `MoveFocus()`, `CycleFocus()` | Focus commands that rely on accurate FocusedCell state |

## API Contract

### Server Dump Response

The server's dump response must include `focusedWindowID` in metadata:

```json
{
  "metadata": {
    "focusedWindowID": 12345,
    "activeDisplayUUID": "...",
    ...
  },
  "windows": { ... },
  "spaces": { ... },
  ...
}
```

### syncFocus Behavior

The `reconcile.syncFocus()` function:

1. Reads `snapshot.FocusedWindowID` from server state
2. Finds which cell contains that window ID using `spaceState.GetWindowCell()`
3. If found and different from current `FocusedCell`, updates local state
4. Returns `true` if state was changed (triggers state save)

**Edge cases:**
- `FocusedWindowID == 0`: No focused window, skip sync
- Focused window not in any cell: Skip sync (window not part of layout)
- Already in sync: No state change needed

## Debug Logging

Enable debug logging with `--debug` flag to trace focus sync:

```
reconcile: starting sync spaceID=123 focusedWindowID=456 windowCount=5
syncFocus: checking focus focusedWindowID=456 spaceID=123 currentFocusedCell=A
syncFocus: updating focus to match OS oldCell=A newCell=B oldWindowIndex=0 newWindowIndex=0 windowID=456
```

## Known Issues / Investigation Areas

### 1. Metadata Field Availability
Verify the server is correctly populating `focusedWindowID` in the metadata section of dump responses.

### 2. AX Notification Timing
The AX notification (`kAXFocusedWindowChangedNotification`) may not be processed before the CLI queries the dump. The immediate update in `MessageHandler.swift` helps for programmatic focus, but user clicks rely on AX timing.

### 3. Window Not Assigned to Cell
If a user focuses a window that isn't assigned to any cell (e.g., a floating window or newly opened window), syncFocus correctly skips the update. This is expected behavior but may be confusing.

### 4. State File Persistence
When syncFocus updates focus, it should persist to the state file. Verify `rs.Save()` is being called after `rs.MarkUpdated()`.

## Testing Checklist

- [ ] Server dump includes `metadata.focusedWindowID`
- [ ] Click window in Cell A, run `grid focus right` - should move to cell right of A
- [ ] Run `grid focus next` in cell with 2 windows - should cycle within cell
- [ ] Click window in Cell B while Cell A was focused - next focus command operates from Cell B
- [ ] Debug logging shows correct focus sync messages
- [ ] State file reflects updated FocusedCell after user click

## Implementation Status

| Component | Status |
|-----------|--------|
| Server: handleWindowFocused | Implemented |
| Server: Immediate focus update on window.focus | Implemented (unstaged) |
| CLI: Snapshot.FocusedWindowID parsing | Implemented (unstaged) |
| CLI: syncFocus in reconcile | Implemented (unstaged) |
| CLI: Debug logging | Implemented (unstaged) |
| End-to-end verification | Pending |
