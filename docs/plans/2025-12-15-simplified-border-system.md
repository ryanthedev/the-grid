# Simplified Border System Implementation Plan

**Date**: 2025-12-15
**Status**: Ready for execution
**Branch**: borders

## Pre-Implementation Step

**Commit current work first** before starting the refactor to preserve the existing 3-tier implementation.

---

## Summary

Replace the complex 3-tier per-window border system with a simple 2-element approach:
1. **Cell Highlight**: White background with thin blue border, fills the active cell grid area, sits BEHIND windows
2. **Active Window Border**: Thin (2-3px) red (#ff0000) border around ONLY the focused window
3. **Other windows**: NO borders at all

## Current Problems
- Transaction commit failures (58 occurrences in logs)
- Border thickness inconsistencies
- All colors appearing the same
- Wrong windows having borders
- Per-window tracking creates too many overlays

## Key Technical Challenge

Cell bounds exist in CLI (`CalculatedLayout.CellBounds`) but are NOT sent to server. Must extend IPC protocol.

---

## Implementation Phases

### Phase 1: CLI Changes (Go)

#### 1.1 `grid-cli/internal/client/borders.go`

Add `CellRect` struct and extend `SendCellAssignments` to include cell bounds:

```go
type CellRect struct {
    X, Y, Width, Height float64 `json:"..."`
}

func (c *Client) SendCellAssignments(
    ctx context.Context,
    assignments []CellAssignment,
    overrides map[string]CellOverride,
    cellBounds map[string]CellRect,  // NEW
) error {
    // Add "cellBounds" to params
}
```

#### 1.2 `grid-cli/internal/layout/apply.go`

Update `sendCellAssignments` (line 337-381):
- Add `cellBounds map[string]types.Rect` parameter
- Convert to `client.CellRect` and pass to client

Update call site (line 187):
```go
// Pass calculatedLayout.CellBounds
sendCellAssignments(ctx, c, layout, assignment.Assignments, calculatedLayout.CellBounds)
```

---

### Phase 2: Server Changes (Swift)

#### 2.1 NEW: `Borders/SimpleBorderConfig.swift`

Simple config struct:
- `highlightFillColor`: White with slight transparency (0.05 alpha)
- `highlightStrokeColor`: Blue (#0088ff or similar)
- `highlightStrokeWidth`: 2.0
- `windowBorderColor`: **Red (#ff0000)**
- `windowBorderWidth`: 3.0

#### 2.2 NEW: `Borders/CellHighlight.swift`

Single SkyLight overlay that:
- Creates window at VERY LOW z-order (behind normal windows)
- Fills with white background
- Draws thin blue stroke around edge
- Has `update(frame:)` method to reposition/resize
- Has `show()/hide()` methods

#### 2.3 NEW: `Borders/SimpleBorderManager.swift`

Orchestrator managing:
- `cellBounds: [String: CGRect]` - from CLI
- `cellAssignments: [UInt32: String]` - from CLI
- `focusedWindowID: UInt32?`
- `focusedCellID: String?`
- `cellHighlight: CellHighlight` (single instance)
- `windowBorder: BorderWindow` (single instance, reuse existing)

Key methods:
- `setCellBounds(_:)` - receive from IPC
- `setCellAssignments(_:)` - receive from IPC
- `updateFocus(newFocusedWindow:)` - move both overlays

#### 2.4 `MessageHandler.swift`

Update `borders.setCellAssignments` handler:
- Parse new `cellBounds` field from params
- Call `simpleBorderManager.setCellBounds(_:)`

Add property:
```swift
weak var simpleBorderManager: SimpleBorderManager?
```

#### 2.5 `Borders/BorderEvents.swift`

Simplify to only handle:
- `handleWindowMoved` → update window border position
- `handleWindowFocused` → update both overlays
- `handleWindowMinimized/Deminimized` → show/hide overlays

Remove per-window creation/destruction logic.

#### 2.6 `main.swift`

Update initialization:
```swift
let simpleBorderManager = SimpleBorderManager(connectionID: connectionID)
borderEvents.setup(borderManager: simpleBorderManager, stateManager: StateManager.shared)
messageHandler.simpleBorderManager = simpleBorderManager
```

Remove per-window border creation loop.

---

### Phase 3: Cleanup (after verification)

**Delete** (no longer needed):
- `Borders/BorderManager.swift`
- `Borders/BorderConfig.swift`

**Keep** (still used):
- `Borders/BorderWindow.swift` - reused for active window border
- `Borders/BorderRenderer.swift` - may be useful

---

## Files to Modify

| File | Action |
|------|--------|
| `grid-cli/internal/client/borders.go` | Add CellRect, extend SendCellAssignments |
| `grid-cli/internal/layout/apply.go` | Pass cellBounds to sendCellAssignments |
| `grid-server/.../Borders/SimpleBorderConfig.swift` | CREATE |
| `grid-server/.../Borders/CellHighlight.swift` | CREATE |
| `grid-server/.../Borders/SimpleBorderManager.swift` | CREATE |
| `grid-server/.../MessageHandler.swift` | Parse cellBounds, wire SimpleBorderManager |
| `grid-server/.../Borders/BorderEvents.swift` | Simplify for 2-element system |
| `grid-server/.../main.swift` | Initialize SimpleBorderManager |

---

## Visual Behavior

| Action | Cell Highlight | Window Border |
|--------|---------------|---------------|
| Focus window in cell | Show at cell bounds | Show around window |
| Focus different window, same cell | No change | Move to new window |
| Focus window in different cell | Move to new cell | Move to new window |
| Focus floating window (no cell) | Hide | Show around window |
| Minimize focused window | Hide | Hide |
| Space change | Re-evaluate | Re-evaluate |

---

## Logging Points

1. CLI: Log cellBounds count when sending
2. Server: Log parsed cellBounds on receive
3. SimpleBorderManager: Log focus changes with before/after state
4. CellHighlight: Log frame updates
5. WindowBorder: Log position updates

---

## Context for Fresh Agent

Key files to reference:
- `grid-cli/internal/types/layout_types.go` - `CalculatedLayout.CellBounds` already exists (line 173)
- `grid-cli/internal/layout/cells.go` - `CalculateCellBounds()` function
- `grid-server/Sources/GridServer/Borders/BorderWindow.swift` - Existing SkyLight overlay pattern to reuse
- `grid-server/Sources/GridServer/MacOSAPIs.swift` - SkyLight API declarations

The existing `BorderWindow.swift` has working code for:
- Creating transparent SkyLight overlay windows
- Positioning/resizing overlays
- Drawing with CoreGraphics
- Event coalescing (20ms debounce)

Reuse this pattern for `CellHighlight.swift`.
