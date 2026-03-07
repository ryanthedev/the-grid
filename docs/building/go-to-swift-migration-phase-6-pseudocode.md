# Pseudocode: Phase 6 - Cell Operations + Window Move + Layout Apply

## Files to Create/Modify
- **Create:** `Grid/GridCellOps.swift`
- **Create:** `Grid/GridWindowMove.swift`
- **Create:** `Grid/GridApply.swift`
- **Modify:** `Grid/GridFocus.swift` -- change some `private` helpers to `internal`
- **Modify:** `Grid/GridReconciler.swift` -- make `syncBordersForSpace` internal

## Prerequisite Modifications

### GridFocus.swift -- Expose shared helpers

Change these methods from `private` to `internal` (package-level):

```
findActiveSpaceID(_ wmState:) -> String?
getDisplayBoundsForSpace(_ spaceID:, wmState:) -> CGRect
findCurrentDisplayUUID(_ wmState:, _ spaceID:) -> String
findAdjacentDisplay(currentDisplayUUID:, direction:, displays:) -> DisplayState?
findOppositeDisplay(currentDisplayUUID:, direction:, displays:) -> DisplayState?
matchVisualPosition(sourceCell:, sourceDisplay:, targetDisplay:) -> CGPoint
findClosestCellToPoint(point:, cellBounds:) -> String?
getDisplayCells(_ display:) -> (cellBounds:, spaceID:)
pickClosestCell(currentCell:, candidates:, cellBounds:) -> String
findWrapTarget(direction:, currentCell:, cellBounds:) -> [String]
focusWindowByID(_ windowID:)
```

These are stateless computations or simple StateManager lookups. Making them internal lets GridWindowMove and GridApply reuse them without duplication.

### GridReconciler.swift -- Expose border sync

Change `syncBordersForSpace` from `private` to `internal`:

```
func syncBordersForSpace(_ spaceID: String, displayUUID: String) async
```

This lets GridApply trigger a border sync after layout application without duplicating the logic.

---

## Pseudocode

### Grid/GridCellOps.swift

