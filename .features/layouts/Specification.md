# theGrid: Grid-Based macOS Tiling Window Manager
## Technical Specification v1.0

---

## 1. Executive Summary

theGrid is a macOS tiling window manager that uses a grid-based layout model. Users define 2D grid layouts (tracks, areas, spanning) and cycle through these layouts to organize their workspace. The system supports multiple monitors, per-Space configurations, and flexible window arrangement within cells.

### Key Design Principles

1. **Layouts are fixed, windows are dynamic** - Users define grid layouts once and windows flow into them
2. **Layout cycling over manual placement** - Users switch between predefined layouts rather than manually positioning windows
3. **Grid integrity is maintained** - Cell boundaries are defined by the layout; only internal cell splits are adjustable
4. **Progressive complexity** - Simple equal-column layouts by default, with advanced features available when needed

---

## 2. Core Concepts

### 2.1 Grid Layout

A **Layout** defines a 2D grid structure:

- **Tracks**: Columns and rows defined using fractional units (`1fr`, `2fr`), fixed pixels (`300px`), or constraints (`minmax(200px, 1fr)`)
- **Cells**: Named regions within the grid that can span multiple rows/columns
- **Areas**: A visual way to define cells using ASCII-art-like syntax

### 2.2 Cells

A **Cell** is a rectangular region within the grid that contains one or more windows:

- Each cell has a unique identifier (e.g., `editor`, `terminal`, `sidebar`)
- Cells can span multiple columns and/or rows
- Cells maintain their own stack mode for handling multiple windows
- Cell boundaries are fixed by the layout and cannot be manually resized

### 2.3 Stack Modes

When a cell contains multiple windows, they are arranged according to its **Stack Mode**:

- **Vertical**: Windows stack top-to-bottom, each gets full cell width
- **Horizontal**: Windows stack left-to-right, each gets full cell height  
- **Tabs**: Only one window visible at a time, with tab bar for switching

Within a stack, users can drag dividers to adjust split ratios between windows, but cannot break the cell boundaries.

### 2.4 Layout Cycling

Users cycle through available layouts using hotkeys. When a layout is applied:

1. The grid structure is calculated based on screen dimensions
2. Windows are assigned to cells (via auto-flow or pinned rules)
3. Each cell's windows are arranged according to its stack mode
4. All windows are moved/resized to their calculated positions

### 2.5 Spaces

macOS Spaces are supported with per-Space configuration:

- Each Space can have its own list of available layouts
- Each Space maintains independent runtime state (current layout, window positions, focus)
- Layout changes are scoped to the current Space

---

## 3. System Architecture

### 3.1 Components

```
┌─────────────────────────────────────────┐
│           Configuration Layer           │
│  (YAML parsing, layout definitions)     │
└─────────────────┬───────────────────────┘
                  │
┌─────────────────▼───────────────────────┐
│            Core Logic Layer             │
│  - Layout engine (grid calculations)    │
│  - Window assignment algorithm          │
│  - Focus navigation                     │
│  - Split ratio management               │
└─────────────────┬───────────────────────┘
                  │
┌─────────────────▼───────────────────────┐
│         macOS Integration Layer         │
│  - Accessibility API (window control)   │
│  - Spaces detection                     │
│  - Event listening (window lifecycle)   │
│  - Hotkey registration                  │
└─────────────────┬───────────────────────┘
                  │
┌─────────────────▼───────────────────────┐
│              IPC/API Layer              │
│  (Commands, queries, state inspection)  │
└─────────────────────────────────────────┘
```

### 3.2 Data Flow

**Layout Application Flow:**
```
User triggers layout cycle
  → Get current Space ID
  → Load next layout from Space's layout list
  → Enumerate all windows on current Space
  → Run window assignment algorithm
  → Calculate grid track sizes from screen dimensions
  → Calculate cell bounds from grid
  → For each cell:
      → Calculate window bounds based on stack mode and splits
      → Move/resize windows via Accessibility API
  → Update runtime state
```

