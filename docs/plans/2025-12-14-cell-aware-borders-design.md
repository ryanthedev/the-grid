# Cell-Aware Border System Design

> **Refined:** 2025-12-15 - Added cell state sync, config flow, dynamic corner radius, event coalescing

## Overview

A window border rendering system integrated into grid-server that provides JankyBorders-equivalent functionality with cell-awareness. Borders can display different colors based on both window focus state and cell membership.

## Goals

- Feature parity with JankyBorders (solid colors, gradients, glow, styles, animation)
- Cell-aware coloring: different colors per cell
- Three-tier focus hierarchy: active window → active cell → inactive cells
- Hybrid configuration: per-cell overrides + palette fallback + global defaults
- Incremental MVP approach: basic borders first, advanced features later
- **Dynamic corner radius** matching actual macOS window corners
- **Event coalescing** for smooth window drag performance

## Non-Goals

- Standalone binary (integrated into grid-server instead)
- Accessibility API for focus detection (use SkyLight for speed)

---

## Configuration Schema

```yaml
# ~/.config/thegrid/config.yaml
borders:
  enabled: true
  width: 5.0
  style: round          # round | square | uniform
  corner_radius: 8.0
  padding: 2.0
  hidpi: true

  # Three-tier focus colors (global defaults)
  active_window_color: "0xffe06c75"   # Focused window
  active_cell_color: "0xff61afef"     # Other windows in focused cell
  inactive_color: "0xff5c6370"        # Windows in other cells

  # Optional palette for auto-assigning cell colors
  palette:
    - "0xff61afef"  # blue
    - "0xff98c379"  # green
    - "0xffe5c07b"  # yellow
    - "0xffe06c75"  # red

  # App filtering
  whitelist: []         # If set, only these apps get borders
  blacklist:            # These apps never get borders
    - "com.apple.finder"

# Per-cell overrides in layout
layouts:
  - id: dev
    cells:
      - id: editor
        column: "1/3"
        border:
          active_cell_color: "0xff98c379"
          inactive_color: "0xff3e4451"
      - id: terminal
        column: "1/3"
        # No override - uses palette or global default
```

---

## Three-Tier Focus Hierarchy

| Tier | Description | Color Source |
|------|-------------|--------------|
| **Active Window** | The single focused window | `active_window_color` (global) |
| **Active Cell** | Other windows in the same cell as focused window | Per-cell override → palette → `active_cell_color` |
| **Inactive** | Windows in other cells | Per-cell override → dimmed palette → `inactive_color` |

---

## Architecture

```
grid-server/Sources/GridServer/
├── Borders/
│   ├── BorderManager.swift      # Orchestrates border lifecycle
│   ├── BorderWindow.swift       # Single border overlay window
│   ├── BorderRenderer.swift     # Core Graphics drawing
│   ├── BorderConfig.swift       # Config parsing, color resolution
│   └── BorderEvents.swift       # Event routing from observers
```

### Component Responsibilities

| Component | Role |
|-----------|------|
| **BorderManager** | Maintains `[windowID: BorderWindow]` map, creates/destroys borders, handles focus tier updates |
| **BorderWindow** | Wraps a single SkyLight overlay window, positions relative to target window |
| **BorderRenderer** | Stateless drawing functions: bounds + style → CGContext drawing |
| **BorderConfig** | Loads config, computes effective color for window given cell + focus state |
| **BorderEvents** | Subscribes to ApplicationObserver/WorkspaceObserver, routes to BorderManager |

### Data Flow

```
Window event (move/resize/focus/create/destroy)
    ↓
BorderEvents (filters, determines affected windows)
    ↓
BorderManager (updates border state)
    ↓
BorderConfig (resolves: which cell? what tier? what color?)
    ↓
BorderWindow (repositions overlay)
    ↓
BorderRenderer (redraws with correct style)
```

---

## IPC Protocol (CLI→Server)

The server needs two pieces of information from the CLI:
1. **Border configuration** - colors, width, style, blacklist
2. **Cell assignments** - which window belongs to which cell

### borders.configure

Sent by CLI on startup and when config changes:

```json
{
    "type": "borders.configure",
    "config": {
        "enabled": true,
        "width": 5.0,
        "style": "round",
        "cornerRadius": 8.0,
        "padding": 2.0,
        "hidpi": true,
        "activeWindowColor": "0xffe06c75",
        "activeCellColor": "0xff61afef",
        "inactiveColor": "0xff5c6370",
        "palette": ["0xff61afef", "0xff98c379", "0xffe5c07b"],
        "blacklist": ["com.apple.finder"],
        "whitelist": []
    }
}
```

