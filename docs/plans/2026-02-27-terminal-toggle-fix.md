# Fix Terminal Toggle Positioning + Lightweight Server Query API

## Context

The terminal toggle (`thegrid terminal`) has three positioning bugs on multi-monitor setups, plus a behavior issue with sticky windows:

1. **Chicken-and-egg active display**: `window.show` focuses the terminal, updating `activeDisplayUUID` in server metadata to wherever the terminal already is. `moveTerminalToActiveDisplay` then sees the wrong "active" display.

2. **Terminal not in snapshot**: `Fetch()` filters windows by the active space. The sticky terminal may not appear on the current space, causing a `not_in_snapshot` fallback with estimated positioning.

3. **Display offsets not applied**: `moveTerminalToActiveDisplay` and `centerTerminalOnDisplay` never call `cfg.GetDisplayOffset()`, unlike layout/apply.go and window/move.go which consistently apply offsets.

4. **Sticky window pollutes all spaces**: The terminal is set sticky (appears on ALL spaces). User wants "follow me" — terminal appears only on the space where they toggle it.

5. **Tier 4 polls full dump up to 50 times**: After launching Ghostty, the CLI polls `c.Dump()` every 100ms for 5s, each time serializing the entire state (50-100KB+) just to check if one window appeared.

Root cause: the terminal positioning flow relies on full `dump` calls. We need lightweight targeted queries, "follow me" semantics, and efficient window discovery.

## Phase 1: Server — New RPC Methods + Enhancements

**File:** `grid-server/Sources/GridServer/MessageHandler.swift`

### 1a. `metadata.get` (new)
Returns cached metadata — no window enumeration.
```
Params: (none)
Response: { focusedWindowID, activeDisplayUUID, activeSpaceID, lastUpdate }
```
Insert after `getServerInfo` handler (~line 128).

### 1b. `display.list` (new)
Returns all connected displays with bounds (no windows/apps/spaces).
```
Params: (none)
Response: { displays: [{ uuid, name, frame, visibleFrame, currentSpaceID, isMain, backingScaleFactor }] }
```

### 1c. `display.get` (new)
Returns a single display. Supports lookup by UUID or `active: true` shorthand.
```
Params: { uuid: string } OR { active: true }
Response: { uuid, name, frame, visibleFrame, currentSpaceID, isMain, backingScaleFactor }
```
When `active: true`, reads `state.metadata.activeDisplayUUID` to find the display.

### 1d. `window.find` (new)
Searches `state.windows` by criteria. Returns immediately with match or `found: false`.
```
Params: { appName: "Ghostty", title: "grid-terminal" }
Response: { found: true, windowId: 12345, pid: 67890 }
      OR: { found: false }
```
Iterates `state.windows` dictionary, filters by appName + title + `!isHidden` + frame height > 100 (same criteria as `findTerminalInDump`). Returns ~50 bytes per call vs 50-100KB for a full dump.

### 1e. Enhance `window.isOrderedIn` (existing, ~line 439)
Add `spaces` array to the response so CLI can check if window is on the current space.
```
Before: { windowId, isOrderedIn }
After:  { windowId, isOrderedIn, spaces: [spaceID, ...] }
```
Look up `state.windows[windowId].spaces` and include it in the response.

## Phase 2: CLI Client Helpers

**File:** `grid-cli/internal/client/client.go`

### 2a. Types
```go
type DisplayInfo struct {
    UUID           string
    Name           string
    Frame          Rect
    VisibleFrame   Rect
    CurrentSpaceID string
    IsMain         bool
    ScaleFactor    float64
}

type Rect struct {
    X, Y, Width, Height float64
}
```

### 2b. Methods
- `GetActiveDisplay(ctx) (*DisplayInfo, error)` — calls `display.get` with `active: true`
- `GetMetadata(ctx) (map[string]interface{}, error)` — calls `metadata.get`
- `GetDisplays(ctx) ([]DisplayInfo, error)` — calls `display.list`
- `FindWindow(ctx, appName, title) (windowId uint32, pid int, found bool, err error)` — calls `window.find`

Add unexported helpers: `parseDisplayInfo`, `parseRect`, `toFloat64`, `toString`, `toBool`.

## Phase 3: Terminal Toggle Fix

**File:** `grid-cli/cmd/grid/main.go`

### 3a. New function: `positionTerminalOnDisplay`
Replaces both `moveTerminalToActiveDisplay` (~line 4562) and `centerTerminalOnDisplay` (~line 4668).

```
positionTerminalOnDisplay(ctx, c, windowID int, display *client.DisplayInfo, resize bool)
```