**Window Event Flow:**
```
New window opens
  → Detect via Accessibility notification
  → Get current Space and layout
  → Assign window to cell (auto-flow or pinned rule)
  → Recalculate bounds for affected cell
  → Apply window bounds
  → Update runtime state

Window closes
  → Detect via Accessibility notification
  → Remove from cell's window list
  → Recalculate remaining windows' bounds
  → Apply new bounds
  → Update runtime state
```

---

## 4. Configuration Specification

### 4.1 File Structure

Configuration is stored in YAML format at `~/.config/thegrid/config.yaml`

```yaml
settings:           # Global settings
layouts:            # Layout definitions
spaces:             # Per-Space configuration
appRules:           # Application-specific rules
keybindings:        # Hotkey mappings
```

### 4.2 Settings Schema

```yaml
settings:
  defaultStackMode: vertical | horizontal | tabs
  animationDuration: number          # Seconds, 0 for instant
  cellPadding: number                # Pixels between windows in a cell
  focusFollowsMouse: boolean         # Whether focus follows mouse cursor
```

### 4.3 Layout Schema

```yaml
layouts:
  - id: string                       # Unique identifier (required)
    name: string                     # Display name (required)
    description: string              # Optional description
    
    # Grid structure definition
    grid:
      columns: [TrackSize, ...]      # Column track definitions
      rows: [TrackSize, ...]         # Row track definitions
    
    # Cell definition (Option A: Named areas)
    areas:
      - [cellId, cellId, ...]        # Row 1
      - [cellId, cellId, ...]        # Row 2
    
    # Cell definition (Option B: Explicit cells with spanning)
    cells:
      - id: string                   # Cell identifier
        column: string               # "start/end" e.g. "1/3"
        row: string                  # "start/end" e.g. "1/2"
        stackMode: StackMode         # Optional override
    
    # Per-cell stack mode configuration
    cellModes:
      cellId: StackMode              # vertical | horizontal | tabs
    
    # Optional cell constraints
    cellConstraints:
      cellId:
        minWidth: number             # Pixels
        maxWidth: number             # Pixels
        minHeight: number            # Pixels
        maxHeight: number            # Pixels
```

**TrackSize Format:**
- `"1fr"`, `"2fr"` - Fractional units (proportional distribution)
- `"300px"` - Fixed pixel size
- `"minmax(200px, 1fr)"` - Constrained flexible size
- `"auto"` - Content-based size

**StackMode Values:**
- `vertical` - Windows stack top-to-bottom
- `horizontal` - Windows stack left-to-right
- `tabs` - One window visible at a time

### 4.4 Spaces Schema

```yaml
spaces:
  spaceId:                           # macOS Space ID (integer)
    name: string                     # Optional display name
    layouts: [layoutId, ...]         # Available layouts for this Space
    defaultLayout: layoutId          # Layout to use on first activation
    autoApply: boolean               # Auto-apply layout when switching to Space
```

### 4.5 Application Rules Schema

```yaml
appRules:
  - app: string                      # App name or bundle ID
    preferredCell: cellId            # Cell to auto-assign this app to
    layouts: [layoutId, ...]         # Only applies to these layouts
    float: boolean                   # If true, never tile this app
    preferredStackMode: StackMode    # Override stack mode for this app
```

### 4.6 Keybindings Schema

