# Space ID Migration - Phase 1 Design

**Goal:** Automatically remap space state when macOS reassigns space IDs on wake.

**Problem:** When the system wakes from sleep, macOS may reassign space IDs. If a user has grid layouts saved to a space, those layouts become inaccessible because the old space ID no longer maps to the same workspace.

**Solution:** Track display-to-space mappings in state, detect when space IDs change, and migrate layout state to the new space ID.

---

## Discovery Findings

### Key Types and Patterns

#### RuntimeState (state.go:16-22)
```go
type RuntimeState struct {
    Version     int                    `json:"version"`
    Spaces      map[string]*SpaceState `json:"spaces"` // spaceID -> state
    LastUpdated time.Time              `json:"lastUpdated"`
    mu          sync.RWMutex           `json:"-"`
}
```

- Thread-safe via `mu` RWMutex
- Spaces are keyed by space ID string (converted from float64/int)
- Methods: `GetSpace(spaceID)`, `GetSpaceReadOnly(spaceID)`, `RemoveSpace(spaceID)`, `MarkUpdated()`

#### SpaceState (state.go:24-34)
```go
type SpaceState struct {
    SpaceID         string                `json:"spaceId"`
    CurrentLayoutID string                `json:"currentLayoutId"`
    LayoutIndex     int                   `json:"layoutIndex"`
    Cells           map[string]*CellState `json:"cells"`
    FocusedCell     string                `json:"focusedCell"`
    FocusedWindow   int                   `json:"focusedWindow"`
    ColumnRatios    []float64             `json:"columnRatios,omitempty"`
    RowRatios       []float64             `json:"rowRatios,omitempty"`
}
```

Tracks layout and focus state for a single space.

#### DisplayInfo (snapshot.go:17-25)
```go
type DisplayInfo struct {
    UUID           string
    Name           string
    Frame          types.Rect
    VisibleFrame   types.Rect
    CurrentSpaceID interface{} // Can be int, float64, or bool (overflow)
    IsMain         bool
}
```

- `CurrentSpaceID` is stored as `interface{}` to handle JSON number overflow
- Snapshot.AllDisplays contains all connected displays
- One DisplayInfo per physical display

#### Space ID Conversion Pattern
From snapshot.go (lines 149-161, 219, 332):
```go
spaceIDStr := ""
switch v := display.CurrentSpaceID.(type) {
case float64:
    spaceIDStr = fmt.Sprintf("%.0f", v)
case int:
    spaceIDStr = fmt.Sprintf("%d", v)
case string:
    spaceIDStr = v
}
```

Or using `interfaceToInt()` helper (line 607-619):
```go
func interfaceToInt(v interface{}) int64 {
    switch n := v.(type) {
    case float64:
        return int64(n)
    case int:
        return int64(n)
    case int64:
        return n
    case int32:
        return int64(n)
    default:
        return 0
    }
}
```

### State Persistence
- **Load:** `LoadStateFrom(path)` -> unmarshal JSON -> initialize nil maps
- **Save:** `SaveTo(path)` -> marshal with indent -> atomic write via temp file
- **Nil handling:** `LoadStateFrom()` initializes nil `Spaces` and nested `Cells` maps (lines 51-60)

### Reconciliation Pattern
From reconcile.go:
- `Sync()` is called before each command execution (line 23)
- Takes: context, client, snapshot, RuntimeState, config
- Returns error if state changed during sync
- Example: syncs window membership (removes windows that no longer exist), syncs focus

---

## Implementation Pseudocode

### 1. state.go Changes

#### Add DisplaySpaces field to RuntimeState
```go
type RuntimeState struct {
    Version        int                    `json:"version"`
    Spaces         map[string]*SpaceState `json:"spaces"`
    DisplaySpaces  map[string]string      `json:"displaySpaces"` // displayUUID -> current spaceID
    LastUpdated    time.Time              `json:"lastUpdated"`
    mu             sync.RWMutex           `json:"-"`
}
```

#### Update NewRuntimeState() constructor
```go
func NewRuntimeState() *RuntimeState {
    return &RuntimeState{
        Version:       StateVersion,
        Spaces:        make(map[string]*SpaceState),
        DisplaySpaces: make(map[string]string),   // Initialize empty map
        LastUpdated:   time.Now(),
    }
}
```

