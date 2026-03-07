import Foundation
import CoreGraphics

// MARK: - Cell Operations Errors

enum GridCellOpsError: Error, LocalizedError {
    case noLayout
    case noFocusedWindow
    case noFocusedCell
    case noCellInDirection(String)
    case needAtLeastTwoWindows
    case invalidMode(String)

    var errorDescription: String? {
        switch self {
        case .noLayout: return "no layout applied"
        case .noFocusedWindow: return "no focused window"
        case .noFocusedCell: return "no focused cell"
        case .noCellInDirection(let d): return "no cell in direction \(d)"
        case .needAtLeastTwoWindows: return "need at least two windows to swap"
        case .invalidMode(let m): return "invalid stack mode: \(m)"
        }
    }
}

// MARK: - GridCellOps

class GridCellOps {

    // Dependencies (weak references, set via setup)
    private weak var gridState: GridState?
    private weak var gridConfig: GridConfig?
    private weak var stateManager: StateManager?
    private weak var gridApply: GridApply?
    private weak var gridFocus: GridFocus?

    init() {}

    func setup(
        gridState: GridState,
        gridConfig: GridConfig,
        stateManager: StateManager,
        gridFocus: GridFocus
    ) {
        self.gridState = gridState
        self.gridConfig = gridConfig
        self.stateManager = stateManager
        self.gridFocus = gridFocus
        jlog("cellops.init")
    }

    // Set gridApply after it's created (circular dependency resolution)
    func setApply(_ apply: GridApply) {
        self.gridApply = apply
    }

    // ============================================================
    // PUBLIC: sendWindow - move focused window to adjacent cell
    // ============================================================

    func sendWindow(direction: GridDirection) async throws {
        guard let gridState = gridState,
              let gridConfig = gridConfig,
              let stateManager = stateManager,
              let gridFocus = gridFocus,
              let gridApply = gridApply else {
            throw GridCellOpsError.noLayout
        }

        // 1. Get current space state
        let wmState = await stateManager.getState()
        guard let spaceID = gridFocus.findActiveSpaceID(wmState) else {
            throw GridCellOpsError.noLayout
        }
        guard let spaceState = await gridState.getSpaceReadOnly(spaceID),
              !spaceState.currentLayoutId.isEmpty else {
            throw GridCellOpsError.noLayout
        }

        // 2. Get focused window and cell
        let windowID = await gridState.getFocusedWindow(spaceID: spaceID)
        guard windowID != 0 else {
            throw GridCellOpsError.noFocusedWindow
        }

        let currentCell = await gridState.getFocusedCell(spaceID: spaceID)
        guard let currentCell = currentCell else {
            throw GridCellOpsError.noFocusedCell
        }

        // 3. Calculate layout and find adjacent cells
        let layoutDef = try await MainActor.run { try gridConfig.getLayout(id: spaceState.currentLayoutId) }
        let displayBounds = gridFocus.getDisplayBoundsForSpace(spaceID, wmState: wmState)
        let columnRatios = await gridState.getColumnRatios(spaceID: spaceID)
        let rowRatios = await gridState.getRowRatios(spaceID: spaceID)
        let calculated = GridLayout.calculateLayoutWithRatios(
            layout: layoutDef,
            screenRect: displayBounds,
            gap: 0,
            columnRatios: columnRatios,
            rowRatios: rowRatios
        )

        // 4. Find target cell via adjacency
        let adjacentMap = GridLayout.getAdjacentCells(cellID: currentCell, cellBounds: calculated.cellBounds)
        let candidates = adjacentMap[direction] ?? []
        guard !candidates.isEmpty else {
            throw GridCellOpsError.noCellInDirection(direction.rawValue)
        }

        let targetCell = gridFocus.pickClosestCell(
            currentCell: currentCell,
            candidates: candidates,
            cellBounds: calculated.cellBounds
        )

        // 5. Move window in state: remove from old cell, assign to new
        await gridState.removeWindow(windowID, fromSpace: spaceID)
        await gridState.assignWindow(windowID, toCellID: targetCell, inSpace: spaceID)

        // 6. Update focus to follow window
        let targetCellWindows = await gridState.getCellWindows(spaceID: spaceID, cellID: targetCell)
        let newIndex = targetCellWindows.count - 1
        await gridState.setFocus(spaceID: spaceID, cellID: targetCell, windowIndex: max(0, newIndex))

        // 7. Reapply layout with preserve strategy
        try await gridApply.reapplyLayout(spaceID: spaceID, strategy: .preserve)
    }

    // ============================================================
    // PUBLIC: swapWindow - swap focused window with adjacent window in same cell
    // ============================================================