```yaml
keybindings:
  # Layout management
  cycleLayout: keyCombo              # Cycle to next layout
  previousLayout: keyCombo           # Cycle to previous layout
  
  # Focus navigation (between cells)
  focusLeft: keyCombo
  focusRight: keyCombo
  focusUp: keyCombo
  focusDown: keyCombo
  
  # Focus navigation (within cell)
  focusNextInCell: keyCombo
  focusPrevInCell: keyCombo
  
  # Window movement (between cells)
  moveWindowLeft: keyCombo
  moveWindowRight: keyCombo
  moveWindowUp: keyCombo
  moveWindowDown: keyCombo
  
  # Move window to specific cell
  moveToCell1: keyCombo
  moveToCell2: keyCombo
  # ... up to moveToCell9
  
  # Jump focus to specific cell
  focusCell1: keyCombo
  focusCell2: keyCombo
  # ... up to focusCell9
  
  # Cell stack mode control
  toggleStackMode: keyCombo          # Cycle through stack modes
  setStackVertical: keyCombo
  setStackHorizontal: keyCombo
  setStackTabs: keyCombo
  
  # Utility
  reapplyLayout: keyCombo            # Reapply current layout
  toggleFloat: keyCombo              # Float/unfloat current window
```

**Key Combo Format:** `"modifier+modifier+key"` where modifiers are `cmd`, `shift`, `ctrl`, `alt`

Example: `"cmd+shift+space"`, `"cmd+h"`, `"cmd+shift+ctrl+l"`

---

## 5. Runtime Behavior

### 5.1 Window Assignment Algorithm

When a layout is applied, windows must be assigned to cells. The algorithm depends on the configuration:

**Strategy 1: Auto-flow (default)**
1. Sort cells by visual position (left-to-right, top-to-bottom)
2. Distribute windows evenly across cells
3. If more windows than cells, stack multiple windows per cell

**Strategy 2: Pinned Apps**
1. First pass: Assign windows matching `appRules` to their preferred cells
2. Second pass: Auto-flow remaining windows to remaining cells

**Strategy 3: Preserve Previous State**
1. If switching layouts in the same Space, maintain window-to-cell mappings where possible
2. Reassign only if window's previous cell doesn't exist in new layout

### 5.2 Window Lifecycle Events

**Window Opens:**
1. Detect new window via Accessibility API
2. Check if app has pinned cell rule
3. If pinned, add to that cell
4. If not pinned, add to next available cell (round-robin or least-full)
5. Recalculate bounds for affected cell
6. Apply bounds to all windows in cell

**Window Closes:**
1. Detect window close via Accessibility API
2. Remove from cell's window list
3. If cell had split ratios, redistribute evenly or keep remaining ratios
4. Recalculate bounds for affected cell
5. Apply new bounds

**Window Focus Changes:**
1. Detect focus change via Accessibility API
2. Update focused cell and focused window index
3. Optional: Apply visual highlight to focused cell

### 5.3 Split Adjustment

When a user drags a divider between windows within a cell:

1. Calculate delta as percentage of cell dimension
2. Adjust split ratios for affected windows
3. Ensure ratios sum to 1.0
4. Recalculate window bounds
5. Apply new bounds
6. Persist split ratios in runtime state

**Constraints:**
- Minimum window size respected (from app or global setting)
- Dragging is constrained to cell boundaries
- Ratios are relative, so resizing the cell maintains proportions

### 5.4 Focus Navigation

**Between Cells (directional):**
1. Get current focused cell
2. Calculate cell centers
3. Find cell whose center is closest in the specified direction
4. If no cell in that direction, optionally wrap to opposite edge
5. Focus first window in target cell

**Within Cell (next/previous):**
1. Get current focused window index in cell
2. Increment/decrement with wrapping
3. Focus window at new index
4. If stack mode is tabs, also switch visible tab

### 5.5 Multi-Monitor Support

Each monitor is treated independently:

- Each monitor has its own active Space
- Each Space has its own layout and window state
- Layouts are applied per-monitor based on its dimensions
- Windows cannot span multiple monitors
- Dragging a window to another monitor removes it from source layout and adds to destination

---

## 6. Grid Calculation Algorithm

### 6.1 Track Size Calculation

Given a screen dimension (width or height) and track definitions, calculate pixel sizes:

