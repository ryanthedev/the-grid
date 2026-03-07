# Pseudocode: Phase 7 - Resize

## Files to Create/Modify
- **Create:** `grid-server/Sources/GridServer/Grid/GridResize.swift`
- **Modify:** `grid-server/Sources/GridServer/Grid/GridState.swift` (add clearTrackRatios)
- **Modify:** `grid-server/Sources/GridServer/Grid/GridLayout.swift` (add track ratio helpers)

## Design

### Approach A: Standalone GridResize class (mirror Go pattern)
A `GridResize` class with weak dependencies, 4 public methods that each get state, mutate ratios, call reapply. Same pattern as GridCellOps/GridWindowMove.

### Approach B: Methods on GridApply
Add resize methods directly to GridApply since every resize ends with reapplyLayout anyway. Fewer classes, but GridApply is already the largest module.

### Approach C: Thin GridResize class delegating to GridApply
GridResize holds weak refs, does ratio computation + state mutation, then calls gridApply.reapplyLayout. Keeps apply logic in one place, resize logic separate.

### Choice: A (Standalone GridResize class)
Rationale: Consistent with GridCellOps, GridWindowMove, GridFocus pattern. GridApply stays focused on layout application. GridResize owns the "compute new ratios, update state, trigger reapply" sequence. Sacrifice: one more class, but the pattern is established and keeps modules focused.

### Depth Check
- Interface methods: 4 public (`adjustFocusedSplit`, `resetSplits`, `adjustCellBoundary`, `resetCellRatios`)
- Hidden details: boundary index computation, flex track counting, ratio clamping, reapply orchestration
- Common case complexity: simple (caller says "grow right 0.1" or "reset")

## Pseudocode

### GridLayout.swift (additions) -- 3 static helper methods

```
// Count how many tracks are flexible (fr or minmax type)
static func countFlexibleTracks(tracks) -> Int
    count = 0
    for each track in tracks
        if track type is fr or minmax, increment count
    return count

// Create initial ratios from track fr values (proportional to their fr weights)
static func initializeTrackRatios(tracks) -> [Double]
    count flexible tracks
    if none, return empty array

    sum total fr values across flexible tracks
        (fr tracks use their value, minmax tracks use their max)

    if total is zero, return equal ratios for flex count

    build ratios array: for each flexible track, ratio = its fr value / total
    normalize and return

// Map an overall track index to its position in the flex-only ratios array
// Returns -1 if the track at that index is not flexible
static func getFlexBoundaryIndex(tracks, trackIndex) -> Int
    flexIndex = 0
    for each track at position i
        if i equals trackIndex
            if track is flexible, return flexIndex
            else return -1
        if track is flexible, increment flexIndex
    return -1
```

### GridState.swift (addition) -- 1 method

```
// Clear column and row ratios to nil (layout defaults)
func clearTrackRatios(spaceID)
    get mutable space for spaceID
    set space.columnRatios = nil
    set space.rowRatios = nil
    save space back to spaces dictionary
    mark dirty
```

### GridResize.swift -- new file

