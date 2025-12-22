# Cell Mode Command Design

Add a CLI command to toggle or set the stack mode for the currently focused cell.

## Command Interface

```
thegrid cell mode [mode]
```

**Arguments:**
- `mode` (optional): `vertical`, `horizontal`, or `tabs`

**Behavior:**
- No argument: cycle through modes (vertical → horizontal → tabs → vertical)
- With argument: set the specified mode directly
- Operates on the currently focused cell (determined from focused window)

**Output:**
```
# Success
✓ Cell "left" mode: tabs

# Errors
✗ No focused cell
✗ Invalid mode "foo" - use: vertical, horizontal, tabs
```

## Implementation Flow

File: `grid-cli/cmd/grid/main.go` (add to existing `cellCmd` group)

```
1. ctx := context.Background()
2. Load config (gridConfig.LoadConfig) and runtime state (gridState.LoadState)
3. Fetch server snapshot: snap := gridServer.Fetch(ctx, c)
4. Reconcile local state: gridReconcile.Sync(ctx, c, snap, rs, cfg)
   - This syncs snap.FocusedWindowID into spaceState.FocusedCell
5. Get space and focused cell:
   - spaceState := rs.GetSpaceReadOnly(snap.SpaceID)
   - cellID := spaceState.FocusedCell
   - Error if cellID == "" ("no focused cell")
6. Determine new mode:
   - If arg provided: validate with parseStackMode(), error if invalid
   - If no arg: get effective mode → cycle with nextMode()
7. Update state:
   - rs.SetCellStackMode(snap.SpaceID, cellID, newMode)
8. Reapply layout:
   - Call layout.ReapplyLayout() (handles window positioning + border sync + state save)
9. Print success: ✓ Cell "cellID" mode: newMode
```

Follows the exact pattern of `cell send` in `/grid-cli/internal/cell/send.go`.

## Mode Validation

```go
func parseStackMode(s string) (types.StackMode, error) {
    mode := types.StackMode(s)
    switch mode {
    case types.StackVertical, types.StackHorizontal, types.StackTabs:
        return mode, nil
    default:
        return "", fmt.Errorf("invalid mode %q - use: vertical, horizontal, tabs", s)
    }
}
```

## Mode Cycling

```go
func nextMode(current types.StackMode) types.StackMode {
    switch current {
    case types.StackVertical:
        return types.StackHorizontal
    case types.StackHorizontal:
        return types.StackTabs
    case types.StackTabs:
        return types.StackVertical
    default:
        return types.StackVertical
    }
}
```

## Mode Resolution

StackMode has a priority hierarchy. When cycling, we resolve the current effective mode:

1. **Runtime state override** - `CellState.StackMode` (what we're setting)
2. **Cell config** - `layout.Cells[].StackMode` in config.yaml
3. **Layout cellModes** - `layout.CellModes[cellID]` map
4. **Settings default** - `settings.defaultStackMode`

```go
func getEffectiveMode(rs *state.RuntimeState, cfg *config.Config, spaceID, cellID, layoutID string) types.StackMode {
    // 1. Check runtime override
    if mode := rs.GetCellStackMode(spaceID, cellID); mode != "" {
        return mode
    }

    // 2-3. Check layout config (cell-level and cellModes map)
    if layoutDef, ok := cfg.GetLayout(layoutID); ok {
        if mode := layoutDef.GetCellMode(cellID); mode != "" {
            return mode
        }
    }

    // 4. Fall back to settings default
    if cfg.Settings.DefaultStackMode != "" {
        return cfg.Settings.DefaultStackMode
    }

    return types.StackVertical
}
```

The runtime override takes precedence, preserving config defaults while allowing runtime changes.

## Persistence

The mode change persists via the existing state management:

```
SetCellStackMode()  → Updates in-memory CellState.StackMode
ReapplyLayout()     → Repositions windows, calls runtimeState.Save()
runtimeState.Save() → Writes to ~/.local/state/thegrid/state.json
```

The mode persists until changed again or a layout reset occurs.

## Error Handling

| Scenario | Response |
|----------|----------|
| No focused cell | `✗ No focused cell` |
| Invalid mode arg | `✗ Invalid mode "foo" - use: vertical, horizontal, tabs` |
| Server unreachable | `✗ Failed to connect to server: ...` |

## Dependencies

No new packages or server changes required. Uses existing:

- `gridServer.Fetch()` - get current window/space state
- `gridReconcile.Sync()` - sync local state with server
- `rs.SetCellStackMode()` - exists in `state/queries.go`
- `layout.ReapplyLayout()` - exists in `layout/apply.go`

Follows the same pattern as `cell send` command.