```
Algorithm:
1. Parse each track definition:
   - Fixed (e.g., "300px") → 300
   - Fractional (e.g., "2fr") → marked for distribution
   - Minmax (e.g., "minmax(200px, 1fr)") → process constraints
   
2. Subtract fixed track sizes from available space
   Remaining space = Screen dimension - Σ(fixed sizes) - Gaps

3. Distribute remaining space to fractional tracks:
   For each "fr" unit: pixels = (remaining space) / (total fr units) * (track's fr value)
   
4. Apply minmax constraints:
   Clamp each track between its min and max values
   If clamping occurs, recalculate distribution for unclamped tracks

5. Return array of pixel sizes for each track
```

**Example:**
```
Screen width: 3000px
Columns: ["300px", "1fr", "2fr"]

Step 1: Fixed = 300px
Step 2: Remaining = 3000 - 300 = 2700px
Step 3: Total fr = 1 + 2 = 3fr
        1fr = 2700 / 3 = 900px
        2fr = 2700 / 3 * 2 = 1800px
Step 4: No constraints
Result: [300px, 900px, 1800px]
```

### 6.2 Cell Bounds Calculation

Given track sizes and cell definition, calculate cell's screen coordinates:

```
Algorithm:
1. Parse cell's grid area (e.g., column "1/3", row "1/2")
2. Sum track sizes from start to end:
   x = Σ(column widths from 0 to start-1)
   width = Σ(column widths from start to end-1)
   y = Σ(row heights from 0 to start-1)
   height = Σ(row heights from start to end-1)
3. Return CGRect(x, y, width, height)
```

### 6.3 Window Bounds Calculation

Given cell bounds, stack mode, and split ratios, calculate each window's bounds:

**Vertical Stack:**
```
For window at index i with split ratio r[i]:
  x = cell.x
  width = cell.width
  y = cell.y + Σ(cell.height * r[j] for j < i)
  height = cell.height * r[i]
```

**Horizontal Stack:**
```
For window at index i with split ratio r[i]:
  x = cell.x + Σ(cell.width * r[j] for j < i)
  width = cell.width * r[i]
  y = cell.y
  height = cell.height
```

**Tabs:**
```
All windows get full cell bounds (only focused window is visible):
  x = cell.x
  y = cell.y
  width = cell.width
  height = cell.height
```

---

## 7. macOS Integration Requirements

### 7.1 Accessibility API

**Required permissions:**
- Accessibility access (requested on first launch)

**Window Operations:**
```
- Enumerate all windows: AXUIElementCopyAttributeValue with kAXWindowsAttribute
- Get window bounds: AXUIElementCopyAttributeValue with kAXPositionAttribute and kAXSizeAttribute
- Set window bounds: AXUIElementSetAttributeValue
- Get window title: kAXTitleAttribute
- Get window app: kAXParentAttribute → application
- Get focused window: systemWideElement kAXFocusedWindowAttribute
- Set focused window: AXUIElementSetAttributeValue with kAXMainAttribute
```

**Event Observation:**
```
- Window created: kAXWindowCreatedNotification
- Window closed: kAXUIElementDestroyedNotification
- Window moved: kAXMovedNotification
- Window resized: kAXResizedNotification
- Focus changed: kAXFocusedWindowChangedNotification
```

### 7.2 Spaces Detection

**Challenge:** Apple does not provide public APIs for Spaces.

**Options:**
1. **Private API (like yabai):** Use undocumented APIs via CGSInternal framework
   - More reliable Space detection
   - Per-Space window enumeration
   - Space change notifications
   - Risk: May break in macOS updates, App Store rejection

2. **Public API workarounds:**
   - Use Mission Control accessibility elements
   - Screen arrangement changes as proxy for Space switches
   - Less reliable, more fragile

**Recommendation:** Start with public APIs, document private API integration as optional advanced feature.

### 7.3 Hotkey Registration

Use Carbon Event Manager or modern Cocoa equivalents:
- Register global hotkeys with modifier key combinations
- Handle conflicts with system shortcuts
- Provide UI for remapping if conflicts detected

### 7.4 Application Bundling

**Daemon Architecture:**
- Background daemon process (runs in menu bar)
- No dock icon
- Launch at login option
- Status item shows current layout name