```
// Errors for cell operations
enum GridCellOpsError:
    noLayout
    noFocusedWindow
    noFocusedCell
    noCellInDirection(String)
    needAtLeastTwoWindows
    invalidMode(String)

class GridCellOps:

    // Dependencies (weak, set via setup)
    weak gridState: GridState
    weak gridConfig: GridConfig
    weak stateManager: StateManager
    weak gridApply: GridApply     // forward reference -- set after GridApply is created
    weak gridFocus: GridFocus

    func setup(gridState, gridConfig, stateManager, gridFocus):
        store weak references
        log "cellops.init"

    // Set gridApply after it's created (circular dependency resolution)
    func setApply(_ apply: GridApply):
        self.gridApply = apply

    // ============================================================
    // sendWindow: move focused window to adjacent cell
    // ============================================================
    func sendWindow(direction: GridDirection) async throws:
        // 1. Get current space state
        let wmState = await stateManager.getState()
        guard spaceID = gridFocus.findActiveSpaceID(wmState)
        guard spaceState = await gridState.getSpaceReadOnly(spaceID)
        guard spaceState.currentLayoutId is not empty -> throw noLayout

        // 2. Get focused window and cell
        let windowID = await gridState.getFocusedWindow(spaceID: spaceID)
        guard windowID != 0 -> throw noFocusedWindow

        let currentCell = await gridState.getFocusedCell(spaceID: spaceID)
        guard currentCell is not nil -> throw noFocusedCell

        // 3. Calculate layout and find adjacent cells
        let layoutDef = try await MainActor.run { gridConfig.getLayout(id: spaceState.currentLayoutId) }
        let displayBounds = gridFocus.getDisplayBoundsForSpace(spaceID, wmState: wmState)
        let columnRatios = await gridState.getColumnRatios(spaceID: spaceID)
        let rowRatios = await gridState.getRowRatios(spaceID: spaceID)
        let calculated = GridLayout.calculateLayoutWithRatios(layout: layoutDef, screenRect: displayBounds, gap: 0, columnRatios: columnRatios, rowRatios: rowRatios)

        // 4. Find target cell via adjacency
        let adjacentMap = GridLayout.getAdjacentCells(cellID: currentCell, cellBounds: calculated.cellBounds)
        let candidates = adjacentMap[direction] ?? []
        guard candidates is not empty -> throw noCellInDirection

        let targetCell = gridFocus.pickClosestCell(currentCell: currentCell, candidates: candidates, cellBounds: calculated.cellBounds)

        // 5. Move window in state: remove from old cell, assign to new
        await gridState.removeWindow(windowID, fromSpace: spaceID)
        await gridState.assignWindow(windowID, toCellID: targetCell, inSpace: spaceID)

        // 6. Update focus to follow window
        let targetCellWindows = await gridState.getCellWindows(spaceID: spaceID, cellID: targetCell)
        let newIndex = targetCellWindows.count - 1
        await gridState.setFocus(spaceID: spaceID, cellID: targetCell, windowIndex: max(0, newIndex))

        // 7. Reapply layout with preserve strategy
        try await gridApply.reapplyLayout(spaceID: spaceID, strategy: .preserve)

    // ============================================================
    // swapWindow: swap focused window with adjacent window in same cell
    // ============================================================
    func swapWindow(direction: GridDirection) async throws:
        // 1. Get current space state
        let wmState = await stateManager.getState()
        guard spaceID = gridFocus.findActiveSpaceID(wmState)
        guard spaceState = await gridState.getSpaceReadOnly(spaceID)
        guard spaceState.currentLayoutId not empty -> throw noLayout

        // 2. Get focused cell with at least 2 windows
        let cellID = await gridState.getFocusedCell(spaceID: spaceID)
        guard cellID not nil -> throw noFocusedCell
        let cellWindows = await gridState.getCellWindows(spaceID: spaceID, cellID: cellID)
        guard cellWindows.count >= 2 -> throw needAtLeastTwoWindows

        // 3. Get current window index
        let currentIdx = max(0, min(spaceState.focusedWindow, cellWindows.count - 1))

        // 4. Get effective stack mode for swap direction mapping
        let stackMode = await getEffectiveStackMode(spaceID: spaceID, cellID: cellID, layoutID: spaceState.currentLayoutId)

        // 5. Calculate swap target index
        let targetIdx = calculateSwapTarget(currentIdx: currentIdx, windowCount: cellWindows.count, direction: direction, stackMode: stackMode)

        // 6. Build new window order with swap applied
        var newWindows = cellWindows
        newWindows.swapAt(currentIdx, targetIdx)

        // 7. Get current split ratios and swap them too
        var splitRatios = await gridState.getCellSplitRatios(spaceID: spaceID, cellID: cellID)
        if splitRatios.count == cellWindows.count:
            splitRatios.swapAt(currentIdx, targetIdx)
            await gridState.setCellSplitRatios(spaceID: spaceID, cellID: cellID, ratios: splitRatios)

        // 8. Update state: set new window order, focus follows moved window
        await gridState.setWindowAssignments(spaceID: spaceID, assignments: /* rebuild with swapped windows for this cell */)
        // NOTE: Actually we need a more targeted update. Use removeWindow + insertWindow pattern:
        //   But GridState doesn't have a "reorder within cell" method.
        //   Alternative: build full assignments map, swap just this cell's windows, call setWindowAssignments
        // Simplest: read all assignments, modify just this cell, write back
        var allAssignments = await gridState.getWindowAssignments(spaceID: spaceID)
        allAssignments[cellID] = newWindows
        await gridState.setWindowAssignments(spaceID: spaceID, assignments: allAssignments)

        // 9. Update focus to follow the window to its new position
        await gridState.setFocus(spaceID: spaceID, cellID: cellID, windowIndex: targetIdx)

        // 10. Reapply layout with preserve strategy
        try await gridApply.reapplyLayout(spaceID: spaceID, strategy: .preserve)

    // ============================================================
    // setMode: set or cycle stack mode for focused cell
    // ============================================================
    func setMode(targetMode: GridStackMode?) async throws -> (cellID: String, newMode: GridStackMode):
        // 1. Get current space state
        let wmState = await stateManager.getState()
        guard spaceID = gridFocus.findActiveSpaceID(wmState)
        guard spaceState = await gridState.getSpaceReadOnly(spaceID)
        guard spaceState.currentLayoutId not empty -> throw noLayout

        // 2. Get focused cell
        let cellID = await gridState.getFocusedCell(spaceID: spaceID)
        guard cellID not nil -> throw noFocusedCell

        // 3. Determine new mode
        let newMode: GridStackMode
        if let targetMode:
            newMode = targetMode
        else:
            // Cycle: vertical -> horizontal -> tabs -> vertical
            let currentMode = await getEffectiveStackMode(spaceID: spaceID, cellID: cellID, layoutID: spaceState.currentLayoutId)
            newMode = nextMode(currentMode)

        // 4. Update state
        await gridState.setCellStackMode(spaceID: spaceID, cellID: cellID, mode: newMode)

        // 5. Apply cell layout only (more efficient than full reapply)
        try await gridApply.applyCellLayout(spaceID: spaceID, cellID: cellID)

        return (cellID, newMode)

    // ============================================================
    // PRIVATE: Helper functions
    // ============================================================

    // nextMode: cycle through modes
    private func nextMode(_ current: GridStackMode) -> GridStackMode:
        switch current:
            case .vertical: return .horizontal
            case .horizontal: return .tabs
            case .tabs: return .vertical

    // getEffectiveStackMode: resolve stack mode priority chain
    // Priority: runtime override > cell config > layout cellModes > settings default
    private func getEffectiveStackMode(spaceID: String, cellID: String, layoutID: String) async -> GridStackMode:
        // 1. Check runtime override in GridState
        if let stateMode = await gridState.getCellStackMode(spaceID: spaceID, cellID: cellID):
            return stateMode

        // 2-3. Check layout config (cell-level StackMode and cellModes map)
        if let layoutDef = try? await MainActor.run({ try gridConfig.getLayout(id: layoutID) }):
            // Check per-cell StackMode
            for cell in layoutDef.cells:
                if cell.id == cellID && cell.stackMode != nil:
                    return cell.stackMode!
            // Check cellModes map
            if let cellModes = layoutDef.cellModes, let mode = cellModes[cellID]:
                return mode

        // 4. Fall back to settings default
        let defaultMode = await MainActor.run { gridConfig.settings.defaultStackMode }
        return defaultMode

    // calculateSwapTarget: direction + stack mode -> target index (with wrap)
    private func calculateSwapTarget(currentIdx: Int, windowCount: Int, direction: GridDirection, stackMode: GridStackMode) -> Int:
        let delta: Int
        switch stackMode:
            case .vertical:
                delta = (direction == .up || direction == .left) ? -1 : 1
            case .horizontal:
                delta = (direction == .left || direction == .up) ? -1 : 1
            case .tabs:
                delta = (direction == .left || direction == .up) ? -1 : 1
        return (currentIdx + delta + windowCount) % windowCount
```

### Grid/GridWindowMove.swift

