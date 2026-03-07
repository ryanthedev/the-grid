# Pseudocode: Phase 5 - Focus Navigation

## Files to Create/Modify
- Create: `grid-server/Sources/GridServer/Grid/GridFocus.swift`

## Design: GridFocus

### Approaches Considered
1. **Static enum with free functions** -- like GridLayout, all static methods on an enum. Caller passes dependencies (gridState, gridConfig, stateManager, windowManipulator) to each call.
2. **Class with stored dependency references** -- like GridReconciler, holds weak references to dependencies, methods read from them.
3. **Standalone functions at module scope** -- no namespace, just top-level async functions.

### Comparison
| Criterion | A (static enum) | B (class) | C (free functions) |
|-----------|---|---|---|
| Interface simplicity | Good -- clear namespace | Moderate -- init + setup | Poor -- pollutes namespace |
| Information hiding | Good -- no state to hide | Good -- hides deps | Poor |
| Caller ease of use | Moderate -- must pass deps each call | Good -- deps stored once | Moderate |
| Consistency with codebase | Matches GridLayout | Matches GridReconciler | Matches nothing |

### Choice: B (class with stored references)
Rationale: Focus operations need 4 dependencies (gridState, gridConfig, stateManager, windowManipulator). Passing them every call is tedious and error-prone. A class stores them once at setup, like GridReconciler. The class has no mutable state of its own -- it reads from actors and calls WindowManipulator.

### Depth Check
- Interface methods: 3 public (`moveFocus`, `cycleFocus`, `focusCell`)
- Hidden details: display adjacency logic, visual position mapping, wrap-around, cell selection heuristics, AX focus mechanics
- Common case complexity: simple -- caller says "move focus left" and GridFocus handles everything

## Pseudocode

### Grid/GridFocus.swift