### borders.setCellAssignments

Sent by CLI after each layout apply:

```json
{
    "type": "borders.setCellAssignments",
    "assignments": {
        "12345": "editor",
        "12346": "terminal",
        "12347": "browser"
    },
    "cells": {
        "editor": {"activeCellColor": "0xff98c379"},
        "terminal": {},
        "browser": {"style": "square"}
    }
}
```

---

## SkyLight Border Window

Each target window gets a transparent overlay window for its border.

### Creation

```swift
// 1. Create transparent overlay window
SLSNewWindow(cid, kCGBackingStoreBuffered, -9999, -9999, region, &windowID)

// 2. Set window properties
SLSSetWindowTags(cid, windowID, &tags, 64)  // Floating, no shadow
SLSSetWindowOpacity(cid, windowID, 0)        // Transparent background
SLSSetWindowLevel(cid, windowID, level)      // Below target window

// 3. Create drawing context
context = SLWindowContextCreate(cid, windowID, nil)
```

### Positioning

```swift
// Query target window bounds
SLSGetWindowBounds(cid, targetWindowID, &targetBounds)

// Calculate border bounds (larger than target by width + padding)
let borderBounds = targetBounds.insetBy(dx: -(width + padding), dy: -(width + padding))

// Move and resize overlay
SLSMoveWindow(cid, windowID, borderBounds.origin)
SLSSetWindowShape(cid, windowID, ...)

// Stack just below target window
SLSTransactionOrderWindow(transaction, windowID, -1, targetWindowID)
```

### Drawing

```swift
// Clear context
CGContextClearRect(context, bounds)

// Create border path
let path = CGPath(roundedRect: drawRect, cornerWidth: radius, cornerHeight: radius, transform: nil)

// Draw stroke
CGContextSetStrokeColor(context, color)
CGContextSetLineWidth(context, width)
CGContextAddPath(context, path)
CGContextStrokePath(context)

// Flush to screen
SLSFlushWindowContentRegion(cid, windowID, region)
```

---

## Dynamic Corner Radius

Query each window's actual corner radius to match macOS rounded corners:

```swift
// Add to MacOSAPIs.swift
typealias SLSWindowIteratorGetCornerRadii_t = @convention(c) (UInt32, UnsafeMutablePointer<(CGFloat, CGFloat, CGFloat, CGFloat)>) -> CGError

// In BorderWindow.swift
func getTargetCornerRadius() -> CGFloat {
    var radii: (CGFloat, CGFloat, CGFloat, CGFloat) = (0, 0, 0, 0)
    if SLSWindowIteratorGetCornerRadii(targetWindowID, &radii) == .success {
        return radii.0  // Top-left corner radius
    }
    return config.cornerRadius  // Fallback to config default
}
```

---

## Event Coalescing

Debounce rapid resize/move events during window drags (JankyBorders uses 20ms):

```swift
// In BorderWindow.swift
private var updateTimer: DispatchSourceTimer?
private let coalesceDelay: TimeInterval = 0.02 // 20ms

func scheduleUpdate(frame: CGRect, style: BorderStyle) {
    updateTimer?.cancel()
    updateTimer = DispatchSource.makeTimerSource(queue: .main)
    updateTimer?.schedule(deadline: .now() + coalesceDelay)
    updateTimer?.setEventHandler { [weak self] in
        self?.update(targetFrame: frame, style: style)
    }
    updateTimer?.resume()
}
```

---

## Transaction Batching

Use SkyLight transactions for atomic multi-border updates (focus changes):

```swift
// In BorderManager.swift
func updateFocus(newFocusedWindow: UInt32) {
    // ... compute affected windows ...

    guard let transaction = SLSTransactionCreate(connectionID) else { return }

    for windowID in affectedWindows {
        if let border = borders[windowID] {
            SLSTransactionOrderWindow(transaction, border.windowID, -1, windowID)
        }
    }

    _ = SLSTransactionCommit(transaction, 1)

    // Then redraw colors
    for windowID in affectedWindows {
        updateBorder(for: windowID)
    }
}
```

---

## Event Integration

Hooks into existing grid-server observers (no new SkyLight event registration).

### Events Handled

