# Pseudocode: Phase 2 - GridState Actor

## Design: GridState Actor

### Approaches Considered

1. **Single actor with flat methods** — One `GridState` actor that owns all state and exposes methods matching Go's API surface (getSpace, assignWindow, removeWindow, etc.). Persistence is an internal detail of the actor.

2. **Actor + separate Codable model structs** — Codable structs (`GridRuntimeState`, `GridSpaceStateData`, `GridCellStateData`) handle serialization. The `GridState` actor wraps them, provides mutation methods, and manages persistence. Models are value types passed in/out.

3. **Protocol-oriented with state store** — Define a `GridStateStore` protocol for persistence. Actor holds in-memory state and delegates save/load to a store implementation. Enables testing with in-memory store.

### Comparison

| Criterion | A: Flat actor | B: Actor + models | C: Protocol store |
|-----------|--------------|-------------------|-------------------|
| Interface simplicity | Good — direct methods | Good — same methods, clean serialization | Adds protocol overhead |
| Information hiding | High — all state internal | High — models are internal detail | Medium — store abstraction leaks |
| JSON compatibility | Must handle CodingKeys in actor | Clean separation — models own CodingKeys | Same as B but more indirection |
| Caller ease of use | Simple | Simple | Same but testability benefit unused (no tests planned) |
| Implementation effort | Low | Medium | Higher |

### Choice: B (Actor + separate Codable model structs)