```
// Move result type
struct GridMoveResult:
    windowID: UInt32
    sourceCell: String
    targetCell: String
    sourceSpace: String
    targetSpace: String
    crossDisplay: Bool

// Move options
struct GridMoveOpts:
    wrapAround: Bool = false
    extend: Bool = false      // allow cross-display
    windowID: UInt32 = 0      // 0 = use focused

// Errors
enum GridWindowMoveError:
    noLayout
    noFocusedWindow
    windowNotInCell(UInt32)
    noCellInDirection(String)
    cannotDetermineDisplay
    noDisplayInDirection
    noCellsOnAdjacentDisplay
    layoutNotFound(String)

class GridWindowMove:

    // Dependencies (weak, set via setup)
    weak gridState: GridState
    weak gridConfig: GridConfig
    weak stateManager: StateManager
    weak gridFocus: GridFocus
    weak gridApply: GridApply
    weak windowManipulator: WindowManipulator
    weak gridReconciler: GridReconciler

    func setup(gridState, gridConfig, stateManager, gridFocus, windowManipulator, gridReconciler):
        store weak references
        log "winmove.init"

    func setApply(_ apply: GridApply):
        self.gridApply = apply

    // ============================================================
    // moveWindow: move window to adjacent cell (same or cross display)
    // ============================================================
    func moveWindow(direction: GridDirection, opts: GridMoveOpts) async throws -> GridMoveResult:
        // 1. Get space state
        let wmState = await stateManager.getState()
        guard spaceID = gridFocus.findActiveSpaceID(wmState)
        guard spaceState = await gridState.getSpaceReadOnly(spaceID)
        guard spaceState.currentLayoutId not empty -> throw noLayout

        // 2. Determine which window to move
        let windowID = opts.windowID != 0 ? opts.windowID : await gridState.getFocusedWindow(spaceID: spaceID)
        guard windowID != 0 -> throw noFocusedWindow

        // 3. Find source cell
        let sourceCell = await gridState.getWindowCell(windowID: windowID, inSpace: spaceID)
        guard sourceCell not nil -> throw windowNotInCell(windowID)

        // 4. Calculate layout and find adjacent cells
        let layoutDef = try await MainActor.run { gridConfig.getLayout(id: spaceState.currentLayoutId) }
        let displayBounds = gridFocus.getDisplayBoundsForSpace(spaceID, wmState: wmState)
        let columnRatios = await gridState.getColumnRatios(spaceID: spaceID)
        let rowRatios = await gridState.getRowRatios(spaceID: spaceID)
        let calculated = GridLayout.calculateLayoutWithRatios(layout: layoutDef, screenRect: displayBounds, gap: 0, columnRatios: columnRatios, rowRatios: rowRatios)

        let adjacentMap = GridLayout.getAdjacentCells(cellID: sourceCell, cellBounds: calculated.cellBounds)
        var candidates = adjacentMap[direction] ?? []

        // 5. Handle no adjacent cells
        if candidates.isEmpty:
            // Try cross-display if extend enabled
            if opts.extend:
                let result = try await moveWindowCrossDisplay(
                    direction: direction, windowID: windowID,
                    sourceCell: sourceCell, currentCellBounds: calculated.cellBounds,
                    wmState: wmState, spaceID: spaceID
                )
                return result

            if !opts.wrapAround:
                throw noCellInDirection(direction)

            // Wrap: find opposite edge cells
            candidates = gridFocus.findWrapTarget(direction: direction, currentCell: sourceCell, cellBounds: calculated.cellBounds)
            guard candidates not empty -> throw noCellInDirection

        // 6. Pick closest candidate
        let targetCell = gridFocus.pickClosestCell(currentCell: sourceCell, candidates: candidates, cellBounds: calculated.cellBounds)

        // 7. Move window within same space
        return try await moveWindowToCell(
            windowID: windowID, sourceCell: sourceCell, targetCell: targetCell,
            spaceID: spaceID, layoutDef: layoutDef, displayBounds: displayBounds, wmState: wmState
        )

    // ============================================================
    // PRIVATE: moveWindowToCell (same space)
    // ============================================================
    private func moveWindowToCell(
        windowID, sourceCell, targetCell, spaceID,
        layoutDef, displayBounds, wmState
    ) async throws -> GridMoveResult:

        // 1. Update state: prepend window to target cell (removes from source)
        await gridState.prependWindow(windowID, toCellID: targetCell, inSpace: spaceID)

        // 2. Update focus to follow moved window
        await gridState.setFocus(spaceID: spaceID, cellID: targetCell, windowIndex: 0)

        // 3. Calculate placements for affected cells only
        let columnRatios = await gridState.getColumnRatios(spaceID: spaceID)
        let rowRatios = await gridState.getRowRatios(spaceID: spaceID)
        let calculated = GridLayout.calculateLayoutWithRatios(
            layout: layoutDef, screenRect: displayBounds, gap: 0,
            columnRatios: columnRatios, rowRatios: rowRatios
        )

        // 4. Build assignments for affected cells
        let affectedCells = [sourceCell, targetCell]
        var affectedAssignments: [String: [UInt32]] = [:]
        for cellID in affectedCells:
            affectedAssignments[cellID] = await gridState.getCellWindows(spaceID: spaceID, cellID: cellID)

        // 5. Build cell modes and ratios from config+state hierarchy
        let (cellModes, cellRatios) = await buildCellModesAndRatios(
            cellIDs: affectedCells, spaceID: spaceID, layoutDef: layoutDef
        )

        // 6. Calculate window placements
        let baseSpacing = await MainActor.run { gridConfig.getBaseSpacing() }
        let settingsPadding = await MainActor.run { gridConfig.getSettingsPadding() }
        let settingsWindowSpacing = await MainActor.run { gridConfig.getSettingsWindowSpacing() }
        let defaultMode = await MainActor.run { gridConfig.settings.defaultStackMode }

        var placements = GridLayout.calculateAllWindowPlacements(
            calculatedLayout: calculated,
            layout: layoutDef,
            assignments: affectedAssignments,
            cellModes: cellModes,
            cellRatios: cellRatios,
            defaultMode: defaultMode,
            baseSpacing: baseSpacing,
            settingsPadding: settingsPadding,
            settingsWindowSpacing: settingsWindowSpacing
        )

        // 7. Apply display offset
        let displayUUID = gridFocus.findCurrentDisplayUUID(wmState, spaceID)
        let displayName = findDisplayName(displayUUID, wmState: wmState)
        let offset = await MainActor.run { gridConfig.getDisplayOffset(uuid: displayUUID, name: displayName) }
        if offset.x != 0 || offset.y != 0:
            for i in 0..<placements.count:
                placements[i] = GridWindowPlacement(
                    windowID: placements[i].windowID,
                    bounds: placements[i].bounds.offsetBy(dx: offset.x, dy: offset.y)
                )

        // 8. Apply placements via WindowManipulator
        await applyPlacementsViaAX(placements)

        // 9. Handle tab mode: raise next window in source cell if tabbed
        await raiseNextWindowIfTabbed(sourceCell: sourceCell, spaceID: spaceID, cellModes: cellModes, defaultMode: defaultMode)

        // 10. Focus the moved window
        try await gridFocus.focusWindowByID(windowID)

        // 11. Sync borders for current space
        let displayUUIDForBorders = gridFocus.findCurrentDisplayUUID(wmState, spaceID)
        await gridReconciler.syncBordersForSpace(spaceID, displayUUID: displayUUIDForBorders)

        return GridMoveResult(
            windowID: windowID, sourceCell: sourceCell, targetCell: targetCell,
            sourceSpace: spaceID, targetSpace: spaceID, crossDisplay: false
        )

    // ============================================================
    // PRIVATE: moveWindowCrossDisplay
    // ============================================================
    private func moveWindowCrossDisplay(
        direction, windowID, sourceCell, currentCellBounds, wmState, spaceID
    ) async throws -> GridMoveResult:

        // 1. Find current display UUID
        let currentDisplayUUID = gridFocus.findCurrentDisplayUUID(wmState, spaceID)
        guard currentDisplayUUID not empty -> throw cannotDetermineDisplay

        // 2. Find adjacent display
        var adjacentDisplay = gridFocus.findAdjacentDisplay(
            currentDisplayUUID: currentDisplayUUID, direction: direction, displays: wmState.displays
        )
        if adjacentDisplay == nil:
            adjacentDisplay = gridFocus.findOppositeDisplay(
                currentDisplayUUID: currentDisplayUUID, direction: direction, displays: wmState.displays
            )
        guard adjacentDisplay not nil -> throw noDisplayInDirection

        // 3. Get cells on target display
        let (targetCellBounds, targetSpaceID) = try await gridFocus.getDisplayCells(adjacentDisplay)
        let targetSpaceIDStr = String(targetSpaceID)

        // 4. Map visual position to target display
        let currentDisplayBounds = findDisplayBounds(currentDisplayUUID, from: wmState)
        let currentBounds = currentCellBounds[sourceCell]!
        let targetDisplayBounds = adjacentDisplay.visibleFrame ?? adjacentDisplay.frame
        let targetPoint = gridFocus.matchVisualPosition(
            sourceCell: currentBounds, sourceDisplay: currentDisplayBounds, targetDisplay: targetDisplayBounds
        )

        // 5. Find closest cell on target display
        let targetCell = gridFocus.findClosestCellToPoint(point: targetPoint, cellBounds: targetCellBounds)
        guard targetCell not nil -> throw noCellsOnAdjacentDisplay

        // 6. Move window to target space via WindowManipulator
        let spaceIDInt = UInt64(targetSpaceID)
        windowManipulator.moveWindowToSpace(windowID: windowID, spaceID: spaceIDInt)

        // 7. Update state on both source and target spaces
        await gridState.removeWindow(windowID, fromSpace: spaceID)
        await gridState.prependWindow(windowID, toCellID: targetCell, inSpace: targetSpaceIDStr)
        await gridState.setFocus(spaceID: targetSpaceIDStr, cellID: targetCell, windowIndex: 0)

        // 8. Calculate and apply placements for target cell on target display
        await applyPartialLayout(
            spaceID: targetSpaceIDStr,
            cellIDs: [targetCell],
            displayBounds: targetDisplayBounds,
            displayUUID: adjacentDisplay.uuid,
            displayName: adjacentDisplay.name ?? ""
        )

        // 9. Also rebalance source cell on source display
        let sourceCellWindows = await gridState.getCellWindows(spaceID: spaceID, cellID: sourceCell)
        if !sourceCellWindows.isEmpty:
            await applyPartialLayout(
                spaceID: spaceID,
                cellIDs: [sourceCell],
                displayBounds: currentDisplayBounds,
                displayUUID: currentDisplayUUID,
                displayName: findDisplayName(currentDisplayUUID, wmState: wmState)
            )
            // Handle tab mode raise for source cell
            let defaultMode = await MainActor.run { gridConfig.settings.defaultStackMode }
            let (srcModes, _) = await buildCellModesAndRatios(
                cellIDs: [sourceCell], spaceID: spaceID,
                layoutDef: try! await MainActor.run { try gridConfig.getLayout(id: await gridState.getCurrentLayout(spaceID: spaceID)) }
            )
            await raiseNextWindowIfTabbed(sourceCell: sourceCell, spaceID: spaceID, cellModes: srcModes, defaultMode: defaultMode)

        // 10. Focus the moved window
        try await gridFocus.focusWindowByID(windowID)

        // 11. Sync borders on target display
        await gridReconciler.syncBordersForSpace(targetSpaceIDStr, displayUUID: adjacentDisplay.uuid)

        return GridMoveResult(
            windowID: windowID, sourceCell: sourceCell, targetCell: targetCell,
            sourceSpace: spaceID, targetSpace: targetSpaceIDStr, crossDisplay: true
        )

    // ============================================================
    // PRIVATE: Shared helpers
    // ============================================================

    // applyPartialLayout: calculate and apply placements for specific cells
    // Used by moveWindowToCell and moveWindowCrossDisplay
    private func applyPartialLayout(
        spaceID, cellIDs, displayBounds, displayUUID, displayName
    ) async:
        let layoutID = await gridState.getCurrentLayout(spaceID: spaceID)
        guard layoutID not empty else: return
        guard let layoutDef = try? await MainActor.run({ try gridConfig.getLayout(id: layoutID) })

        let columnRatios = await gridState.getColumnRatios(spaceID: spaceID)
        let rowRatios = await gridState.getRowRatios(spaceID: spaceID)
        let calculated = GridLayout.calculateLayoutWithRatios(
            layout: layoutDef, screenRect: displayBounds, gap: 0,
            columnRatios: columnRatios, rowRatios: rowRatios
        )

        var assignments: [String: [UInt32]] = [:]
        for cellID in cellIDs:
            assignments[cellID] = await gridState.getCellWindows(spaceID: spaceID, cellID: cellID)

        let (cellModes, cellRatios) = await buildCellModesAndRatios(
            cellIDs: cellIDs, spaceID: spaceID, layoutDef: layoutDef
        )

        let baseSpacing = await MainActor.run { gridConfig.getBaseSpacing() }
        let settingsPadding = await MainActor.run { gridConfig.getSettingsPadding() }
        let settingsWindowSpacing = await MainActor.run { gridConfig.getSettingsWindowSpacing() }
        let defaultMode = await MainActor.run { gridConfig.settings.defaultStackMode }

        var placements = GridLayout.calculateAllWindowPlacements(
            calculatedLayout: calculated, layout: layoutDef,
            assignments: assignments, cellModes: cellModes, cellRatios: cellRatios,
            defaultMode: defaultMode, baseSpacing: baseSpacing,
            settingsPadding: settingsPadding, settingsWindowSpacing: settingsWindowSpacing
        )

        let offset = await MainActor.run { gridConfig.getDisplayOffset(uuid: displayUUID, name: displayName) }
        if offset.x != 0 || offset.y != 0:
            for i in 0..<placements.count:
                placements[i] = GridWindowPlacement(
                    windowID: placements[i].windowID,
                    bounds: placements[i].bounds.offsetBy(dx: offset.x, dy: offset.y)
                )

        await applyPlacementsViaAX(placements)

    // buildCellModesAndRatios: resolve cell modes + split ratios for given cells
    // Priority: state override > layout cellModes > per-cell config > default
    private func buildCellModesAndRatios(
        cellIDs: [String], spaceID: String, layoutDef: GridLayoutDef
    ) async -> (modes: [String: GridStackMode], ratios: [String: [Double]]):
        var cellModes: [String: GridStackMode] = [:]
        var cellRatios: [String: [Double]] = [:]

        for cellID in cellIDs:
            // 1. Check per-cell StackMode in layout definition
            for cell in layoutDef.cells:
                if cell.id == cellID && cell.stackMode != nil:
                    cellModes[cellID] = cell.stackMode!
                    break
            // 2. Check layout's cellModes map (overrides per-cell)
            if let layoutModes = layoutDef.cellModes, let mode = layoutModes[cellID]:
                cellModes[cellID] = mode
            // 3. State override (highest priority)
            if let stateMode = await gridState.getCellStackMode(spaceID: spaceID, cellID: cellID):
                cellModes[cellID] = stateMode
            let ratios = await gridState.getCellSplitRatios(spaceID: spaceID, cellID: cellID)
            if !ratios.isEmpty:
                cellRatios[cellID] = ratios

        return (cellModes, cellRatios)

    // applyPlacementsViaAX: position windows using WindowManipulator
    // Runs placements in parallel via TaskGroup, AX calls go through WindowManipulator
    private func applyPlacementsViaAX(_ placements: [GridWindowPlacement]) async:
        if placements.isEmpty: return

        await withTaskGroup(of: Void.self) { group in
            for placement in placements:
                group.addTask {
                    guard let context = await ManipulationContext.from(windowID: placement.windowID) else:
                        log warning: window not found
                        return
                    let success = await self.windowManipulator.setWindowFrame(
                        context: context, frame: placement.bounds
                    )
                    if !success:
                        log warning: failed to position window
                }
        }

    // raiseNextWindowIfTabbed: raise the remaining visible window in source cell
    // after a window is moved out of a tabbed cell
    private func raiseNextWindowIfTabbed(
        sourceCell: String, spaceID: String,
        cellModes: [String: GridStackMode], defaultMode: GridStackMode
    ) async:
        let mode = cellModes[sourceCell] ?? defaultMode
        guard mode == .tabs else: return

        let cellWindows = await gridState.getCellWindows(spaceID: spaceID, cellID: sourceCell)
        guard !cellWindows.isEmpty else: return

        // Focus the last-focused window in the source cell
        let spaceState = await gridState.getSpaceReadOnly(spaceID)
        let cellState = spaceState?.cells[sourceCell]
        var nextIdx = 0
        if let cellState:
            if cellState.lastFocusedWid != 0:
                for (i, wid) in cellWindows.enumerated():
                    if wid == cellState.lastFocusedWid:
                        nextIdx = i
                        break
            else if cellState.lastFocusedIdx >= 0 && cellState.lastFocusedIdx < cellWindows.count:
                nextIdx = cellState.lastFocusedIdx

        // Raise via WindowManipulator focus (just AX raise, don't change grid focus)
        guard let context = await ManipulationContext.from(windowID: cellWindows[nextIdx]) else: return
        windowManipulator.focusWindow(pid: context.pid, windowID: cellWindows[nextIdx])

    // findDisplayBounds: look up display bounds from wmState
    private func findDisplayBounds(_ displayUUID: String, from wmState: WindowManagerState) -> CGRect:
        for display in wmState.displays:
            if display.uuid == displayUUID:
                return display.visibleFrame ?? display.frame
        return .zero

    // findDisplayName: look up display name from wmState
    private func findDisplayName(_ displayUUID: String, wmState: WindowManagerState) -> String:
        for display in wmState.displays:
            if display.uuid == displayUUID:
                return display.name ?? ""
        return ""
```