**Permissions:**
- Accessibility API (required for window control)
- Screen Recording (if using private APIs)
- Input Monitoring (for global hotkeys)

---

## 8. IPC/Command API

For programmatic control and CLI integration:

### 8.1 Command Structure

Commands are JSON objects sent via Unix domain socket or named pipe:

```json
{
  "command": "commandName",
  "params": { ... }
}
```

Response:
```json
{
  "success": true,
  "data": { ... },
  "error": "error message if failed"
}
```

### 8.2 Available Commands

**Layout Management:**
```json
// Apply a specific layout
{ "command": "applyLayout", "params": { "layoutId": "ide", "spaceId": 1 } }

// Cycle through layouts
{ "command": "cycleLayout", "params": { "direction": "forward" } }

// Get all layouts
{ "command": "getLayouts" }

// Get current layout
{ "command": "getCurrentLayout", "params": { "spaceId": 1 } }
```

**Focus Management:**
```json
// Move focus between cells
{ "command": "moveFocus", "params": { "direction": "left" } }

// Focus specific cell
{ "command": "focusCell", "params": { "cellId": "editor" } }

// Focus specific window
{ "command": "focusWindow", "params": { "windowId": 123 } }
```

**Window Management:**
```json
// Move window to cell
{ "command": "moveWindow", "params": { "windowId": 123, "targetCell": "terminal" } }

// Move window in direction
{ "command": "moveWindowDirection", "params": { "direction": "right" } }

// Toggle float
{ "command": "toggleFloat", "params": { "windowId": 123 } }

// Get all windows
{ "command": "getWindows", "params": { "spaceId": 1 } }
```

**Cell Management:**
```json
// Set cell stack mode
{ "command": "setCellStackMode", "params": { "cellId": "editor", "mode": "vertical" } }

// Adjust split ratio
{ "command": "adjustSplit", "params": { "cellId": "editor", "dividerIndex": 0, "delta": 0.1 } }
```

**System:**
```json
// Reload configuration
{ "command": "reloadConfig" }

// Get current config
{ "command": "getConfig" }

// Get runtime state
{ "command": "getState", "params": { "spaceId": 1 } }
```

---

## 9. Implementation Phases

### Phase 1: Core Logic (No macOS Integration)
- Parse YAML configuration
- Implement grid calculation algorithm
- Implement window assignment algorithm
- Implement focus navigation logic
- Unit tests with mock data

**Deliverable:** Pure logic library that can be tested independently

### Phase 2: macOS Integration
- Set up Accessibility API wrapper
- Implement window enumeration
- Implement window move/resize
- Integrate core logic with real windows
- Basic hotkey registration

**Deliverable:** Functional window manager with single-Space support

### Phase 3: Spaces Support
- Detect Spaces (public API first)
- Per-Space state management
- Space switch detection
- Layout persistence per Space

**Deliverable:** Full multi-Space window management

### Phase 4: Advanced Features
- Split ratio adjustment (mouse drag)
- Cell stack mode switching
- Application rules
- IPC/command API
- Configuration hot-reload

**Deliverable:** Polished, feature-complete window manager

### Phase 5: Polish
- Animation/transitions
- Visual feedback (focused cell highlight)
- Configuration validation
- Error handling and recovery
- Documentation and examples

**Deliverable:** Production-ready application

---

## 10. Example Configurations

### 10.1 Minimal Configuration

```yaml
settings:
  defaultStackMode: vertical

layouts:
  - id: focus
    name: "Focus"
    grid:
      columns: [1fr]
      rows: [1fr]
    areas:
      - [main]
      
  - id: two-col
    name: "Two Column"
    grid:
      columns: [1fr, 1fr]
      rows: [1fr]
    areas:
      - [left, right]

keybindings:
  cycleLayout: "cmd+shift+space"
  focusLeft: "cmd+h"
  focusRight: "cmd+l"
```

### 10.2 Developer Setup

