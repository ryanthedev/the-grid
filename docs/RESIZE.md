# Resize Operations

A guide to adjusting window and cell sizes in theGrid.

---

## 1. Overview

theGrid provides two types of resize operations:

| Type | Command | What it adjusts |
|------|---------|-----------------|
| **Window Splits** | `grid resize grow/shrink` | Ratio between stacked windows within a cell |
| **Cell Boundaries** | `grid resize cell` | Size of cells in the grid layout |

**Window splits** adjust how space is divided between multiple windows in the same cell. Use this when you want one window larger than others in a stack.

**Cell boundaries** adjust the grid structure itself. Use this when you want an entire cell (and all its windows) to be larger.

---

## 2. Window Splits

Adjust the size ratio between windows stacked in the same cell.

### Commands

```bash
grid resize grow [amount]      # Grow focused window (default: 10%)
grid resize shrink [amount]    # Shrink focused window (default: 10%)
grid resize reset              # Reset splits in focused cell to equal
grid resize reset --all        # Reset all splits across entire layout
```

### Examples

```bash
# Make the focused window take more space
grid resize grow

# Grow by a specific amount (20%)
grid resize grow 0.2

# Shrink the focused window
grid resize shrink

# Reset to equal sizes
grid resize reset
```

### Notes

- Only affects cells with **multiple windows** (no effect on single-window cells)
- Works with `vertical` and `horizontal` stack modes
- Each window has a **minimum size of 10%** to prevent windows from becoming too small
- The amount parameter is a ratio (0.1 = 10%, 0.2 = 20%)

---

## 3. Cell Boundaries

Adjust the size of cells within your grid layout.

### Commands

```bash
grid resize cell left [amount]    # Expand cell leftward
grid resize cell right [amount]   # Expand cell rightward
grid resize cell up [amount]      # Expand cell upward
grid resize cell down [amount]    # Expand cell downward
grid resize reset --cells         # Reset all cell ratios to layout defaults
```

### How Direction Works

The direction indicates which **edge** of your focused cell to push:

| Direction | Effect |
|-----------|--------|
| `left` | Pushes left edge leftward (cell grows, neighbor shrinks) |
| `right` | Pushes right edge rightward (cell grows, neighbor shrinks) |
| `up` | Pushes top edge upward (cell grows, neighbor shrinks) |
| `down` | Pushes bottom edge downward (cell grows, neighbor shrinks) |

### Examples

```bash
# Make the focused cell wider
grid resize cell right

# Make the focused cell taller
grid resize cell down 0.15

# Reset all cells to original proportions
grid resize reset --cells
```

### Notes

- Only works with **flexible tracks** (`fr` or `minmax` in your layout)
- Fixed pixel tracks (`px`) cannot be resized
- Respects `maxRatio` configuration to prevent cells from growing too large

---

## 4. Configuration

Resize behavior can be customized in `~/.config/thegrid/config.yaml`:

```yaml
settings:
  resize:
    maxRatio: 0.8    # Maximum ratio any window/cell can occupy (default: 0.8)
```

The `maxRatio` setting prevents any single window or cell from taking more than the specified proportion of the available space.

---

## 5. Tips

### Keyboard Bindings

Add to your skhd config for quick access:

```bash
# Window splits (grow/shrink focused window)
ctrl + cmd - equal : grid resize grow
ctrl + cmd - minus : grid resize shrink

# Cell boundaries (resize entire cell)
ctrl + shift - h : grid resize cell left
ctrl + shift - l : grid resize cell right
ctrl + shift - k : grid resize cell up
ctrl + shift - j : grid resize cell down

# Reset
ctrl + cmd - 0 : grid resize reset
```

### Common Workflows

**Terminal + Editor layout**: Use `grid resize cell right` to give your editor more horizontal space, then use `grid resize grow` to make a specific terminal larger within a stack.

**Quick reset**: If your layout feels cluttered after many adjustments, `grid resize reset --all && grid resize reset --cells` returns everything to defaults.