#### Add MigrateSpaceIDs method
```go
// MigrateSpaceIDs detects space ID changes and migrates layout state.
// Returns true if any migration occurred.
// Thread-safe: acquires lock internally.
func (rs *RuntimeState) MigrateSpaceIDs(allDisplays []server.DisplayInfo) bool {
    rs.mu.Lock()
    defer rs.mu.Unlock()

    migrated := false

    for _, display := range allDisplays {
        // Convert CurrentSpaceID to string (same conversion as snapshot.go)
        newSpaceID := convertDisplaySpaceID(display.CurrentSpaceID)
        if newSpaceID == "" {
            continue
        }

        // Get the display UUID as key
        displayUUID := display.UUID
        if displayUUID == "" {
            continue
        }

        // Look up the old space ID we had recorded for this display
        oldSpaceID := rs.DisplaySpaces[displayUUID]

        // If space ID changed
        if oldSpaceID != "" && oldSpaceID != newSpaceID {
            // Check if old space has state worth migrating
            oldState := rs.Spaces[oldSpaceID]
            if oldState != nil && hasSignificantState(oldState) {
                // Migrate: copy old state to new space ID
                rs.Spaces[newSpaceID] = oldState
                // Update the SpaceID field to match the new key
                oldState.SpaceID = newSpaceID
                // Remove the old key
                delete(rs.Spaces, oldSpaceID)
                migrated = true

                // Log the migration
                jsonlog.Log("state.space_migrated",
                    jsonlog.WithData(map[string]any{
                        "displayUUID": displayUUID,
                        "oldSpaceID":  oldSpaceID,
                        "newSpaceID":  newSpaceID,
                    }))
            }
        }

        // Update the mapping regardless (new baseline for next check)
        rs.DisplaySpaces[displayUUID] = newSpaceID
    }

    return migrated
}

// Helper: convert interface{} space ID to string (mirrors snapshot.go logic)
func convertDisplaySpaceID(v interface{}) string {
    switch val := v.(type) {
    case float64:
        return fmt.Sprintf("%.0f", val)
    case int:
        return fmt.Sprintf("%d", val)
    case string:
        return val
    default:
        return ""
    }
}

// Helper: check if space state has meaningful content to migrate
func hasSignificantState(ss *SpaceState) bool {
    // Migrate if:
    // - Has a current layout set
    // - OR has cells with windows
    if ss.CurrentLayoutID != "" {
        return true
    }
    if len(ss.Cells) > 0 {
        return true
    }
    return false
}
```

---

### 2. persistence.go Changes

#### Update LoadStateFrom to initialize DisplaySpaces
```go
func LoadStateFrom(path string) (*RuntimeState, error) {
    data, err := os.ReadFile(path)
    if err != nil {
        if os.IsNotExist(err) {
            return NewRuntimeState(), nil
        }
        return nil, fmt.Errorf("failed to read state file: %w", err)
    }

    var state RuntimeState
    if err := json.Unmarshal(data, &state); err != nil {
        return nil, fmt.Errorf("failed to parse state file: %w", err)
    }

    // Handle version migration if needed
    if state.Version < StateVersion {
        state = *migrateState(&state)
    }

    // Initialize maps if nil (not persisted or old format)
    if state.Spaces == nil {
        state.Spaces = make(map[string]*SpaceState)
    }
    
    // Initialize DisplaySpaces if nil (new field for migration)
    if state.DisplaySpaces == nil {
        state.DisplaySpaces = make(map[string]string)
    }

    // Ensure nested maps are initialized
    for _, space := range state.Spaces {
        if space.Cells == nil {
            space.Cells = make(map[string]*CellState)
        }
    }

    return &state, nil
}
```

---

### 3. reconcile.go Changes