```yaml
settings:
  defaultStackMode: vertical
  animationDuration: 0.15

layouts:
  - id: ide
    name: "IDE Layout"
    grid:
      columns: [300px, 1fr, 1fr]
      rows: [2fr, 1fr]
    areas:
      - [sidebar, editor, editor]
      - [sidebar, terminal, preview]
    cellModes:
      sidebar: tabs
      editor: vertical
      terminal: horizontal
      preview: vertical
    cellConstraints:
      terminal:
        minHeight: 150
        
  - id: focus
    name: "Focus"
    grid:
      columns: [1fr]
      rows: [1fr]
    areas:
      - [main]
    cellModes:
      main: vertical
      
  - id: debug
    name: "Debug Layout"
    grid:
      columns: [1fr, 2fr]
      rows: [1fr, 1fr]
    areas:
      - [vars, code]
      - [console, code]
    cellModes:
      vars: tabs
      code: vertical
      console: tabs

spaces:
  1:
    name: Development
    layouts: [ide, focus, debug]
    defaultLayout: ide

appRules:
  - app: "Visual Studio Code"
    preferredCell: editor
    layouts: [ide]
    
  - app: "Terminal"
    preferredCell: terminal
    layouts: [ide, debug]
    
  - app: "Spotify"
    float: true

keybindings:
  cycleLayout: "cmd+shift+space"
  focusLeft: "cmd+h"
  focusRight: "cmd+l"
  focusUp: "cmd+k"
  focusDown: "cmd+j"
  moveToCell1: "cmd+shift+1"
  moveToCell2: "cmd+shift+2"
  moveToCell3: "cmd+shift+3"
  moveToCell4: "cmd+shift+4"
  toggleStackMode: "cmd+shift+t"
  reapplyLayout: "cmd+shift+r"
```

### 10.3 Ultrawide Monitor Setup

```yaml
layouts:
  - id: ultrawide-focus
    name: "Ultrawide Focus"
    grid:
      columns: [4fr, 1fr]
      rows: [1fr, 1fr]
    areas:
      - [main, comms]
      - [main, media]
    cellModes:
      main: vertical
      comms: tabs
      media: tabs
      
  - id: ultrawide-split
    name: "Ultrawide Split"
    grid:
      columns: [1fr, 2fr, 1fr]
      rows: [1fr]
    areas:
      - [left, center, right]
    cellModes:
      left: tabs
      center: vertical
      right: tabs
```

### 10.4 Vertical Monitor Setup

```yaml
layouts:
  - id: vertical-stack
    name: "Vertical Stack"
    grid:
      columns: [1fr]
      rows: [1fr, 2fr, 1fr]
    areas:
      - [top]
      - [middle]
      - [bottom]
    cellModes:
      top: tabs
      middle: vertical
      bottom: tabs
```

---

## 11. Edge Cases and Constraints

### 11.1 Window Size Constraints

**Problem:** Applications may have minimum/maximum size requirements.

**Solution:**
1. Query window's min/max size via Accessibility API
2. Respect these constraints when calculating bounds
3. If window cannot fit in assigned space, either:
   - Float the window (exclude from layout)
   - Assign to larger cell
   - Skip tiling this window entirely

### 11.2 Cell Overflow

**Problem:** More windows than cells in layout.

**Solution:** Stack multiple windows per cell using stack mode. Default to equal splits, allow manual adjustment.

### 11.3 Empty Cells

**Problem:** Fewer windows than cells in layout.

**Solution:** Leave cells empty. Display empty cell boundaries visually (optional feature).

### 11.4 Misaligned Grids

**Problem:** Screen dimensions don't divide evenly by track ratios.

**Solution:** Accept sub-pixel positioning (use floats, round to nearest pixel in final step).

### 11.5 Rapid Layout Switching

**Problem:** User rapidly cycles layouts; animations conflict.

**Solution:** Cancel in-flight animations, immediately apply new layout.

### 11.6 Application Resistance