```
// Options for focus movement
struct MoveFocusOpts
    wrapAround: Bool    // wrap within current display
    extend: Bool        // cross to adjacent displays
    warpMouse: Bool     // move cursor to focused window center

// GridFocus class -- handles all focus navigation
class GridFocus

    // Dependencies (weak references, set via setup)
    private gridState: GridState (weak)
    private gridConfig: GridConfig (weak)
    private stateManager: StateManager (weak)
    private windowManipulator: WindowManipulator (weak)

    // Setup: store references (called once from main.swift)
    func setup(gridState, gridConfig, stateManager, windowManipulator)
        store all four references

    // ============================================================
    // PUBLIC API (3 methods)
    // ============================================================

    // moveFocus: move focus to adjacent cell in direction
    //   Returns the window ID that was focused, or throws on failure
    func moveFocus(direction: GridDirection, opts: MoveFocusOpts) async throws -> UInt32

        // Get current OS state from StateManager
        let wmState = await stateManager.getState()
        let spaceID = find active space ID from wmState.spaces

        // Get grid state for this space
        let spaceState = await gridState.getSpaceReadOnly(spaceID)
        guard spaceState has a currentLayoutId, else throw "no layout applied"

        // Calculate layout bounds for current display
        let layoutDef = await MainActor.run { gridConfig.getLayout(id: spaceState.currentLayoutId) }
        let baseSpacing = await MainActor.run { gridConfig.getBaseSpacing() }
        let displayBounds = find display visibleFrame for current space from wmState
        let columnRatios = await gridState.getColumnRatios(spaceID)
        let rowRatios = await gridState.getRowRatios(spaceID)
        let calculated = GridLayout.calculateLayoutWithRatios(layoutDef, displayBounds, baseSpacing, columnRatios, rowRatios)

        // Find current focused cell
        let currentCell = await gridState.getFocusedCell(spaceID)
            ?? findFirstCellWithWindows(spaceState)
        guard currentCell is not nil, else throw "no cells with windows"

        // Find adjacent cells on current display
        let adjacentMap = GridLayout.getAdjacentCells(currentCell, calculated.cellBounds)
        var candidates = adjacentMap[direction]

        if candidates is empty
            // Try cross-display if extend enabled
            if opts.extend
                try cross-display focus (see moveFocusCrossDisplay below)
                if successful, warp mouse if opts.warpMouse, return windowID

            if not opts.wrapAround
                throw "no cell in direction"

            // Wrap: find cells on opposite edge
            candidates = findWrapTarget(direction, currentCell, calculated.cellBounds)
            if candidates still empty, throw "no cell in direction (wrap)"

        // Pick closest candidate by center distance
        let targetCell = pickClosestCell(currentCell, candidates, calculated.cellBounds)

        // Focus the target cell (updates GridState, triggers AX focus)
        let windowID = try await focusCellByID(spaceID, targetCell)

        // Warp mouse to focused window center if requested
        if opts.warpMouse
            warpMouseToCell(targetCell, calculated.cellBounds)

        return windowID


    // cycleFocus: cycle to next/prev window within focused cell
    //   Returns the window ID that was focused, or throws on failure
    func cycleFocus(forward: Bool) async throws -> UInt32

        // Get current space
        let wmState = await stateManager.getState()
        let spaceID = find active space ID from wmState.spaces
        let spaceState = await gridState.getSpaceReadOnly(spaceID)
        guard spaceState exists, else throw "no layout applied"

        // Find focused cell
        let cellID = spaceState.focusedCell
        if cellID is empty
            cellID = findFirstCellWithWindows(spaceState)
            guard cellID not empty, else throw "no cells with windows"

        let cellWindows = await gridState.getCellWindows(spaceID, cellID)
        guard cellWindows not empty, else throw "no windows in cell"

        if cellWindows.count == 1
            // Only one window, just ensure it's focused
            let windowID = cellWindows[0]
            try await focusWindowByID(windowID)
            await gridState.setFocus(spaceID, cellID, windowIndex: 0)
            return windowID

        // Calculate next/prev index (wrapping)
        let currentIdx = spaceState.focusedWindow
        let clampedIdx = clamp currentIdx to valid range
        let newIdx = if forward: (clampedIdx + 1) % count
                     else: (clampedIdx - 1 + count) % count

        let windowID = cellWindows[newIdx]
        try await focusWindowByID(windowID)
        await gridState.setFocus(spaceID, cellID, windowIndex: newIdx)

        return windowID


    // focusCell: focus a specific cell by ID
    //   Returns the window ID that was focused, or throws on failure
    func focusCell(spaceID: String, cellID: String) async throws -> UInt32
        return try await focusCellByID(spaceID, cellID)


    // ============================================================
    // PRIVATE: Core focus mechanics
    // ============================================================

    // focusCellByID: focus a cell, restoring last-focused window
    private func focusCellByID(spaceID: String, cellID: String) async throws -> UInt32

        let cellWindows = await gridState.getCellWindows(spaceID, cellID)
        guard cellWindows not empty, else throw "no windows in cell"

        // Determine which window to focus
        // Priority: lastFocusedWid > lastFocusedIdx > first window
        let spaceState = await gridState.getSpaceReadOnly(spaceID)
        let cellState = spaceState?.cells[cellID]

        var idx = 0
        if let cellState
            // Try lastFocusedWid first (stable across reorders)
            if cellState.lastFocusedWid != 0
                if let foundIdx = cellWindows.firstIndex(of: cellState.lastFocusedWid)
                    idx = foundIdx
            // Fall back to lastFocusedIdx
            else
                idx = clamp cellState.lastFocusedIdx to valid range

        let windowID = cellWindows[idx]

        // Do the AX focus
        try await focusWindowByID(windowID)

        // Update GridState focus tracking
        await gridState.setFocus(spaceID, cellID, windowIndex: idx)

        return windowID


    // focusWindowByID: focus a window via WindowManipulator
    private func focusWindowByID(_ windowID: UInt32) async throws

        // Look up window PID from StateManager
        let wmState = await stateManager.getState()
        guard let windowState = wmState.windows[String(windowID)]
            else throw "window not found"

        // Call WindowManipulator directly (no RPC)
        let success = windowManipulator.focusWindow(pid: windowState.pid, windowID: windowID)
        if not success
            throw "focus failed for window \(windowID)"


    // ============================================================
    // PRIVATE: Cross-display focus
    // ============================================================

    // moveFocusCrossDisplay: handle focus movement to adjacent display
    private func moveFocusCrossDisplay(
        direction, wmState, spaceID, currentCell, currentCellBounds
    ) async throws -> UInt32

        // Find current display UUID
        let currentDisplayUUID = findCurrentDisplayUUID(wmState, spaceID)
        guard currentDisplayUUID not empty, else throw "cannot determine display"

        // Find adjacent display in direction
        var adjacentDisplay = findAdjacentDisplay(currentDisplayUUID, direction, wmState.displays)
        if adjacentDisplay is nil
            // Try opposite display for wrap-around
            adjacentDisplay = findOppositeDisplay(currentDisplayUUID, direction, wmState.displays)
        guard let adjacentDisplay, else throw "no display in direction"

        // Get cells on target display
        let (targetCellBounds, targetSpaceID) = try await getDisplayCells(adjacentDisplay)
        let targetSpaceIDStr = String(targetSpaceID)
        let targetSpaceState = await gridState.getSpaceReadOnly(targetSpaceIDStr)

        // Get display bounds for position mapping
        let currentDisplayBounds = getDisplayBounds(currentDisplayUUID, wmState.displays)
        let targetDisplayBounds = getDisplayBounds(adjacentDisplay.uuid, wmState.displays)
        let currentBounds = currentCellBounds[currentCell] ?? .zero

        // Select target cell: prefer last-focused, fallback to closest by visual position
        let targetCell = selectCrossDisplayTargetCell(
            targetSpaceState, targetCellBounds,
            currentBounds, currentDisplayBounds, targetDisplayBounds
        )
        guard targetCell not empty, else throw "no cells on adjacent display"

        // Focus the cell on the target space
        let windowID = try await focusCellByID(targetSpaceIDStr, targetCell)

        // NOTE: Border sync handled automatically by GridReconciler's focusChanged handler
        // (it detects cross-display focus changes and syncs borders for new display)

        return windowID


    // ============================================================
    // PRIVATE: Display adjacency
    // ============================================================

    // findAdjacentDisplay: find display adjacent in direction
    //   Uses ~5px edge tolerance, vertical/horizontal overlap check
    //   Returns closest display by edge distance, with UUID tiebreaker
    private func findAdjacentDisplay(
        currentDisplayUUID: String,
        direction: GridDirection,
        displays: [DisplayState]
    ) -> DisplayState?

        let edgeTolerance = 5.0

        // Find current display
        guard let currentDisplay = displays.first(where: { $0.uuid == currentDisplayUUID })
            else return nil
        let currentFrame = currentDisplay.visibleFrame ?? currentDisplay.frame ?? return nil

        // Collect candidate displays with their edge distances
        var candidates: [(display: DisplayState, edgeDist: Double)] = []

        for each display (skip current)
            let candidateFrame = display.visibleFrame ?? display.frame ?? continue

            switch direction
            case .left:
                edgeDist = currentFrame.minX - candidateFrame.maxX
                if overlaps vertically AND candidate is to the left (with tolerance)
                    add to candidates
            case .right:
                edgeDist = candidateFrame.minX - currentFrame.maxX
                if overlaps vertically AND candidate is to the right (with tolerance)
                    add to candidates
            case .up:
                edgeDist = currentFrame.minY - candidateFrame.maxY
                if overlaps horizontally AND candidate is above (with tolerance)
                    add to candidates
            case .down:
                edgeDist = candidateFrame.minY - currentFrame.maxY
                if overlaps horizontally AND candidate is below (with tolerance)
                    add to candidates

        if candidates is empty, return nil

        // Sort by absolute edge distance (closest first), UUID tiebreaker
        sort candidates by abs(edgeDist), then by UUID
        return candidates[0].display


    // findOppositeDisplay: find display on opposite edge for wrap-around
    //   For left: find rightmost display that overlaps vertically
    //   For right: find leftmost, etc.
    private func findOppositeDisplay(
        currentDisplayUUID: String,
        direction: GridDirection,
        displays: [DisplayState]
    ) -> DisplayState?

        guard displays.count >= 2 else return nil
        guard let currentDisplay, let currentFrame else return nil

        var candidate: DisplayState? = nil
        var candidateValue: Double = 0

        for each display (skip current)
            let frame = display.visibleFrame ?? display.frame ?? continue

            switch direction
            case .left:
                // Wrap left -> find rightmost display overlapping vertically
                if overlaps vertically
                    rightEdge = frame.maxX
                    if candidate is nil OR rightEdge > candidateValue
                        candidate = display, candidateValue = rightEdge
            case .right:
                // Wrap right -> find leftmost display overlapping vertically
                if overlaps vertically
                    if candidate is nil OR frame.minX < candidateValue
                        candidate = display, candidateValue = frame.minX
            case .up:
                // Wrap up -> find bottommost display overlapping horizontally
                if overlaps horizontally
                    bottomEdge = frame.maxY
                    if candidate is nil OR bottomEdge > candidateValue
                        candidate = display, candidateValue = bottomEdge
            case .down:
                // Wrap down -> find topmost display overlapping horizontally
                if overlaps horizontally
                    if candidate is nil OR frame.minY < candidateValue
                        candidate = display, candidateValue = frame.minY

        return candidate


    // ============================================================
    // PRIVATE: Cell selection helpers
    // ============================================================

    // findWrapTarget: find cells on opposite edge for wrap within display
    //   For left direction: find rightmost cells that overlap vertically
    //   Returns cells at the extreme edge position
    private func findWrapTarget(
        direction: GridDirection,
        currentCell: String,
        cellBounds: [String: CGRect]
    ) -> [String]

        guard let current = cellBounds[currentCell] else return []

        // Collect all cells that overlap in perpendicular axis (excluding current)
        var candidates: [String] = []
        for (cellID, bounds) in cellBounds where cellID != currentCell
            switch direction
            case .left, .right:
                if current.overlapsVertically(with: bounds)
                    candidates.append(cellID)
            case .up, .down:
                if current.overlapsHorizontally(with: bounds)
                    candidates.append(cellID)

        if candidates is empty, return []

        // Filter to only cells at the extreme opposite edge
        // For wrap-left: keep only the rightmost cells
        // For wrap-right: keep only the leftmost cells
        // etc.
        switch direction
        case .left:
            filter to cells with maximum (bounds.maxX)
        case .right:
            filter to cells with minimum (bounds.minX)
        case .up:
            filter to cells with maximum (bounds.maxY)
        case .down:
            filter to cells with minimum (bounds.minY)

        return filtered candidates


    // pickClosestCell: pick cell closest to current cell's center
    //   Uses cell ID as deterministic tiebreaker
    private func pickClosestCell(
        currentCell: String,
        candidates: [String],
        cellBounds: [String: CGRect]
    ) -> String

        if candidates.count <= 1, return candidates.first ?? ""

        guard let currentBounds = cellBounds[currentCell] else return candidates[0]
        let currentCenter = currentBounds.center

        var closest = candidates[0]
        var closestDist = Double.greatestFiniteMagnitude

        for cellID in candidates
            let center = cellBounds[cellID]!.center
            let dist = sqrt((center.x - currentCenter.x)^2 + (center.y - currentCenter.y)^2)
            if dist < closestDist OR (dist == closestDist AND cellID < closest)
                closestDist = dist
                closest = cellID

        return closest


    // matchVisualPosition: map position from source to target display
    //   Uses normalized coordinates (0..1) to preserve visual position
    private func matchVisualPosition(
        sourceCell: CGRect,
        sourceDisplay: CGRect,
        targetDisplay: CGRect
    ) -> CGPoint

        let cellCenter = sourceCell.center
        let normX = (cellCenter.x - sourceDisplay.minX) / sourceDisplay.width
        let normY = (cellCenter.y - sourceDisplay.minY) / sourceDisplay.height
        let targetX = targetDisplay.minX + normX * targetDisplay.width
        let targetY = targetDisplay.minY + normY * targetDisplay.height
        return CGPoint(x: targetX, y: targetY)


    // findClosestCellToPoint: find cell whose center is closest to point
    //   Cell ID tiebreaker for deterministic ordering
    private func findClosestCellToPoint(
        point: CGPoint,
        cellBounds: [String: CGRect]
    ) -> String

        if cellBounds is empty, return ""

        var closestCell = ""
        var closestDist = Double.greatestFiniteMagnitude

        for (cellID, bounds) in cellBounds
            let center = bounds.center
            let dist = sqrt((center.x - point.x)^2 + (center.y - point.y)^2)
            if dist < closestDist OR (dist == closestDist AND cellID < closestCell)
                closestDist = dist
                closestCell = cellID

        return closestCell


    // selectCrossDisplayTargetCell: choose cell when crossing displays
    //   Priority: last focused cell on target space > closest with windows by visual position
    private func selectCrossDisplayTargetCell(
        targetSpaceState: GridSpaceStateData?,
        targetCellBounds: [String: CGRect],
        currentCellBounds: CGRect,
        currentDisplayBounds: CGRect,
        targetDisplayBounds: CGRect
    ) -> String

        // Check if target space has a previously focused cell with windows
        if let targetSpace = targetSpaceState,
           let focusedCell = targetSpace.focusedCell (not empty),
           targetCellBounds contains focusedCell,
           targetSpace.cells[focusedCell] has windows
            return focusedCell

        // Fall back to closest cell WITH WINDOWS based on visual position mapping
        let targetPoint = matchVisualPosition(currentCellBounds, currentDisplayBounds, targetDisplayBounds)

        // Filter to only cells with windows on target space
        var cellsWithWindows: [String: CGRect] = [:]
        if let targetSpace = targetSpaceState
            for (cellID, bounds) in targetCellBounds
                if targetSpace.cells[cellID] has windows
                    cellsWithWindows[cellID] = bounds

        if cellsWithWindows not empty
            return findClosestCellToPoint(targetPoint, cellsWithWindows)

        // No cells with windows
        return ""


    // ============================================================
    // PRIVATE: Display/space helpers
    // ============================================================

    // getDisplayCells: calculate cell bounds for a display's active space
    //   Mirrors Go's GetDisplayCells
    private func getDisplayCells(
        _ display: DisplayState
    ) async throws -> (cellBounds: [String: CGRect], spaceID: UInt64)

        let spaceID = display.currentSpaceID
        let spaceIDStr = String(spaceID)

        let layoutID = await gridState.getCurrentLayout(spaceID: spaceIDStr)
        guard layoutID not empty, else throw "no layout on space"

        let layoutDef = try await MainActor.run { try gridConfig.getLayout(id: layoutID) }
        let baseSpacing = await MainActor.run { gridConfig.getBaseSpacing() }

        let displayBounds = display.visibleFrame ?? display.frame
            ?? throw "no display bounds"

        let columnRatios = await gridState.getColumnRatios(spaceID: spaceIDStr)
        let rowRatios = await gridState.getRowRatios(spaceID: spaceIDStr)

        let calculated = GridLayout.calculateLayoutWithRatios(
            layoutDef, displayBounds, baseSpacing, columnRatios, rowRatios
        )

        return (calculated.cellBounds, spaceID)


    // findCurrentDisplayUUID: determine current display from space state
    private func findCurrentDisplayUUID(
        _ wmState: WindowManagerState,
        _ spaceID: String
    ) -> String

        // Match space ID to display via active space
        for display in wmState.displays
            if String(display.currentSpaceID) == spaceID
                return display.uuid
        return ""


    // getDisplayBounds: get visible frame for a display UUID
    private func getDisplayBounds(
        _ displayUUID: String,
        _ displays: [DisplayState]
    ) -> CGRect

        for display in displays
            if display.uuid == displayUUID
                return display.visibleFrame ?? display.frame ?? .zero
        return .zero


    // findFirstCellWithWindows: deterministic first cell with windows
    //   Sorts cell IDs alphabetically for consistency
    private func findFirstCellWithWindows(
        _ spaceState: GridSpaceStateData
    ) -> String?

        let sortedCellIDs = spaceState.cells.keys.sorted()
        for cellID in sortedCellIDs
            if let cell = spaceState.cells[cellID], !cell.windows.isEmpty
                return cellID
        return nil


    // findActiveSpaceID: find the active space from WindowManagerState
    private func findActiveSpaceID(
        _ wmState: WindowManagerState
    ) -> String?

        for (spaceKey, space) in wmState.spaces
            if space.isActive
                return spaceKey
        return nil


    // warpMouseToCell: move cursor to center of cell bounds
    private func warpMouseToCell(
        _ cellID: String,
        _ cellBounds: [String: CGRect]
    )
        guard let bounds = cellBounds[cellID] else return
        let center = bounds.center
        CGWarpMouseCursorPosition(center)
```