#### Update Sync() to call MigrateSpaceIDs
```go
func Sync(ctx context.Context, c *client.Client, snap *server.Snapshot, rs *state.RuntimeState, cfg *config.Config) error {
    // FIRST: Migrate space IDs in case of wake/sleep reassignment
    if migrated := rs.MigrateSpaceIDs(snap.AllDisplays); migrated {
        rs.MarkUpdated()
        if err := rs.Save(); err != nil {
            return err
        }
        jsonlog.Log("sync.space_migration_saved")
    }

    // NOW: Continue with normal reconciliation logic
    spaceState := rs.GetSpaceReadOnly(snap.SpaceID)
    if spaceState == nil {
        return nil
    }

    changed := false
    for cellID, cell := range spaceState.Cells {
        var valid []uint32
        for _, wid := range cell.Windows {
            if snap.WindowIDs[wid] {
                valid = append(valid, wid)
            }
        }

        if len(valid) != len(cell.Windows) {
            mutableCell := rs.GetSpace(snap.SpaceID).GetCell(cellID)
            mutableCell.Windows = valid
            mutableCell.SplitRatios = equalRatios(len(valid))
            changed = true
        }
    }

    // Sync focus
    if snap.FocusedWindowID != 0 {
        if syncFocus(snap, rs) {
            changed = true
        }
    }

    if changed {
        rs.MarkUpdated()
        if err := rs.Save(); err != nil {
            return err
        }
    }

    return nil
}
```

---

## Thread Safety & Locking Strategy

### MigrateSpaceIDs
- Acquires `rs.mu.Lock()` at start, releases with defer unlock
- Operates on `rs.Spaces` and `rs.DisplaySpaces` under lock
- No blocking I/O while locked

### State Persistence
- `Save()` acquires `rs.mu.RLock()` before marshaling
- Safe to call with other goroutines reading state

### Reconcile.Sync
- Calls `rs.GetSpaceReadOnly()` (acquires RLock internally)
- Calls `rs.MigrateSpaceIDs()` (acquires full Lock internally)
- Calls `rs.MarkUpdated()` and `rs.Save()` (acquires Lock internally)
- Pattern is safe: nested locks follow proper hierarchy (Read-only -> Lock -> RLock for state access)

---

## Logging

All logging uses JSONL format to `~/.local/state/thegrid/thegrid-cli.json`:

```go
// Migration detected and performed
jsonlog.Log("state.space_migrated",
    jsonlog.WithData(map[string]any{
        "displayUUID": "ABC123...",
        "oldSpaceID":  "2",
        "newSpaceID":  "5",
    }))

// State saved after migration
jsonlog.Log("sync.space_migration_saved")
```

---

## Edge Cases Handled

1. **No migration needed:** oldSpaceID == newSpaceID -> DisplaySpaces is updated, no state change
2. **Empty old space:** oldState.SpaceID != "" but no layout/cells -> skip migration (checked by hasSignificantState)
3. **New space (never seen before):** oldSpaceID == "" -> skip migration, just record mapping
4. **Space ID overflow:** CurrentSpaceID can be float64, int, or string; conversion handles all types
5. **Display unplugged then replugged:** DisplaySpaces[uuid] = "" (lost), then re-assigned later. If a new space ID is assigned to a display we've lost track of, we treat it as a new space (no old state to migrate).
6. **Multi-display:** AllDisplays contains all displays; migration happens per-display independently
7. **Nil AllDisplays:** Loop is skipped safely

---

## Testing Strategy

Unit tests in `state_test.go`:

1. **Test MigrateSpaceIDs with no changes:** 
   - Create state with space ID "1" mapped to display "UUID-A"
   - Call MigrateSpaceIDs with AllDisplays containing UUID-A -> space "1"
   - Assert: migrated = false, DisplaySpaces unchanged, Spaces unchanged

2. **Test MigrateSpaceIDs with space ID change:**
   - Create state with space "1" + layout, DisplaySpaces["UUID-A"] = "1"
   - Call MigrateSpaceIDs with AllDisplays containing UUID-A -> space "5"
   - Assert: migrated = true, DisplaySpaces["UUID-A"] = "5", Spaces["5"] has layout, Spaces["1"] gone

3. **Test MigrateSpaceIDs with empty old space:**
   - Create state with space "1" (empty), DisplaySpaces["UUID-A"] = "1"
   - Call MigrateSpaceIDs with AllDisplays containing UUID-A -> space "5"
   - Assert: migrated = false (no significant state to migrate), DisplaySpaces["UUID-A"] = "5", Spaces["1"] still there

4. **Test LoadStateFrom with nil DisplaySpaces:**
   - Load old state.json without DisplaySpaces field
   - Assert: DisplaySpaces initialized to empty map

5. **Test Sync calls MigrateSpaceIDs before window cleanup:**
   - Create snapshot where a space ID has migrated
   - Call Sync
   - Assert: state is saved, migration logged