    func swapWindow(direction: GridDirection) async throws {
        guard let gridState = gridState,
              gridConfig != nil,
              let stateManager = stateManager,
              let gridFocus = gridFocus,
              let gridApply = gridApply else {
            throw GridCellOpsError.noLayout
        }

        // 1. Get current space state
        let wmState = await stateManager.getState()
        guard let spaceID = gridFocus.findActiveSpaceID(wmState) else {
            throw GridCellOpsError.noLayout
        }
        guard let spaceState = await gridState.getSpaceReadOnly(spaceID),
              !spaceState.currentLayoutId.isEmpty else {
            throw GridCellOpsError.noLayout
        }

        // 2. Get focused cell with at least 2 windows
        let cellID = await gridState.getFocusedCell(spaceID: spaceID)
        guard let cellID = cellID else {
            throw GridCellOpsError.noFocusedCell
        }
        let cellWindows = await gridState.getCellWindows(spaceID: spaceID, cellID: cellID)
        guard cellWindows.count >= 2 else {
            throw GridCellOpsError.needAtLeastTwoWindows
        }

        // 3. Get current window index
        let currentIdx = max(0, min(spaceState.focusedWindow, cellWindows.count - 1))

        // 4. Get effective stack mode for swap direction mapping
        let stackMode = await getEffectiveStackMode(
            spaceID: spaceID,
            cellID: cellID,
            layoutID: spaceState.currentLayoutId
        )

        // 5. Calculate swap target index
        let targetIdx = calculateSwapTarget(
            currentIdx: currentIdx,
            windowCount: cellWindows.count,
            direction: direction,
            stackMode: stackMode
        )

        // 6. Build new window order with swap applied
        var newWindows = cellWindows
        newWindows.swapAt(currentIdx, targetIdx)

        // 7. Get current split ratios and swap them too
        var splitRatios = await gridState.getCellSplitRatios(spaceID: spaceID, cellID: cellID)
        if splitRatios.count == cellWindows.count {
            splitRatios.swapAt(currentIdx, targetIdx)
            await gridState.setCellSplitRatios(spaceID: spaceID, cellID: cellID, ratios: splitRatios)
        }

        // 8. Update state: set new window order
        var allAssignments = await gridState.getWindowAssignments(spaceID: spaceID)
        allAssignments[cellID] = newWindows
        await gridState.setWindowAssignments(spaceID: spaceID, assignments: allAssignments)

        // 9. Update focus to follow the window to its new position
        await gridState.setFocus(spaceID: spaceID, cellID: cellID, windowIndex: targetIdx)

        // 10. Reapply layout with preserve strategy
        try await gridApply.reapplyLayout(spaceID: spaceID, strategy: .preserve)
    }

    // ============================================================
    // PUBLIC: setMode - set or cycle stack mode for focused cell
    // ============================================================

    func setMode(targetMode: GridStackMode?) async throws -> (cellID: String, newMode: GridStackMode) {
        guard let gridState = gridState,
              gridConfig != nil,
              let stateManager = stateManager,
              let gridFocus = gridFocus,
              let gridApply = gridApply else {
            throw GridCellOpsError.noLayout
        }

        // 1. Get current space state
        let wmState = await stateManager.getState()
        guard let spaceID = gridFocus.findActiveSpaceID(wmState) else {
            throw GridCellOpsError.noLayout
        }
        guard let spaceState = await gridState.getSpaceReadOnly(spaceID),
              !spaceState.currentLayoutId.isEmpty else {
            throw GridCellOpsError.noLayout
        }

        // 2. Get focused cell
        let cellID = await gridState.getFocusedCell(spaceID: spaceID)
        guard let cellID = cellID else {
            throw GridCellOpsError.noFocusedCell
        }

        // 3. Determine new mode
        let newMode: GridStackMode
        if let targetMode = targetMode {
            newMode = targetMode
        } else {
            // Cycle: vertical -> horizontal -> tabs -> vertical
            let currentMode = await getEffectiveStackMode(
                spaceID: spaceID,
                cellID: cellID,
                layoutID: spaceState.currentLayoutId
            )
            newMode = nextMode(currentMode)
        }

        // 4. Update state
        await gridState.setCellStackMode(spaceID: spaceID, cellID: cellID, mode: newMode)

        // 5. Apply cell layout only (more efficient than full reapply)
        try await gridApply.applyCellLayout(spaceID: spaceID, cellID: cellID)

        return (cellID, newMode)
    }

    // ============================================================
    // PRIVATE: Helper functions
    // ============================================================

    // nextMode: cycle through modes
    private func nextMode(_ current: GridStackMode) -> GridStackMode {
        switch current {
        case .vertical: return .horizontal
        case .horizontal: return .tabs
        case .tabs: return .vertical
        }
    }

    // getEffectiveStackMode: resolve stack mode priority chain
    // Priority: runtime override > cell config > layout cellModes > settings default
    private func getEffectiveStackMode(
        spaceID: String,
        cellID: String,
        layoutID: String
    ) async -> GridStackMode {
        guard let gridState = gridState,
              let gridConfig = gridConfig else {
            return .tabs
        }

        // 1. Check runtime override in GridState
        if let stateMode = await gridState.getCellStackMode(spaceID: spaceID, cellID: cellID) {
            return stateMode
        }

        // 2-3. Check layout config (cell-level StackMode and cellModes map)
        let layoutDefOpt: GridLayoutDef? = try? await MainActor.run { try gridConfig.getLayout(id: layoutID) }
        if let layoutDef = layoutDefOpt {
            // Check per-cell StackMode
            for cell in layoutDef.cells {
                if cell.id == cellID && cell.stackMode != nil {
                    return cell.stackMode!
                }
            }
            // Check cellModes map
            if let mode = layoutDef.cellModes[cellID] {
                return mode
            }
        }

        // 4. Fall back to settings default
        let defaultMode = await MainActor.run { gridConfig.settings.defaultStackMode }
        return defaultMode
    }

    // calculateSwapTarget: direction + stack mode -> target index (with wrap)
    private func calculateSwapTarget(
        currentIdx: Int,
        windowCount: Int,
        direction: GridDirection,
        stackMode: GridStackMode
    ) -> Int {
        let delta: Int
        switch stackMode {
        case .vertical:
            delta = (direction == .up || direction == .left) ? -1 : 1
        case .horizontal:
            delta = (direction == .left || direction == .up) ? -1 : 1
        case .tabs:
            delta = (direction == .left || direction == .up) ? -1 : 1
        }
        return (currentIdx + delta + windowCount) % windowCount
    }
}