## Design Notes

1. **Border sync is implicit.** Go's focus.go explicitly calls `reconcile.SyncBordersForDisplay()` and `reconcile.SyncBorderFocus()` after cross-display moves. In Swift, the `GridReconciler.handleFocusChanged()` already detects cross-display focus changes (via `previousDisplayUUID != displayUUID`) and syncs borders automatically. GridFocus does NOT need to call border sync.

2. **No RPC layer.** Go's `FocusWindow()` calls `c.CallMethod("window.focus")` with RPC fallback. In Swift, we call `WindowManipulator.focusWindow(pid:windowID:)` directly. This requires looking up the window's PID from StateManager.

3. **Actor boundaries.** `GridState` is an actor (requires `await`). `GridConfig` is `@MainActor` (requires `await MainActor.run { ... }`). `WindowManipulator.focusWindow()` is synchronous (AX calls). `StateManager.getState()` is async.

4. **Mouse warp.** `CGWarpMouseCursorPosition` is a simple CoreGraphics call. No event association needed for our use case (we're not synthesizing clicks).

5. **Error handling.** Methods throw descriptive errors. Callers (BFD command router in Phase 8) will catch and log errors, fire-and-forget style.

6. **Deterministic ordering.** Cell ID is used as tiebreaker throughout (matching Go behavior) for consistent focus navigation.

7. **filterByEdge simplification.** Go's `filterByEdge()` with a comparator function is verbose. In Swift, we inline the logic per direction in `findWrapTarget()` using a simpler "find max/min value, then collect all cells at that value" pattern.

## PRE-GATE Status
- [x] Discovery complete
- [x] Pseudocode complete
- [x] Design reviewed (class with stored dependencies, 3 public methods, deep module)
- [x] Ready for implementation
