# theGrid Layouts Feature

A comprehensive reference for the grid-based tiling window management system.

---

## 1. Overview

theGrid uses a **CSS Grid-inspired layout model** for organizing windows on macOS. You define 2D grid layouts with named cells, and windows flow into those cells automatically or via rules.

### Core Philosophy

- **Layouts are fixed, windows are dynamic** - Define grid structures once; windows flow into them
- **Layout cycling over manual placement** - Switch between predefined layouts rather than manually positioning windows
- **Grid integrity is maintained** - Cell boundaries are fixed by the layout; only internal splits between windows are adjustable
- **Progressive complexity** - Simple equal-column layouts by default, advanced features available when needed

---

## 2. Quick Start

### Minimal Configuration

Create `~/.config/thegrid/config.yaml`:

```yaml
settings:
  defaultStackMode: vertical

layouts:
  - id: two-col
    name: "Two Column"
    grid:
      columns: ["1fr", "1fr"]
      rows: ["1fr"]
    areas:
      - [left, right]
```

### Essential Commands

```bash
grid layout list          # See available layouts
grid layout apply two-col # Apply a layout
grid layout cycle         # Switch to next layout
grid focus right          # Move focus to adjacent cell
```

---

## 3. Core Concepts

### Layouts

A **Layout** defines a 2D grid structure with:
- **Columns and rows** (tracks) with flexible sizing
- **Cells** - named rectangular regions that contain windows
- **Cell modes** - how multiple windows stack within a cell

### Cells

A **Cell** is a rectangular region in the grid:
- Has a unique identifier (e.g., `editor`, `terminal`, `sidebar`)
- Can span multiple columns and/or rows
- Contains zero or more windows
- Has a stack mode determining how multiple windows are arranged

### Track Sizing

Columns and rows support four sizing modes:

| Type | Example | Behavior |
|------|---------|----------|
| **Fractional** | `"1fr"`, `"2fr"` | Proportional distribution of remaining space |
| **Fixed** | `"300px"` | Exact pixel size |
| **Auto** | `"auto"` | Content-based sizing |
| **MinMax** | `"minmax(200px, 1fr)"` | Flexible with constraints |

### Stack Modes

When a cell contains multiple windows:

| Mode | Behavior |
|------|----------|
| **vertical** | Windows stack top-to-bottom, each gets full width |
| **horizontal** | Windows stack left-to-right, each gets full height |
| **tabs** | Only one window visible at a time |

### Assignment Strategies

How windows are distributed to cells:

| Strategy | Description |
|----------|-------------|
| **AutoFlow** | Distribute windows evenly across cells (round-robin) |
| **Pinned** | Use app rules to assign specific apps to preferred cells |
| **Preserve** | Keep previous cell assignments when switching layouts |

---

## 4. Configuration Reference

### File Location

`~/.config/thegrid/config.yaml`

### Top-Level Structure

```yaml
settings:       # Global settings
layouts:        # Layout definitions
spaces:         # Per-Space configuration
appRules:       # Application-specific rules
```

### Settings

```yaml
settings:
  defaultStackMode: vertical    # vertical | horizontal | tabs
  cellPadding: 8                # Pixels between windows in a cell
```

### Layout Definition

```yaml
layouts:
  - id: ide                      # Unique identifier (required)
    name: "IDE Layout"           # Display name (required)
    description: "For coding"    # Optional

    grid:
      columns: ["300px", "1fr", "1fr"]
      rows: ["2fr", "1fr"]

    # Option A: ASCII areas syntax
    areas:
      - [sidebar, editor, editor]
      - [sidebar, terminal, preview]

    # Option B: Explicit cell definitions
    cells:
      - id: sidebar
        column: "1/2"            # Column start/end (1-indexed)
        row: "1/3"               # Row start/end

    # Per-cell stack mode overrides
    cellModes:
      sidebar: tabs
      editor: vertical
```

### Space Configuration

```yaml
spaces:
  "1":                           # Space ID
    name: "Development"
    layouts: [ide, focus, debug] # Available layouts for cycling
    defaultLayout: ide
    autoApply: false             # Auto-apply on space switch
```

### App Rules

```yaml
appRules:
  - app: "Visual Studio Code"    # App name or bundle ID
    preferredCell: editor
    layouts: [ide]               # Only for these layouts

  - app: "Terminal"
    preferredCell: terminal

  - app: "Spotify"
    float: true                  # Never tile this app
```

### Complete Example

```yaml
settings:
  defaultStackMode: vertical
  cellPadding: 8

layouts:
  - id: focus
    name: "Focus"
    grid:
      columns: ["1fr"]
      rows: ["1fr"]
    areas:
      - [main]

  - id: ide
    name: "IDE Layout"
    grid:
      columns: ["300px", "1fr", "1fr"]
      rows: ["2fr", "1fr"]
    areas:
      - [sidebar, editor, editor]
      - [sidebar, terminal, preview]
    cellModes:
      sidebar: tabs
      editor: vertical
      terminal: horizontal

spaces:
  "1":
    name: Development
    layouts: [ide, focus]
    defaultLayout: ide

appRules:
  - app: "Code"
    preferredCell: editor
  - app: "Terminal"
    preferredCell: terminal
  - app: "Spotify"
    float: true
```

---

## 5. CLI Commands Reference

### Layout Management

```bash
grid layout list                 # List all available layouts
grid layout show <id>            # Show layout details
grid layout apply <id>           # Apply layout to current space
grid layout apply <id> --space 2 # Apply to specific space
grid layout cycle                # Cycle to next layout
grid layout current              # Show current layout
grid layout reapply              # Reapply current layout (refresh)
```