### Grid/GridApply.swift

```
// Apply options (mirrors Go's ApplyLayoutOptions)
struct GridApplyOptions:
    strategy: GridAssignmentStrategy = .position
    displayFilter: String? = nil    // if set, only refresh this display UUID

// Display error for multi-display refresh
struct GridDisplayError:
    displayUUID: String
    displayName: String
    error: Error

enum GridApplyError:
    noLayout
    layoutNotFound(String)
    noDisplayBounds
    allDisplaysFailed([GridDisplayError])

class GridApply:

    // Dependencies (weak, set via setup)
    weak gridState: GridState
    weak gridConfig: GridConfig
    weak stateManager: StateManager
    weak windowManipulator: WindowManipulator
    weak gridReconciler: GridReconciler
    weak simpleBorderManager: SimpleBorderManager
    weak gridFocus: GridFocus

    init() {}

    func setup(gridState, gridConfig, stateManager, windowManipulator, gridReconciler, simpleBorderManager, gridFocus):
        store weak references
        log "apply.init"

    // ============================================================
    // applyLayout: full layout application orchestrator
    // ============================================================
    // This is the big one -- equivalent to Go's 247-line ApplyLayout function.
    // Coordinates: config -> assignment -> layout calc -> AX positioning -> border sync
    func applyLayout(spaceID: String, layoutID: String, strategy: GridAssignmentStrategy = .position) async throws:
        jlog("layout.apply.start", data: ["lid": layoutID, "sid": spaceID])

        // 1. Suppress reconciler during bulk placement
        gridReconciler?.setSuppressed(true)
        defer { gridReconciler?.setSuppressed(false) }

        // 2. Get layout definition
        let layoutDef = try await MainActor.run { try gridConfig.getLayout(id: layoutID) }

        // 3. Get display bounds for this space
        let wmState = await stateManager.getState()
        let displayBounds = gridFocus.getDisplayBoundsForSpace(spaceID, wmState: wmState)

        // 4. Get existing track ratios (preserve when reapplying same layout)
        let existingLayoutID = await gridState.getCurrentLayout(spaceID: spaceID)
        var columnRatios: [Double]? = nil
        var rowRatios: [Double]? = nil
        if existingLayoutID == layoutID:
            columnRatios = await gridState.getColumnRatios(spaceID: spaceID)
            rowRatios = await gridState.getRowRatios(spaceID: spaceID)

        // 5. Calculate grid layout (gap=0, padding handles spacing)
        let calculated = GridLayout.calculateLayoutWithRatios(
            layout: layoutDef, screenRect: displayBounds, gap: 0,
            columnRatios: columnRatios, rowRatios: rowRatios
        )

        // 6. Filter tileable windows from StateManager
        let exclusions = await MainActor.run { gridConfig.getWindowExclusions() }
        let tileableWindows = filterTileableFromState(wmState: wmState, spaceID: spaceID, exclusions: exclusions)

        // 7. Get previous assignments from GridState
        let previousAssignments = await gridState.getWindowAssignments(spaceID: spaceID)

        // 8. Assign windows to cells
        let appRules = await MainActor.run { gridConfig.appRules }
        let assignment = GridAssignment.assignWindows(
            windows: tileableWindows,
            layout: layoutDef,
            cellBounds: calculated.cellBounds,
            appRules: appRules,
            previousAssignments: previousAssignments,
            strategy: strategy,
            bundleIDLookup: { pid in
                wmState.windows.values.first(where: { $0.pid == pid })?.bundleID
            }
        )

        // 9. Build cell modes and ratios from config+state
        let allCellIDs = layoutDef.cells.map { $0.id }
        var cellModes: [String: GridStackMode] = [:]
        var cellRatios: [String: [Double]] = [:]

        for cellID in allCellIDs:
            // layout cell-level stackMode
            for cell in layoutDef.cells:
                if cell.id == cellID && cell.stackMode != nil:
                    cellModes[cellID] = cell.stackMode!
                    break
            // layout cellModes map
            if let lm = layoutDef.cellModes, let mode = lm[cellID]:
                cellModes[cellID] = mode
            // state override
            if let stateMode = await gridState.getCellStackMode(spaceID: spaceID, cellID: cellID):
                cellModes[cellID] = stateMode
            let ratios = await gridState.getCellSplitRatios(spaceID: spaceID, cellID: cellID)
            if !ratios.isEmpty:
                // Adjust ratios to match actual window count
                let windowCount = assignment.assignments[cellID]?.count ?? 0
                if ratios.count != windowCount:
                    cellRatios[cellID] = GridLayout.adjustRatiosForWindowCount(ratios, newCount: windowCount)
                else:
                    cellRatios[cellID] = ratios

        // 10. Calculate window placements
        let baseSpacing = await MainActor.run { gridConfig.getBaseSpacing() }
        let settingsPadding = await MainActor.run { gridConfig.getSettingsPadding() }
        let settingsWindowSpacing = await MainActor.run { gridConfig.getSettingsWindowSpacing() }
        let defaultMode = await MainActor.run { gridConfig.settings.defaultStackMode }

        var placements = GridLayout.calculateAllWindowPlacements(
            calculatedLayout: calculated, layout: layoutDef,
            assignments: assignment.assignments, cellModes: cellModes,
            cellRatios: cellRatios, defaultMode: defaultMode,
            baseSpacing: baseSpacing, settingsPadding: settingsPadding,
            settingsWindowSpacing: settingsWindowSpacing
        )

        // 11. Apply display offset
        let displayUUID = gridFocus.findCurrentDisplayUUID(wmState, spaceID)
        let displayName = findDisplayName(displayUUID, wmState: wmState)
        let offset = await MainActor.run { gridConfig.getDisplayOffset(uuid: displayUUID, name: displayName) }
        if offset.x != 0 || offset.y != 0:
            placements = placements.map { p in
                GridWindowPlacement(windowID: p.windowID, bounds: p.bounds.offsetBy(dx: offset.x, dy: offset.y))
            }

        // 12. Apply placements via WindowManipulator (parallel via TaskGroup)
        await applyPlacementsViaAX(placements)

        // 13. Update GridState
        if existingLayoutID != layoutID:
            // Switching layouts: reset state
            let layoutIndex = await MainActor.run { gridConfig.getLayoutIDs().firstIndex(of: layoutID) ?? 0 }
            await gridState.setCurrentLayout(spaceID: spaceID, layoutID: layoutID, layoutIndex: layoutIndex)
        else:
            // Same layout: just update assignments (preserves ratios)
            // Note: setCurrentLayout clears ratios, so we skip it
            pass

        await gridState.setWindowAssignments(spaceID: spaceID, assignments: assignment.assignments)

        // 14. Sync borders
        // (reconciler unsuppression in defer block triggers border sync automatically)
        // But we want immediate sync, so call it explicitly
        await gridReconciler?.syncBordersForSpace(spaceID, displayUUID: displayUUID)

        jlog("layout.apply.done", data: ["lid": layoutID, "placements": placements.count])

    // ============================================================
    // reapplyLayout: reapply current layout with optional strategy override
    // ============================================================
    func reapplyLayout(spaceID: String, strategy: GridAssignmentStrategy = .preserve) async throws:
        let layoutID = await gridState.getCurrentLayout(spaceID: spaceID)
        guard !layoutID.isEmpty else: throw GridApplyError.noLayout

        try await applyLayout(spaceID: spaceID, layoutID: layoutID, strategy: strategy)

    // ============================================================
    // applyCellLayout: apply layout changes to a single cell only
    // ============================================================
    // More efficient than reapplyLayout when only one cell changed
    func applyCellLayout(spaceID: String, cellID: String) async throws:
        jlog("layout.cell.start", data: ["cellID": cellID, "sid": spaceID])

        // 1. Get layout
        let layoutID = await gridState.getCurrentLayout(spaceID: spaceID)
        guard !layoutID.isEmpty else: throw GridApplyError.noLayout
        let layoutDef = try await MainActor.run { try gridConfig.getLayout(id: layoutID) }

        // 2. Get display bounds
        let wmState = await stateManager.getState()
        let displayBounds = gridFocus.getDisplayBoundsForSpace(spaceID, wmState: wmState)

        // 3. Calculate full layout (needed for cell bounds with track ratios)
        let columnRatios = await gridState.getColumnRatios(spaceID: spaceID)
        let rowRatios = await gridState.getRowRatios(spaceID: spaceID)
        let calculated = GridLayout.calculateLayoutWithRatios(
            layout: layoutDef, screenRect: displayBounds, gap: 0,
            columnRatios: columnRatios, rowRatios: rowRatios
        )

        // 4. Get target cell's windows
        let cellWindows = await gridState.getCellWindows(spaceID: spaceID, cellID: cellID)
        if cellWindows.isEmpty:
            return  // Nothing to do

        // 5. Build single-cell assignment
        let singleAssignment = [cellID: cellWindows]

        // 6. Build cell modes + ratios
        var cellModes: [String: GridStackMode] = [:]
        if let stateMode = await gridState.getCellStackMode(spaceID: spaceID, cellID: cellID):
            cellModes[cellID] = stateMode

        var cellRatios: [String: [Double]] = [:]
        let ratios = await gridState.getCellSplitRatios(spaceID: spaceID, cellID: cellID)
        if !ratios.isEmpty:
            cellRatios[cellID] = ratios

        // 7. Calculate placements for this cell
        let baseSpacing = await MainActor.run { gridConfig.getBaseSpacing() }
        let settingsPadding = await MainActor.run { gridConfig.getSettingsPadding() }
        let settingsWindowSpacing = await MainActor.run { gridConfig.getSettingsWindowSpacing() }
        let defaultMode = await MainActor.run { gridConfig.settings.defaultStackMode }

        var placements = GridLayout.calculateAllWindowPlacements(
            calculatedLayout: calculated, layout: layoutDef,
            assignments: singleAssignment, cellModes: cellModes, cellRatios: cellRatios,
            defaultMode: defaultMode, baseSpacing: baseSpacing,
            settingsPadding: settingsPadding, settingsWindowSpacing: settingsWindowSpacing
        )

        // 8. Apply display offset
        let displayUUID = gridFocus.findCurrentDisplayUUID(wmState, spaceID)
        let displayName = findDisplayName(displayUUID, wmState: wmState)
        let offset = await MainActor.run { gridConfig.getDisplayOffset(uuid: displayUUID, name: displayName) }
        if offset.x != 0 || offset.y != 0:
            placements = placements.map { p in
                GridWindowPlacement(windowID: p.windowID, bounds: p.bounds.offsetBy(dx: offset.x, dy: offset.y))
            }

        // 9. Apply placements
        await applyPlacementsViaAX(placements)

        // 10. Sync borders
        await gridReconciler?.syncBordersForSpace(spaceID, displayUUID: displayUUID)

    // ============================================================
    // refreshAllDisplays: refresh layouts on all connected displays
    // ============================================================
    func refreshAllDisplays(displayFilter: String? = nil) async -> [GridDisplayError]:
        jlog("layout.refresh_all.start")

        let wmState = await stateManager.getState()
        var errors: [GridDisplayError] = []
        var processedCount = 0

        for display in wmState.displays:
            // Skip if display filter is set and doesn't match
            if let filter = displayFilter, display.uuid != filter:
                continue
            processedCount += 1

            // Find active space ID for this display
            let spaceID = findSpaceIDForDisplay(display.uuid, wmState: wmState)
            guard let spaceID else:
                errors.append(GridDisplayError(displayUUID: display.uuid, displayName: display.name ?? "unknown", error: "no space for display"))
                continue

            // Check if space has existing layout state
            let layoutID = await gridState.getCurrentLayout(spaceID: spaceID)
            let strategy: GridAssignmentStrategy
            let targetLayoutID: String

            if !layoutID.isEmpty:
                // Reapply existing layout with preserve strategy
                targetLayoutID = layoutID
                strategy = .preserve
            else:
                // No layout: apply default
                if let _ = try? await MainActor.run({ try gridConfig.getLayout(id: "default") }):
                    targetLayoutID = "default"
                else:
                    targetLayoutID = "single-tabbed"
                strategy = .position

            // Apply layout
            do:
                try await applyLayout(spaceID: spaceID, layoutID: targetLayoutID, strategy: strategy)
            catch:
                errors.append(GridDisplayError(displayUUID: display.uuid, displayName: display.name ?? "unknown", error: error))

        if let filter = displayFilter, processedCount == 0:
            errors.append(GridDisplayError(displayUUID: filter, displayName: "unknown", error: "no display found"))

        jlog("layout.refresh_all.done", data: ["processed": processedCount, "errors": errors.count])
        return errors

    // ============================================================
    // PRIVATE: Shared helpers
    // ============================================================

    // applyPlacementsViaAX: position windows via WindowManipulator
    private func applyPlacementsViaAX(_ placements: [GridWindowPlacement]) async:
        if placements.isEmpty: return

        await withTaskGroup(of: Void.self) { group in
            for placement in placements:
                group.addTask {
                    guard let context = await ManipulationContext.from(windowID: placement.windowID) else:
                        jlog("warn.placement", data: ["wid": placement.windowID, "reason": "no_context"])
                        return
                    let success = await self.windowManipulator.setWindowFrame(
                        context: context, frame: placement.bounds
                    )
                    if !success:
                        jlog("warn.placement", data: ["wid": placement.windowID, "reason": "ax_fail"])
                }
        }

    // filterTileableFromState: get tileable windows for a space from StateManager
    // Equivalent to Go's snap.FilterTileable(exclusions) but from live state
    private func filterTileableFromState(
        wmState: WindowManagerState, spaceID: String, exclusions: GridWindowExclusion
    ) -> [WindowState]:
        var tileable: [WindowState] = []

        for (_, windowState) in wmState.windows:
            // Check if window is on this space
            let windowSpaceID = String(windowState.spaceID ?? 0)
            // TODO: need to verify the space matching logic against StateManager's space tracking
            // For now: include windows that are on the active space
            guard windowSpaceID == spaceID else: continue

            // Check tileable
            guard isTileable(window: windowState) else: continue

            // Check exclusions
            let appName = windowState.appName ?? ""
            if isExcluded(window: windowState, appName: appName, exclusions: exclusions):
                continue

            tileable.append(windowState)

        return tileable

    // findSpaceIDForDisplay: find the active space ID for a display
    private func findSpaceIDForDisplay(_ displayUUID: String, wmState: WindowManagerState) -> String?:
        for (spaceKey, space) in wmState.spaces:
            if space.displayUUID == displayUUID && space.isActive:
                return spaceKey
        return nil

    // findDisplayName: look up display name
    private func findDisplayName(_ displayUUID: String, wmState: WindowManagerState) -> String:
        for display in wmState.displays:
            if display.uuid == displayUUID:
                return display.name ?? ""
        return ""
```