```
// GridResize: handles resize operations for splits (within cells) and
// cell boundaries (column/row track ratios)

class GridResize

    // Weak dependencies set via setup (same pattern as GridCellOps)
    weak gridState: GridState
    weak gridConfig: GridConfig
    weak gridApply: GridApply
    weak gridFocus: GridFocus
    weak stateManager: StateManager

    func setup(gridState, gridConfig, gridApply, gridFocus, stateManager)
        store all weak references
        log "resize.init"

    // ============================================================
    // adjustFocusedSplit: grow/shrink split ratio between stacked
    // windows in the focused cell
    // ============================================================

    func adjustFocusedSplit(spaceID, delta) async throws
        guard dependencies exist, else throw noLayout

        // Get space state, verify layout exists
        get spaceState read-only for spaceID
        if nil, throw "no layout applied"

        // Get focused cell
        get focusedCell from spaceState
        if empty, throw "no focused cell"

        // Get cell state, verify at least 2 windows
        get cell data from spaceState.cells[focusedCell]
        if cell is nil or has fewer than 2 windows
            throw "need at least 2 windows to resize"

        // Determine boundary to adjust based on focused window index
        get focused window index from spaceState
        clamp index to valid range [0, windowCount-1]

        // Get current split ratios (or initialize equal if wrong length)
        get ratios from cell.splitRatios
        if ratios count does not match window count
            ratios = equal ratios for window count

        // Boundary is between focusedIndex and focusedIndex+1
        // If at last window, use boundary before it instead
        boundaryIndex = focusedIndex
        if boundaryIndex >= ratios.count - 1
            boundaryIndex = ratios.count - 2

        // Adjust the split ratio at this boundary
        call GridLayout.adjustSplitRatio(ratios, boundaryIndex, delta, minimumRatio)
        if failure, throw the error

        // Update state with new ratios
        await gridState.setCellSplitRatios(spaceID, cellID, newRatios)

        // Reapply layout to reposition windows
        try await gridApply.reapplyLayout(spaceID, strategy: .preserve)

        log "resize.split.done"

    // ============================================================
    // resetSplits: reset split ratios to equal for focused cell
    // or all cells
    // ============================================================

    func resetSplits(spaceID, allCells: Bool) async throws
        guard dependencies exist, else throw noLayout

        get spaceState read-only for spaceID
        if nil, throw "no layout applied"

        if allCells
            // Reset every cell's splits to equal
            for each (cellID, cell) in spaceState.cells
                equalRatios = GridLayout.equalRatios(cell.windows.count)
                await gridState.setCellSplitRatios(spaceID, cellID, equalRatios)
        else
            // Reset only focused cell
            get focusedCell from spaceState
            if empty, throw "no focused cell"

            get cell from spaceState.cells[focusedCell]
            if nil, throw "no focused cell"

            equalRatios = GridLayout.equalRatios(cell.windows.count)
            await gridState.setCellSplitRatios(spaceID, focusedCell, equalRatios)

        // Reapply layout
        try await gridApply.reapplyLayout(spaceID, strategy: .preserve)

        log "resize.splits_reset.done"

    // ============================================================
    // adjustCellBoundary: grow/shrink the focused cell's edge in
    // a direction by adjusting column or row track ratios
    // ============================================================

    func adjustCellBoundary(spaceID, direction, delta) async throws
        guard dependencies exist, else throw noLayout

        get spaceState read-only for spaceID
        if nil, throw "no layout applied"

        get focusedCell from spaceState
        if empty, throw "no focused cell"

        // Look up layout definition to get tracks and cell grid positions
        get layoutDef from gridConfig using spaceState.currentLayoutId
        if not found, throw error

        // Find the focused cell's definition in the layout
        find cellDef in layoutDef.cells where id == focusedCell
        if not found, throw "cell not found in layout"

        // Determine axis: left/right = columns, up/down = rows
        isColumn = direction is left or right
        isGrowing = direction is right or down

        // Select the relevant tracks and current ratios
        if isColumn
            tracks = layoutDef.columns
            currentRatios = await gridState.getColumnRatios(spaceID)
            trackStart = cellDef.columnStart - 1  (convert to 0-indexed)
            trackEnd = cellDef.columnEnd - 2       (end line is after last column)
        else
            tracks = layoutDef.rows
            currentRatios = await gridState.getRowRatios(spaceID)
            trackStart = cellDef.rowStart - 1
            trackEnd = cellDef.rowEnd - 2

        // Need at least 2 flexible tracks to resize between
        flexCount = GridLayout.countFlexibleTracks(tracks)
        if flexCount < 2, throw "need at least 2 flexible tracks"

        // Initialize ratios from track definitions if not set or wrong length
        if currentRatios is nil or count != flexCount
            currentRatios = GridLayout.initializeTrackRatios(tracks)

        // Find which boundary to adjust
        // Growing right/down: boundary after the cell
        // Growing left/up: boundary before the cell
        if isGrowing
            boundaryIndex = GridLayout.getFlexBoundaryIndex(tracks, trackEnd)
        else
            boundaryIndex = GridLayout.getFlexBoundaryIndex(tracks, trackStart) - 1

        if boundaryIndex < 0 or >= flexCount - 1
            throw "cannot resize in direction: at edge of layout"

        // Compute adjusted delta
        // For left/up: negate delta (adjusting from the other side)
        adjustDelta = delta
        if not isGrowing
            adjustDelta = -delta

        // Get min/max ratio from config
        minRatio = gridConfig.settings.resize.minRatio
        maxRatio = gridConfig.settings.resize.maxRatio

        // Adjust the track ratios at this boundary
        call GridLayout.adjustSplitRatioWithMax(currentRatios, boundaryIndex, adjustDelta, minRatio, maxRatio)
        if failure, throw the error

        // Update state with new track ratios
        if isColumn
            await gridState.setColumnRatios(spaceID, newRatios)
        else
            await gridState.setRowRatios(spaceID, newRatios)

        // Reapply layout
        try await gridApply.reapplyLayout(spaceID, strategy: .preserve)

        log "resize.cell.done"

    // ============================================================
    // resetCellRatios: reset column and row ratios to layout defaults
    // ============================================================

    func resetCellRatios(spaceID) async throws
        guard dependencies exist, else throw noLayout

        get spaceState read-only for spaceID
        if nil, throw "no layout applied"

        // Clear track ratios (sets to nil so layout uses default fr distribution)
        await gridState.clearTrackRatios(spaceID)

        // Reapply layout
        try await gridApply.reapplyLayout(spaceID, strategy: .preserve)

        log "resize.ratios_reset.done"
```

## Design Notes

1. **GridResize follows the established class-with-weak-deps pattern** used by GridCellOps, GridWindowMove, and GridFocus. Dependencies injected via `setup()`.

2. **Split ratios vs track ratios are distinct concepts:**
   - Split ratios: within a cell, between stacked windows (stored per-cell in GridState)
   - Track ratios: between columns or rows of the grid (stored per-space in GridState)
   - `adjustFocusedSplit` and `resetSplits` operate on split ratios
   - `adjustCellBoundary` and `resetCellRatios` operate on track ratios

3. **The three track helpers belong on GridLayout** (`countFlexibleTracks`, `initializeTrackRatios`, `getFlexBoundaryIndex`) because they are pure functions operating on `[GridTrackSize]` -- same home as the other track calculation functions.

4. **GridState.clearTrackRatios** sets both `columnRatios` and `rowRatios` to nil (not empty array). This is semantically different from `setColumnRatios([])` which would normalize to empty. Nil means "use layout defaults."

5. **Go's ResetAllSplits and ResetFocusedSplits are merged into `resetSplits(spaceID:allCells:)`** -- the logic is identical except for scope. A boolean parameter eliminates duplication.

6. **Config access pattern:** `gridConfig.settings.resize.minRatio`/`maxRatio` are accessed via `@MainActor` since GridConfig is MainActor-isolated.

## PRE-GATE Status
- [x] Discovery complete
- [x] Pseudocode complete
- [x] Design reviewed (approach comparison done)
- [x] Ready for implementation