| Event | Action |
|-------|--------|
| `windowCreated` | Create border if app not blacklisted |
| `windowDestroyed` | Destroy border |
| `windowMoved` | Reposition border |
| `windowResized` | Reposition + redraw border |
| `windowFocused` | Update focus tiers, repaint affected borders |
| `windowMinimized` | Hide border |
| `windowUnminimized` | Show border |
| `spaceChanged` | Show/hide borders for current space |
| `appHidden` | Hide borders for app |
| `appUnhidden` | Show borders for app |

### Focus Update Flow

```swift
func updateFocus(newFocusedWindow: CGWindowID) {
    let oldCell = focusedCellID
    let newCell = stateManager.getCellForWindow(newFocusedWindow)

    // Compute affected windows
    var toRepaint: Set<CGWindowID> = []

    // Old focused window → now active_cell or inactive
    if let old = focusedWindowID { toRepaint.insert(old) }

    // Old cell windows → now inactive (if cell changed)
    if oldCell != newCell, let oldCellWindows = getWindowsInCell(oldCell) {
        toRepaint.formUnion(oldCellWindows)
    }

    // New cell windows → now active_cell
    if let newCellWindows = getWindowsInCell(newCell) {
        toRepaint.formUnion(newCellWindows)
    }

    // Update state
    focusedWindowID = newFocusedWindow
    focusedCellID = newCell

    // Repaint affected borders
    for wid in toRepaint {
        borders[wid]?.redraw(color: resolveColor(for: wid))
    }
}
```

---

## Color Resolution

Hybrid fallback system: per-cell override → palette → global default.

```swift
func resolveColor(windowID: CGWindowID) -> CGColor {
    let tier = getFocusTier(for: windowID)
    let cellID = stateManager.getCellForWindow(windowID)

    switch tier {
    case .activeWindow:
        return config.activeWindowColor

    case .activeCell:
        // 1. Per-cell override
        if let override = config.cellOverrides[cellID]?.activeCellColor {
            return override
        }
        // 2. Palette
        if let paletteColor = config.paletteColor(for: cellID) {
            return paletteColor
        }
        // 3. Global default
        return config.activeCellColor

    case .inactive:
        // 1. Per-cell override
        if let override = config.cellOverrides[cellID]?.inactiveColor {
            return override
        }
        // 2. Dimmed palette color
        if let paletteColor = config.paletteColor(for: cellID) {
            return dim(paletteColor, by: 0.5)
        }
        // 3. Global default
        return config.inactiveColor
    }
}

enum FocusTier {
    case activeWindow   // The focused window
    case activeCell     // Other windows in focused cell
    case inactive       // Windows in other cells
}
```

---

## Implementation Phases

### Phase 1: MVP
- Basic border rendering (solid colors, round/square styles)
- Three-tier focus system
- Per-cell color overrides
- Palette fallback
- App blacklist

### Phase 2: Visual Polish
- Gradient support
- Glow/shadow effects
- HiDPI rendering
- Fade animations on focus change

### Phase 3: Advanced Features
- Per-cell style overrides (not just colors)
- Uniform border style
- Whitelist mode
- Live config reload via CLI command

---

## Files to Modify

### New Files (Server - Swift)
- `grid-server/Sources/GridServer/Borders/BorderManager.swift`
- `grid-server/Sources/GridServer/Borders/BorderWindow.swift`
- `grid-server/Sources/GridServer/Borders/BorderRenderer.swift`
- `grid-server/Sources/GridServer/Borders/BorderConfig.swift`
- `grid-server/Sources/GridServer/Borders/BorderEvents.swift`

### New Files (CLI - Go)
- `grid-cli/internal/client/borders.go` - Send config and cell assignments to server

### Modified Files (Server - Swift)
- `grid-server/Sources/GridServer/MacOSAPIs.swift` - Add window creation + corner radius APIs
- `grid-server/Sources/GridServer/MessageHandler.swift` - Add `borders.configure` and `borders.setCellAssignments` handlers
- `grid-server/Sources/GridServer/StateManager.swift` - Wire BorderEvents
- `grid-server/Sources/GridServer/GridServer.swift` - Initialize BorderManager

### Modified Files (CLI - Go)
- `grid-cli/internal/config/types.go` - Add BorderConfig struct
- `grid-cli/internal/types/layout_types.go` - Add CellBorderConfig
- `grid-cli/cmd/grid/layout.go` - Send cell assignments after layout apply

---

## References

- JankyBorders source: `~/repos/JankyBorders/src/`
- Existing overlay: `grid-server/Sources/GridServer/ResizeOverlay.swift`
- SkyLight APIs: `grid-server/Sources/GridServer/SkyLight/`