**Problem:** Some apps resist programmatic resizing (e.g., Settings, Preferences).

**Solution:**
- Retry with slight delay
- Mark app as "resistant" and auto-float after N failures
- Allow user to manually float via `appRules`

### 11.7 Fullscreen Apps

**Problem:** Fullscreen apps hide the desktop and other windows.

**Solution:** Detect fullscreen state, exclude from layout, restore when exiting fullscreen.

---

## 12. Technical Constraints

### 12.1 Language Choice

**Recommended:** Swift
- Native macOS integration
- Direct Accessibility API access
- Type safety
- Modern concurrency (async/await)
- Easy to distribute via App Store (if using public APIs only)

**Alternative:** Rust
- Better performance
- Memory safety
- Good Objective-C interop via objc crate
- Steeper learning curve for macOS APIs

### 12.2 Minimum macOS Version

Target: macOS 12.0 (Monterey) or later
- Modern Accessibility APIs
- Stable window management
- Large install base

### 12.3 Performance Requirements

- Layout application: <100ms for 20 windows
- Focus navigation: <16ms (60 FPS)
- Memory footprint: <50MB
- CPU usage when idle: <1%

### 12.4 Testing Strategy

**Unit Tests:**
- Grid calculation algorithm
- Window assignment logic
- Focus navigation
- Split ratio adjustment

**Integration Tests:**
- Mock Accessibility API responses
- End-to-end layout application
- Configuration parsing

**Manual Tests:**
- Real applications with various window sizes
- Multi-monitor setups
- Space switching
- Hotkey conflicts

---

## 13. Success Metrics

**Core Functionality:**
- ✅ Apply layouts to arbitrary window counts
- ✅ Cycle through layouts smoothly
- ✅ Navigate focus directionally
- ✅ Persist state across Space switches
- ✅ Handle window lifecycle events

**Performance:**
- ✅ <100ms layout application time
- ✅ No dropped frames during transitions
- ✅ No memory leaks over extended use

**Usability:**
- ✅ Simple default configuration for new users
- ✅ Clear documentation with examples
- ✅ Intuitive keybindings
- ✅ Recoverable from errors (malformed config, permission denied)

---

## 14. Open Questions

1. **Private vs Public APIs:** What level of macOS integration is acceptable? Should we have two versions (basic/advanced)?

2. **Animation Strategy:** Animate windows independently or as a group? Stagger animations for visual effect?

3. **Configuration Hot-Reload:** Watch filesystem for changes or require manual reload command?

4. **Window Order:** Should window order within cells be stable across layout switches? Or always auto-flow?

5. **Floating Windows:** How to handle floating windows when applying a layout? Ignore them, or bring them back into layout?

6. **External Displays:** When a display disconnects, what happens to its windows? Move to main display? Remember positions for reconnect?

7. **Mission Control Integration:** Should layouts sync with Mission Control's Space visualization?

---

## Appendix A: Accessibility API Reference

Key Accessibility API calls and their usage:

```swift
// Window enumeration
let windows = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID)

// Window position/size
AXUIElementCopyAttributeValue(window, kAXPositionAttribute, &position)
AXUIElementCopyAttributeValue(window, kAXSizeAttribute, &size)

// Set window bounds
AXUIElementSetAttributeValue(window, kAXPositionAttribute, newPosition)
AXUIElementSetAttributeValue(window, kAXSizeAttribute, newSize)

// Observer for window events
AXObserverCreate(pid, callback, &observer)
AXObserverAddNotification(observer, window, kAXWindowCreatedNotification, context)
```

## Appendix B: Example CLI Usage

```bash
# Apply a layout
grid layout apply ide

# Cycle layouts
grid layout cycle

# Move focus
grid focus left
grid focus cell editor

# Move window
grid window move --window-id 123 --cell terminal
grid window move-direction right

# Query state
grid list windows
grid layout current

# Configuration
grid config show
grid config validate

# Debugging
grid state show
grid list spaces
```

---

**End of Technical Specification**