Rationale: Clean separation between serialization (matching Go's JSON format with explicit CodingKeys) and business logic (mutations, queries, debounced persistence). The Codable structs are purely internal — callers never see them. This avoids cluttering the actor with CodingKeys while keeping JSON compatibility clean. Sacrifices: slightly more code than A, but the separation pays for itself in the CodingKeys complexity.

### Depth Check
- Interface methods: ~20 (matching Go's API surface — mutations + queries + persistence)
- Hidden details: JSON format, debounce timer, file I/O, ratio normalization, space ID migration logic
- Common case complexity: Simple — callers call `assignWindow`, `setFocus`, `cycleLayout` etc.

---

## Files to Create/Modify

- **Create:** `grid-server/Sources/GridServer/Grid/GridState.swift`

## Pseudocode

### Grid/GridState.swift

```
// MARK: - Codable Model Structs (internal, match Go JSON format)

// GridRuntimeStateData — root JSON structure
//   version: Int (always 1)
//   spaces: [String: GridSpaceStateData]
//   displaySpaces: [String: [String]]   // displayUUID -> ordered space IDs
//   lastUpdated: Date (ISO 8601)
//
//   CodingKeys: version, spaces, displaySpaces, lastUpdated
//   All keys match Go's json tags exactly

// GridSpaceStateData — per-space state
//   spaceId: String
//   currentLayoutId: String
//   layoutIndex: Int
//   cells: [String: GridCellStateData]
//   focusedCell: String
//   focusedWindow: Int
//   columnRatios: [Double]?   // omit if nil
//   rowRatios: [Double]?      // omit if nil
//
//   CodingKeys: spaceId, currentLayoutId, layoutIndex, cells,
//               focusedCell, focusedWindow, columnRatios, rowRatios

// GridCellStateData — per-cell state
//   cellId: String
//   windows: [UInt32]
//   splitRatios: [Double]
//   stackMode: String         // NOTE: encode GridStackMode? as String
//                              // nil -> "", .vertical -> "vertical", etc.
//                              // Custom encode/decode to match Go format
//   lastFocusedIdx: Int
//   lastFocusedWid: UInt32    // NOTE: "Wid" not "WID" to match Go
//   prevFocusedWid: UInt32
//
//   CodingKeys: cellId, windows, splitRatios, stackMode,
//               lastFocusedIdx, lastFocusedWid, prevFocusedWid
//
//   Custom Decodable for stackMode:
//     decode as String, if empty -> nil, else GridStackMode(rawValue:)
//   Custom Encodable for stackMode:
//     if nil -> encode "", else encode rawValue


// MARK: - GridState Actor

// actor GridState
//
//   Private state:
//     spaces: [String: GridSpaceStateData]   (keyed by space ID)
//     displaySpaces: [String: [String]]      (displayUUID -> ordered space IDs)
//     lastUpdated: Date
//
//   Persistence:
//     statePath: String  (resolved from XDG state home + "state.json")
//     saveTask: Task?    (debounce handle)
//     isDirty: Bool      (whether state changed since last save)
//     debounceInterval: Duration = .milliseconds(500)
//
//   Constants:
//     stateVersion = 1


// MARK: - Initialization + Load

// init()
//   Resolve statePath from XDG state home (~/.local/state/thegrid/state.json)
//   Initialize empty spaces and displaySpaces maps

// func load()
//   If state file exists at statePath:
//     Read file data
//     Decode as GridRuntimeStateData using JSONDecoder with ISO 8601 date strategy
//     Copy spaces, displaySpaces, lastUpdated from decoded data
//     Ensure all nested maps are non-nil (cells maps in each space)
//     Log "grid.state.load" with space count
//   Else:
//     Keep empty state (already initialized)
//     Log "grid.state.load.new"


// MARK: - Persistence (debounced)

// private func markDirty()
//   Set isDirty = true
//   Cancel existing saveTask if any
//   Create new saveTask that:
//     Try await Task.sleep(for: debounceInterval)
//     Call persistNow()

// private func persistNow()
//   Guard isDirty else return
//   Set isDirty = false
//   Set lastUpdated = Date()
//
//   Build GridRuntimeStateData from current state
//   Encode to JSON with .prettyPrinted and .sortedKeys
//   Use ISO 8601 date strategy (with fractional seconds to match Go)
//
//   Create parent directory if needed
//   Write to statePath + ".tmp"
//   Rename to statePath (atomic)
//   Log "grid.state.save"
//
//   On error: log "err.grid.state.save", set isDirty = true (retry next time)

// func flush()
//   If isDirty, call persistNow() immediately
//   (Called on shutdown for clean exit)

// func reset()
//   Clear spaces to empty map
//   Clear displaySpaces to empty map
//   Set isDirty and persist immediately


// MARK: - Space Access

// func getSpace(_ spaceID: String) -> GridSpaceStateData
//   If space exists, return it
//   Else create new empty GridSpaceStateData with spaceId = spaceID,
//     empty cells, layoutIndex 0
//   Store in spaces map and return it
//   (Does NOT markDirty — creating an empty space is not a state change)

// func getSpaceReadOnly(_ spaceID: String) -> GridSpaceStateData?
//   Return spaces[spaceID] or nil (no creation)

// func removeSpace(_ spaceID: String)
//   Delete from spaces map
//   markDirty()


// MARK: - Space ID Migration (sleep/wake)

// func migrateSpaceIDs(currentDisplaySpaces: [String: [String]]) -> Bool
//   For each (displayUUID, newSpaceList) in currentDisplaySpaces:
//     Skip if displayUUID empty or newSpaceList empty
//     Get oldSpaceList from self.displaySpaces[displayUUID]
//     For each position index up to min(oldList.count, newList.count):
//       Get oldSpaceID and newSpaceID at this index
//       Skip if either empty or they're equal
//       If spaces[oldSpaceID] exists and has significant state:
//         Move state: update spaceId field, move to new key, delete old key
//         Log "state.space_migrated" with display, old, new, position
//         Set migrated = true
//     Update displaySpaces[displayUUID] = newSpaceList (always, new baseline)
//   If migrated: markDirty()
//   Return migrated
//
// (helper) hasSignificantState(_ space) -> Bool
//   Return true if currentLayoutId is non-empty OR cells is non-empty


// MARK: - Layout Cycling

// func setCurrentLayout(spaceID: String, layoutID: String, layoutIndex: Int)
//   Get or create space
//   Set currentLayoutId = layoutID
//   Set layoutIndex = layoutIndex
//   Clear cells to empty map
//   Clear focusedCell to ""
//   Set focusedWindow = 0
//   Clear columnRatios and rowRatios to nil
//   markDirty()

// func cycleLayout(spaceID: String, availableLayouts: [String]) -> String
//   If availableLayouts is empty, return current layout ID for space
//   Get or create space
//   Compute newIndex = (space.layoutIndex + 1) % availableLayouts.count
//   Get newLayoutID = availableLayouts[newIndex]
//   Call setCurrentLayout(spaceID, newLayoutID, newIndex)
//   Return newLayoutID

// func previousLayout(spaceID: String, availableLayouts: [String]) -> String
//   If availableLayouts is empty, return current layout ID for space
//   Get or create space
//   Compute newIndex = (space.layoutIndex - 1 + availableLayouts.count) % availableLayouts.count
//   Get newLayoutID = availableLayouts[newIndex]
//   Call setCurrentLayout(spaceID, newLayoutID, newIndex)
//   Return newLayoutID

// func getCurrentLayout(spaceID: String) -> String
//   Return spaces[spaceID]?.currentLayoutId ?? ""


// MARK: - Window Assignment

// func assignWindow(_ windowID: UInt32, toCellID cellID: String, inSpace spaceID: String)
//   Get or create space, get or create cell
//   If window already in this cell, return (no-op)
//   Remove window from any other cell in this space (call removeWindow internally)
//   Append windowID to cell.windows
//   Set cell.lastFocusedIdx = windows.count - 1
//   Set cell.lastFocusedWid = windowID
//   Recalculate cell.splitRatios as equal ratios for new window count
//   markDirty()

// func prependWindow(_ windowID: UInt32, toCellID cellID: String, inSpace spaceID: String)
//   Get or create space and cell
//   If already at position 0, return
//   Remove from any cell (including this one if not at 0)
//   Prepend windowID to cell.windows
//   Set lastFocusedIdx = 0
//   Recalculate equal split ratios
//   markDirty()

// func insertWindow(_ windowID: UInt32, atIndex index: Int, inCellID cellID: String, inSpace spaceID: String)
//   Get or create space and cell
//   Remove from any cell first
//   Clamp index to [0, cell.windows.count]
//   Insert windowID at clamped index
//   Set lastFocusedIdx = clamped index
//   Set lastFocusedWid = windowID
//   Recalculate equal split ratios
//   markDirty()

// func removeWindow(_ windowID: UInt32, fromSpace spaceID: String)
//   Get space, return if not found
//   For each cell in space:
//     Find windowID in cell.windows
//     If found:
//       Remove from array
//       If cell now empty:
//         Reset lastFocusedIdx = 0, lastFocusedWid = 0, prevFocusedWid = 0
//       Else:
//         Clamp lastFocusedIdx to valid range
//         If lastFocusedWid was the removed window:
//           Try to restore prevFocusedWid if still in cell
//           Clear prevFocusedWid
//         If prevFocusedWid was the removed window:
//           Clear prevFocusedWid
//       Recalculate split ratios (equal for remaining, nil if empty)
//       markDirty()
//       Return

// func removeWindowFromAllSpaces(_ windowID: UInt32)
//   For each spaceID in spaces:
//     Call removeWindow(windowID, fromSpace: spaceID)


// MARK: - Window Queries

// func getWindowCell(windowID: UInt32, inSpace spaceID: String) -> String?
//   Search all cells in space for windowID
//   Return cellID if found, nil if not

// func getCellWindows(spaceID: String, cellID: String) -> [UInt32]
//   Return copy of cell's windows array, or empty if not found

// func getAllWindowIDs() -> [UInt32]
//   Collect all unique window IDs across all spaces
//   Return as array

// func getWindowAssignments(spaceID: String) -> [String: [UInt32]]
//   Return map of cellID -> copy of windows array for all non-empty cells

// func setWindowAssignments(spaceID: String, assignments: [String: [UInt32]])
//   Get or create space
//   Save existing cells for preserving state (splitRatios, stackMode, focus)
//   Create new cells map
//   For each (cellID, windowIDs) in assignments:
//     Create new cell with windowIDs
//     If cell existed before:
//       Preserve stackMode
//       Preserve focus by finding lastFocusedWID in new window list
//       Preserve or adjust splitRatios:
//         Same count -> copy ratios
//         Different count -> adjustRatiosForCount()
//     Else: use equal ratios
//   markDirty()


// MARK: - Focus Tracking

// func setFocus(spaceID: String, cellID: String, windowIndex: Int)
//   Get or create space
//   Set focusedCell = cellID
//   Set focusedWindow = windowIndex
//   If cell exists:
//     Set cell.lastFocusedIdx = windowIndex
//     If windowIndex in valid range:
//       Track previous: if lastFocusedWid != 0 and different from new, save to prevFocusedWid
//       Set lastFocusedWid = windows[windowIndex]
//   markDirty()

// func getFocusedWindow(spaceID: String) -> UInt32
//   Get space, return 0 if not found
//   Get focusedCell, return 0 if empty
//   Get cell, return 0 if not found or empty
//   Return windows[focusedWindow] clamped to valid range, or windows[0]

// func getFocusedCell(spaceID: String) -> String?
//   Return spaces[spaceID]?.focusedCell (nil if empty string or space not found)


// MARK: - Cell Stack Mode

// func getCellStackMode(spaceID: String, cellID: String) -> GridStackMode?
//   Return cell's stackMode if space and cell exist

// func setCellStackMode(spaceID: String, cellID: String, mode: GridStackMode?)
//   Get or create space and cell
//   Set cell.stackMode = mode (nil means "use default")
//   markDirty()


// MARK: - Split Ratios

// func getCellSplitRatios(spaceID: String, cellID: String) -> [Double]
//   Return copy of cell's splitRatios, or empty if not found

// func setCellSplitRatios(spaceID: String, cellID: String, ratios: [Double])
//   Get or create space and cell
//   Set cell.splitRatios = normalizeRatios(ratios)
//   markDirty()


// MARK: - Column/Row Ratios

// func getColumnRatios(spaceID: String) -> [Double]?
//   Return spaces[spaceID]?.columnRatios

// func setColumnRatios(spaceID: String, ratios: [Double])
//   Get or create space
//   Set space.columnRatios = normalizeRatios(ratios)
//   markDirty()

// func getRowRatios(spaceID: String) -> [Double]?
//   Return spaces[spaceID]?.rowRatios

// func setRowRatios(spaceID: String, ratios: [Double])
//   Get or create space
//   Set space.rowRatios = normalizeRatios(ratios)
//   markDirty()


// MARK: - Query Helpers

// func hasState(spaceID: String) -> Bool
//   Return true if space exists and has currentLayoutId or non-empty cells

// func summary() -> [String: Any]
//   Build dictionary with version, lastUpdated, spaceCount,
//   and per-space summary (layout, cellCount, windowCount, focusedCell)


// MARK: - Ratio Utilities (private)

// equalRatios(_ n: Int) -> [Double]
//   If n <= 0, return empty
//   Return array of n elements, each 1.0 / Double(n)

// normalizeRatios(_ ratios: [Double]) -> [Double]
//   If empty, return empty
//   Sum all ratios
//   If sum is 0, return equalRatios(ratios.count)
//   Return each ratio divided by sum

// adjustRatiosForCount(_ ratios: [Double], newCount: Int) -> [Double]
//   If newCount <= 0, return empty
//   If ratios empty, return equalRatios(newCount)
//   If same count, return normalizeRatios(ratios)
//   If shrinking: take first newCount ratios, renormalize
//   If growing:
//     Give new windows equal share (1.0 / newCount)
//     Scale existing ratios down proportionally
//     Normalize result
```

## Design Notes

### Actor vs Mutex
Go uses `sync.RWMutex` throughout `RuntimeState`. Swift actor isolation replaces this entirely. All methods are implicitly serialized. No lock/unlock boilerplate needed. The `getSpaceReadOnly` pattern from Go (which uses `RLock`) simply becomes a regular actor method — there's no performance difference in Swift actors, but the semantic intent (read-only, no creation) is preserved.

### Debounced Persistence
Go saves synchronously after every single CLI command. The server handles many more state mutations per second (window events, focus changes). Debouncing prevents disk thrashing. The 500ms debounce interval means at most 2 writes/second. A `flush()` method allows clean shutdown.

### JSON Compatibility Strategy
The Codable model structs use explicit `CodingKeys` to match Go's exact JSON field names. The critical compatibility issue is `stackMode`: Go encodes `""` (empty string) for "no override", while Swift's optional `GridStackMode?` would encode `null`. The `GridCellStateData` uses a custom `encode`/`decode` that maps `nil <-> ""` and `GridStackMode.vertical <-> "vertical"` etc.

### Date Format
Go's `time.Time` marshals as RFC 3339 with timezone (e.g., `2026-03-07T03:27:15.235438-06:00`). Swift's `JSONEncoder` with `.iso8601` strategy produces a slightly different format. Use a custom `DateFormatter` with `yyyy-MM-dd'T'HH:mm:ss.SSSSSSXXXXX` to match Go's output exactly.

### Window ID Type
Go uses `uint32`. Swift equivalent is `UInt32`. The JSON encodes these as plain integers. No special handling needed — `Codable` handles `UInt32` natively.

### Space Config Integration
The `cycleLayout` and `previousLayout` methods take `availableLayouts: [String]` as a parameter. The caller (future GridCommandRouter or GridReconciler) resolves the available layouts from `GridConfig.getSpaceConfig(spaceID:)`. This keeps GridState independent of GridConfig — it just stores and cycles, the caller provides the layout list.

## PRE-GATE Status
- [x] Discovery complete
- [x] Pseudocode complete
- [x] Design reviewed (actor + models approach chosen via design-it-twice)
- [x] Ready for implementation
