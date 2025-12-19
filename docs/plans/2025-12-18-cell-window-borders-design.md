# Cell Window Borders Design

**Date**: 2025-12-18
**Status**: Approved
**Goal**: Show borders on all windows in the active cell, with active/inactive styling

## Overview

Replace the disabled cell highlight overlay with per-window borders for all windows in the active cell. The focused window gets an active style, other windows in the cell get an inactive style (or hidden if disabled).

## Configuration Schema

```yaml
borders:
  enabled: true

  # Active window border (focused window in active cell)
  active:
    color: "#FF0000"
    width: 3
    cornerRadius: 8
    opacity: 1.0
    # Future: blur, gradient, animation

  # Inactive window borders (other windows in active cell)
  inactive:
    enabled: true          # false = hidden
    color: "#666666"
    width: 3
    cornerRadius: 8
    opacity: 1.0
    # Future: blur, gradient, animation

  # Future: per-cell overrides
  # cells:
  #   sidebar:
  #     active: { color: "#00FF00" }
  #     inactive: { enabled: false }
```

### Go Structs

```go
type BorderStyle struct {
    Color        string  `yaml:"color"`
    Width        float64 `yaml:"width"`
    CornerRadius float64 `yaml:"cornerRadius"`
    Opacity      float64 `yaml:"opacity"`
    // Future: Blur, Gradient, Animation
}

type InactiveBorderStyle struct {
    Enabled      bool    `yaml:"enabled"`
    Color        string  `yaml:"color"`
    Width        float64 `yaml:"width"`
    CornerRadius float64 `yaml:"cornerRadius"`
    Opacity      float64 `yaml:"opacity"`
}

type BorderConfig struct {
    Enabled  bool                 `yaml:"enabled"`
    Active   BorderStyle          `yaml:"active"`
    Inactive *InactiveBorderStyle `yaml:"inactive"`
}
```

## Architecture

### Current (to be removed/modified)

- `CellHighlight` - single background overlay → **DELETE**
- `BorderWindow` - single window border, retargeted on focus → **MODIFY**
- `SimpleBorderManager` - orchestrates single border → **REFACTOR**

### New Architecture

```
SimpleBorderManager
├── windowBorders: [UInt32: BorderWindow]   // windowID → its border overlay
├── activeCellID: String?                   // currently active cell
├── focusedWindowID: UInt32?                // active window (gets active style)
├── cellAssignments: [UInt32: String]       // windowID → cellID (existing)
└── cellBounds: [String: CGRect]            // cellID → rect (keep for future)

BorderWindow (modified)
├── targetWindowID: UInt32                  // window this border belongs to
├── overlayWindowID: UInt32                 // SkyLight overlay window
├── currentStyle: BorderStyle?              // active, inactive, or nil (hidden)
└── isVisible: Bool
```

### Key Design Decisions

1. **One BorderWindow per managed window** - Each window that could have a border gets its own persistent `BorderWindow`. Simpler state management than pooling.

2. **Eager creation** - Create `BorderWindow` when window is assigned to a cell (during layout apply). Border exists but stays hidden until cell becomes active.

3. **Instant swap** - No animations when focus changes. Immediately update colors.

4. **Remove cell highlight** - Per-window borders replace the background overlay entirely.

5. **Active cell only** - Only windows in the focused cell have borders. Future: per-cell control.

### BorderWindow Changes

- Remove `retarget()` method - each border is permanently bound to one window
- Add `updateStyle(style: BorderStyle?)` - nil means hidden
- Keep `update(targetFrame:)` for position/size tracking

## Data Flow

### On Layout Apply

```
CLI: apply layout
  └── Calculate window placements
  └── Build cellAssignments: { windowID → cellID }
  └── Send RPC: borders.setCellAssignments(assignments, cellBounds, displayUUID)
        │
Server: SimpleBorderManager.setCellAssignments()
  ├── Diff existing windowBorders against new assignments
  │   ├── New windows → create BorderWindow (hidden initially)
  │   ├── Removed windows → destroy BorderWindow
  │   └── Existing windows → keep, update cellID mapping
  ├── Store cellAssignments and cellBounds
  └── Call updateAllBorders() to refresh visibility/styles
```

### On Focus Change

```
AX Event or RPC: window.focus(windowID)
  │
StateManager.handleWindowFocused(windowID)
  └── borderEvents.handleWindowFocused(windowID)
        │
SimpleBorderManager.updateFocus(windowID)
  ├── Look up cellID from cellAssignments[windowID]
  ├── Set activeCellID = cellID
  ├── Set focusedWindowID = windowID
  └── updateAllBorders():
        ├── For each windowID in windowBorders:
        │   ├── Get window's cellID from assignments
        │   ├── If cellID == activeCellID:
        │   │   ├── If windowID == focusedWindowID → apply activeStyle, show
        │   │   └── Else → apply inactiveStyle (or hide if disabled), show
        │   └── Else → hide
        └── Update border positions from window frames
```