## Design Notes

### Design Decisions

1. **Three separate files:** GridCellOps (cell-level operations), GridWindowMove (window movement including cross-display), GridApply (layout orchestrator). This follows the Go decomposition but with cleaner dependency injection.

2. **Shared `buildCellModesAndRatios` helper:** Both GridWindowMove and GridApply need to resolve cell modes through the same priority chain (state > layout cellModes > per-cell config > default). Extracted as a shared helper to avoid duplication. Kept in GridWindowMove since both need it -- could alternatively be a static function on a utility type.

3. **`applyPlacementsViaAX` uses TaskGroup:** Each window placement creates a ManipulationContext.from() (async StateManager lookup) then calls setWindowFrame. These run in parallel. The WindowManipulator's AX calls themselves are synchronous (not on a serial queue), which is fine since each operates on a different window/AX element. If contention becomes an issue, we can add a serial DispatchQueue later.

4. **Reconciler suppression on full applyLayout only:** The `applyLayout` method suppresses reconciliation during bulk placement. `applyCellLayout` does NOT suppress because it's a targeted update that the reconciler should not interfere with. `reapplyLayout` calls `applyLayout` which suppresses.

5. **Border sync strategy:** Instead of duplicating the reconciler's border sync logic, we make `syncBordersForSpace` internal on GridReconciler. GridApply and GridWindowMove call it directly after placement. The defer unsuppression in applyLayout also triggers a sync, but we want the explicit call for immediate feedback.