Logic:
1. Get `visibleFrame` from display (fall back to `frame`)
2. Load config, get display offset via `cfg.GetDisplayOffset(display.UUID, display.Name)`
3. Calculate centered position with offsets applied
4. If `resize=true`: `UpdateWindow(wid, {x, y, width, height})` — 80%×60% of display
5. If `resize=false`: `UpdateWindow(wid, {spaceId: display.CurrentSpaceID, x, y})` — move to space + position in single RPC
6. Log `term.position` with display UUID, placed coords, offsets, result

Note: `updateWindow` with `spaceId` + `x`/`y` (no `displayUuid`) handles space move then position in one call. No `displayUuid` avoids the `moveWindowToDisplay` → `moveWindowToSpace` path which could interfere with non-sticky windows.

### 3b. Rewrite Tier 1 toggle logic (~line 4357)

"Follow me" semantics: if visible on current space → hide. Otherwise → move to current space + show + position.

```go
if savedPID > 0 && pidAlive(savedPID) && savedWID > 0 {
    // Capture active display BEFORE show (user's current context)
    activeDisplay, displayErr := c.GetActiveDisplay(ctx)

    // Check window state + space membership
    params := map[string]interface{}{"windowId": fmt.Sprintf("%d", savedWID)}
    result, err := c.CallMethod(ctx, "window.isOrderedIn", params)
    if err == nil {
        isOrderedIn := result["isOrderedIn"].(bool)
        onCurrentSpace := isWindowOnSpace(result, activeDisplay)

        if isOrderedIn && onCurrentSpace {
            // Visible on current space → hide
            c.CallMethod(ctx, "window.hide", params)
            logTerminal(1, "hide", nil)
            return nil
        } else {
            // Hidden OR on different space → move + show + position
            if displayErr == nil && activeDisplay != nil {
                positionTerminalOnDisplay(ctx, c, int(savedWID), activeDisplay, false)
            }
            c.CallMethod(ctx, "window.show", params)
            logTerminal(1, "show", map[string]any{"onCurrentSpace": onCurrentSpace})
            return nil
        }
    }
    // RPC failed — fall through to Tier 2...
}
```

### 3c. Rewrite Tier 4 poll loop (~line 4428)

Replace `c.Dump()` + `findTerminalInDump()` with `c.FindWindow()`:

```go
activeDisplay, _ := c.GetActiveDisplay(ctx)

// Launch Ghostty...
// Poll with lightweight window.find instead of full dump
var newWinID uint32
var newPID int
for i := 0; i < 50; i++ {
    time.Sleep(100 * time.Millisecond)
    wid, pid, found, err := c.FindWindow(ctx, "Ghostty", "grid-terminal")
    if err == nil && found {
        newWinID = wid
        newPID = pid
        break
    }
}

// Position + configure
if activeDisplay != nil {
    positionTerminalOnDisplay(ctx, c, int(newWinID), activeDisplay, true)
}
c.CallMethod(ctx, "window.setLayer", ...)
// NO setSticky — terminal is non-sticky
```

### 3d. Remove `setSticky` from Tier 4 (~line 4455)
Delete: `c.CallMethod(ctx, "window.setSticky", ...)`

### 3e. Delete dead functions
- `moveTerminalToActiveDisplay` (~line 4562-4664)
- `centerTerminalOnDisplay` (~line 4666-4694)
- `findTerminalInDump` (~line 4506-4546) — replaced by server-side `window.find`

## Phase 4: Verify

1. `go build ./cmd/grid/` — must compile clean
2. `make run` — rebuild server + CLI
3. Toggle terminal on each display — verify `term.position` log shows correct display UUID and offset-adjusted coordinates
4. Toggle terminal, `focus up/down` to switch displays, toggle again — terminal follows
5. Switch spaces (Mission Control), toggle terminal — terminal appears on new space only
6. Kill Ghostty, toggle terminal — Tier 4 launches fresh, positions correctly
7. Check logs: `grep term ~/.local/state/thegrid/thegrid-cli.json | tail -10`

## RPC Call Comparison

| Scenario | Before | After |
|----------|--------|-------|
| Toggle show | `isOrderedIn` + `show` + `dump` (50-100KB) + `UpdateWindow` | `display.get` (~200B) + `isOrderedIn` (w/ spaces) + `UpdateWindow` + `show` |
| Toggle hide | `isOrderedIn` + `hide` | `display.get` + `isOrderedIn` + `hide` |
| Fresh launch | `dump` ×50 polls + `dump` (center) + `setLayer` + `setSticky` | `display.get` + `window.find` ×N polls (~50B each) + `UpdateWindow` + `setLayer` |