### On Window Move/Resize

```
StateManager.handleWindowMoved(windowID, frame)
  └── borderEvents.handleWindowMoved(windowID, frame)
        │
SimpleBorderManager.handleWindowMoved(windowID, frame)
  └── If windowBorders[windowID] exists and visible:
        └── windowBorders[windowID].update(targetFrame: frame)
```

## State Management

### Server-Side State (SimpleBorderManager)

```swift
// Primary state
private var focusedWindowID: UInt32?
private var activeCellID: String?

// Border instances (new)
private var windowBorders: [UInt32: BorderWindow] = [:]

// Mappings (existing, per-display)
private var cellAssignmentsPerDisplay: [String: [UInt32: String]]
private var cellBoundsPerDisplay: [String: [String: CGRect]]

// Config
private var activeStyle: BorderStyle
private var inactiveStyle: BorderStyle?  // nil if inactive.enabled = false
```

### State Invariants

1. `activeCellID` is always derived from `focusedWindowID` via `cellAssignments` lookup
2. A `BorderWindow` exists for every window in `cellAssignments` (eager creation)
3. Only windows where `cellAssignments[windowID] == activeCellID` have visible borders
4. Exactly one visible border has `activeStyle` (the `focusedWindowID`)

### Edge Cases

| Scenario | Behavior |
|----------|----------|
| Focus window not in any cell | `activeCellID = nil`, all borders hidden |
| Window destroyed | Remove from `windowBorders`, destroy overlay |
| Space change | Hide all borders, clear `activeCellID` |
| App hidden | Hide borders for that app's windows |
| Layout reapply | Diff assignments, create/destroy borders as needed |
| Config change | Rebuild styles, call `updateAllBorders()` |

## Files to Modify

| File | Changes |
|------|---------|
| `SimpleBorderManager.swift` | Refactor to manage multiple `BorderWindow` instances, remove `CellHighlight` usage |
| `BorderWindow.swift` | Remove `retarget()`, add `updateStyle()`, simplify to single-target lifetime |
| `CellHighlight.swift` | **DELETE** |
| `SimpleBorderConfig.swift` | Update config parsing for new `active`/`inactive` structure |
| `BorderConfigManager` | Add `activeStyle` and `inactiveStyle` computed properties |
| `MessageHandler.swift` | Update `borders.updateConfig` RPC to handle new schema |
| `grid-cli/internal/types/config.go` | Add `BorderStyle` and `BorderConfig` structs |
| `grid-cli/internal/client/borders.go` | Update config serialization for RPC |

## RPC Changes

### borders.updateConfig (modified)

```json
{
  "enabled": true,
  "active": { "color": "#FF0000", "width": 3, "cornerRadius": 8, "opacity": 1.0 },
  "inactive": { "enabled": true, "color": "#666666", "width": 3, "cornerRadius": 8, "opacity": 1.0 }
}
```

### borders.setCellAssignments (unchanged)

Side effect: Now creates/destroys BorderWindow instances based on diff.

## Logging

All visible borders (active and inactive) log position and size:

```json
{"event":"bdr.show","wid":12345,"style":"active","cell":"main","frame":[100,200,500,400]}
{"event":"bdr.show","wid":12346,"style":"inactive","cell":"main","frame":[100,620,500,400]}
{"event":"bdr.move","wid":12345,"frame":[100,200,500,400]}
{"event":"bdr.move","wid":12346,"frame":[100,620,500,400]}
{"event":"bdr.hide","wid":12345,"reason":"cell_inactive"}
{"event":"bdr.create","wid":12345,"target":12345}
{"event":"bdr.destroy","wid":12345}
```

## Error Handling

### Border Creation Failures

Log failure and skip - don't add to `windowBorders` map.

### Stale Borders

During `updateAllBorders()`, verify window still exists via `SLSGetWindowBounds`. If window gone, destroy border and remove from map.

### Cleanup

On shutdown, iterate all `windowBorders` and destroy each overlay.

### Config Validation

Clamp values to reasonable ranges:
- `width`: 1-20
- `cornerRadius`: 0-50
- `opacity`: 0-1

## Future Considerations

- Per-cell border overrides
- Gradient spanning all borders in cell
- Blur effect on inactive borders
- Animation support (pulse, fade, etc.)
- Treating all cell borders as a unified visual element