6. **filterTileableFromState:** Replaces Go's `snap.FilterTileable()`. Gets windows from StateManager's live state, filtered by space ID and tileability. This is a key architectural difference -- Go fetched a snapshot per operation, Swift uses live state.

7. **Circular dependency resolution:** GridCellOps and GridWindowMove need GridApply (for reapplyLayout/applyCellLayout), but GridApply exists independently. We use a `setApply()` method called after all objects are created, similar to how GridFocus and GridReconciler use `setup()`.

### Information Hidden

- **AX threading details** -- callers of applyPlacementsViaAX don't know about TaskGroup/AX serialization
- **Cell mode resolution chain** -- callers of getEffectiveStackMode don't know the 4-level priority
- **Display offset application** -- applied internally, callers just see correct placement
- **Border sync mechanics** -- delegated to GridReconciler, callers just know borders update

### Key Differences from Go

| Go Pattern | Swift Pattern |
|-----------|--------------|
| RPC client.Clone() per goroutine | TaskGroup + ManipulationContext.from() per task |
| server.Fetch()/FetchForSpace() per operation | StateManager.getState() (live, in-memory) |
| client.SendBorderConfig/SendCellAssignments | SimpleBorderManager.setCellAssignments() via GridReconciler |
| rs.Save() (blocking write) | GridState.markDirty() (debounced async write) |
| config.GetBaseSpacing() (sync) | await MainActor.run { gridConfig.getBaseSpacing() } |
| snap.FilterTileable(exclusions) | filterTileableFromState(wmState:spaceID:exclusions:) |
| layout.ApplyPlacements(ctx, c, placements) | applyPlacementsViaAX(placements) |

## PRE-GATE Status
- [x] Discovery complete
- [x] Pseudocode complete
- [x] Design reviewed (deep module analysis)
- [x] Ready for implementation