### Focus Navigation

```bash
grid focus left                  # Move focus to cell on left
grid focus right                 # Move focus to cell on right
grid focus up                    # Move focus to cell above
grid focus down                  # Move focus to cell below
grid focus next                  # Cycle to next window in cell
grid focus prev                  # Cycle to previous window in cell
grid focus cell <id>             # Jump focus to specific cell
```

### Resize / Split Adjustment

```bash
grid resize grow                 # Grow focused window by 10%
grid resize grow 0.2             # Grow by 20%
grid resize shrink               # Shrink focused window by 10%
grid resize shrink 0.15          # Shrink by 15%
grid resize reset                # Reset splits in focused cell
grid resize reset --all          # Reset all splits in layout
```

### Configuration

```bash
grid config show                 # Show current config as JSON
grid config validate             # Validate config file
grid config validate /path/to/config.yaml
grid config init                 # Create default config
```

### State Management

```bash
grid state show                  # Show runtime state
grid state reset                 # Clear all state
```

---

## 6. Architecture & Internals

### System Layers

```
Configuration Layer
    ↓ YAML parsing, validation, layout definitions
Core Logic Layer
    ↓ Grid calculations, window assignment, focus navigation
macOS Integration Layer
    ↓ Accessibility API (window control), Spaces detection
IPC/API Layer
    CLI commands, state queries, Unix socket communication
```

### Package Organization

| Package | Purpose |
|---------|---------|
| `internal/types` | Shared type definitions (Layout, Cell, TrackSize, etc.) |
| `internal/config` | Configuration loading, parsing, validation |
| `internal/layout` | Grid calculations, window assignment, split ratios |
| `internal/state` | Runtime state persistence |
| `internal/focus` | Focus navigation between cells and windows |

### Data Flow: Layout Application

```
User runs: grid layout apply ide
    ↓
Load layout definition from config
    ↓
Get current space ID and display bounds
    ↓
Calculate track sizes (columns, rows) → pixel values
    ↓
Calculate cell bounds from grid
    ↓
Get windows on current space from server
    ↓
Assign windows to cells (AutoFlow/Pinned/Preserve)
    ↓
Calculate window positions within cells (stack mode + ratios)
    ↓
Send window positions to server
    ↓
Persist state to ~/.local/state/thegrid/state.json
```

### Key Algorithms

**Track Size Calculation:**
1. Allocate fixed (`px`) tracks first
2. Calculate one fractional unit from remaining space
3. Apply `minmax` constraints with clamping
4. Distribute remaining space proportionally to `fr` tracks

**Window Assignment (AutoFlow):**
1. Sort cells by visual position (top-to-bottom, left-to-right)
2. Filter out floating/minimized/hidden windows
3. Round-robin distribute windows across cells
4. Multiple windows per cell stack according to cell mode

**Focus Navigation:**
1. Calculate cell centers from bounds
2. Find cells in the specified direction
3. Select closest cell using weighted distance (primary + perpendicular×2)
4. Support wrap-around at screen edges

---

## 7. Data Model Reference

### Layout

Defines a grid structure:
- **ID**: Unique identifier for referencing
- **Columns/Rows**: Track size definitions
- **Cells**: Named regions with grid positions
- **CellModes**: Per-cell stack mode overrides

### Cell

A rectangular region in the grid:
- **ID**: Unique identifier
- **Grid position**: Column/row start and end (1-indexed, exclusive end)
- **StackMode**: How windows are arranged (inherited from layout default or overridden)

### TrackSize

Defines column or row sizing:
- **Type**: `fr` (fractional), `px` (fixed), `auto`, or `minmax`
- **Value**: The numeric value (e.g., `1` for `1fr`, `300` for `300px`)
- **Min/Max**: Constraints for `minmax` type

### RuntimeState

Persisted state tracking:
- **Spaces**: Map of space ID to space state
- **Per-space**: Current layout, layout cycle index, cell states, focus tracking
- **Per-cell**: Window IDs, split ratios, stack mode override

### Window Classification

Windows are categorized as:
- **Standard**: Normal windows for tiling
- **Floating**: Tracked but not tiled (via app rules or window type)
- **Excluded**: Minimized, hidden, or overlay windows (ignored)

---

## 8. Key Files

### Feature Specification
- `.features/layouts/Specification.md` - Full technical spec
- `.features/layouts/phases/` - Phase-by-phase implementation specs
- `.features/layouts/DEVIATIONS.md` - Implementation deviations from spec

### Implementation
- `grid-cli/internal/types/layout_types.go` - Core type definitions
- `grid-cli/internal/config/` - Configuration loading and parsing
- `grid-cli/internal/layout/` - Grid engine, assignment, splits
- `grid-cli/internal/state/` - Runtime state persistence
- `grid-cli/internal/focus/` - Focus navigation
- `grid-cli/cmd/grid/main.go` - CLI commands

### Runtime Files
- `~/.config/thegrid/config.yaml` - User configuration
- `~/.local/state/thegrid/state.json` - Runtime state (auto-managed)

---

## Quick Reference Card

| Action | Command |
|--------|---------|
| Apply layout | `grid layout apply <id>` |
| Cycle layout | `grid layout cycle` |
| Focus left/right/up/down | `grid focus <direction>` |
| Focus next window in cell | `grid focus next` |
| Grow focused window | `grid resize grow` |
| Reset splits | `grid resize reset` |
| Show current layout | `grid layout current` |
| Validate config | `grid config validate` |
