import Foundation
import CoreGraphics

// MARK: - Move Result Type

struct GridMoveResult: Sendable {
    let windowID: UInt32
    let sourceCell: String
    let targetCell: String
    let sourceSpace: String
    let targetSpace: String
    let crossDisplay: Bool
}

// MARK: - Move Options

struct GridMoveOpts: Sendable {
    var wrapAround: Bool = false
    var extend: Bool = false
    var windowID: UInt32 = 0
}

// MARK: - Move Errors

enum GridWindowMoveError: Error, LocalizedError {
    case noLayout
    case noFocusedWindow
    case windowNotInCell(UInt32)
    case noCellInDirection(String)
    case cannotDetermineDisplay
    case noDisplayInDirection
    case noCellsOnAdjacentDisplay
    case layoutNotFound(String)

    var errorDescription: String? {
        switch self {
        case .noLayout: return "no layout applied"
        case .noFocusedWindow: return "no focused window"
        case .windowNotInCell(let id): return "window \(id) not in any cell"
        case .noCellInDirection(let d): return "no cell in direction \(d)"
        case .cannotDetermineDisplay: return "cannot determine current display"
        case .noDisplayInDirection: return "no display in direction"
        case .noCellsOnAdjacentDisplay: return "no cells on adjacent display"
        case .layoutNotFound(let id): return "layout not found: \(id)"
        }
    }
}

// MARK: - GridWindowMove

class GridWindowMove {

    // Dependencies (weak references, set via setup)
    private weak var gridState: GridState?
    private weak var gridConfig: GridConfig?
    private weak var stateManager: StateManager?
    private weak var gridFocus: GridFocus?
    private weak var gridApply: GridApply?
    private weak var windowManipulator: WindowManipulator?
    private weak var gridReconciler: GridReconciler?

    init() {}

    func setup(
        gridState: GridState,
        gridConfig: GridConfig,
        stateManager: StateManager,
        gridFocus: GridFocus,
        windowManipulator: WindowManipulator,
        gridReconciler: GridReconciler
    ) {
        self.gridState = gridState
        self.gridConfig = gridConfig
        self.stateManager = stateManager
        self.gridFocus = gridFocus
        self.windowManipulator = windowManipulator
        self.gridReconciler = gridReconciler
        jlog("winmove.init")
    }

    // Set gridApply after it's created (circular dependency resolution)
    func setApply(_ apply: GridApply) {
        self.gridApply = apply
    }

    // ============================================================
    // PUBLIC: moveWindow - move window to adjacent cell (same or cross display)
    // ============================================================

    func moveWindow(direction: GridDirection, opts: GridMoveOpts) async throws -> GridMoveResult {
        guard let gridState = gridState,
              let gridConfig = gridConfig,
              let stateManager = stateManager,
              let gridFocus = gridFocus else {
            throw GridWindowMoveError.noLayout
        }

        // 1. Get space state
        let wmState = await stateManager.getState()
        guard let spaceID = gridFocus.findActiveSpaceID(wmState) else {
            throw GridWindowMoveError.noLayout
        }
        guard let spaceState = await gridState.getSpaceReadOnly(spaceID),
              !spaceState.currentLayoutId.isEmpty else {
            throw GridWindowMoveError.noLayout
        }

        // 2. Determine which window to move
        let windowID = opts.windowID != 0
            ? opts.windowID
            : await gridState.getFocusedWindow(spaceID: spaceID)
        guard windowID != 0 else {
            throw GridWindowMoveError.noFocusedWindow
        }

        // 3. Find source cell
        let sourceCell = await gridState.getWindowCell(windowID: windowID, inSpace: spaceID)
        guard let sourceCell = sourceCell else {
            throw GridWindowMoveError.windowNotInCell(windowID)
        }

        // 4. Calculate layout and find adjacent cells
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

        let adjacentMap = GridLayout.getAdjacentCells(cellID: sourceCell, cellBounds: calculated.cellBounds)
        var candidates = adjacentMap[direction] ?? []

        // 5. Handle no adjacent cells
        if candidates.isEmpty {
            // Try cross-display if extend enabled
            if opts.extend {
                let result = try await moveWindowCrossDisplay(
                    direction: direction,
                    windowID: windowID,
                    sourceCell: sourceCell,
                    currentCellBounds: calculated.cellBounds,
                    wmState: wmState,
                    spaceID: spaceID
                )
                return result
            }

            if !opts.wrapAround {
                throw GridWindowMoveError.noCellInDirection(direction.rawValue)
            }

            // Wrap: find opposite edge cells
            candidates = gridFocus.findWrapTarget(
                direction: direction,
                currentCell: sourceCell,
                cellBounds: calculated.cellBounds
            )
            guard !candidates.isEmpty else {
                throw GridWindowMoveError.noCellInDirection(direction.rawValue)
            }
        }

        // 6. Pick closest candidate
        let targetCell = gridFocus.pickClosestCell(
            currentCell: sourceCell,
            candidates: candidates,
            cellBounds: calculated.cellBounds
        )

        // 7. Move window within same space
        return try await moveWindowToCell(
            windowID: windowID,
            sourceCell: sourceCell,
            targetCell: targetCell,
            spaceID: spaceID,
            layoutDef: layoutDef,
            displayBounds: displayBounds,
            wmState: wmState
        )
    }

    // ============================================================
    // PRIVATE: moveWindowToCell (same space)
    // ============================================================

    private func moveWindowToCell(
        windowID: UInt32,
        sourceCell: String,
        targetCell: String,
        spaceID: String,
        layoutDef: GridLayoutDef,
        displayBounds: CGRect,
        wmState: WindowManagerState
    ) async throws -> GridMoveResult {
        guard let gridState = gridState,
              let gridConfig = gridConfig,
              let gridFocus = gridFocus,
              let gridReconciler = gridReconciler else {
            throw GridWindowMoveError.noLayout
        }

        // 1. Update state: prepend window to target cell (removes from source)
        await gridState.prependWindow(windowID, toCellID: targetCell, inSpace: spaceID)

        // 2. Update focus to follow moved window
        await gridState.setFocus(spaceID: spaceID, cellID: targetCell, windowIndex: 0)

        // 3. Calculate placements for affected cells only
        let columnRatios = await gridState.getColumnRatios(spaceID: spaceID)
        let rowRatios = await gridState.getRowRatios(spaceID: spaceID)
        let calculated = GridLayout.calculateLayoutWithRatios(
            layout: layoutDef,
            screenRect: displayBounds,
            gap: 0,
            columnRatios: columnRatios,
            rowRatios: rowRatios
        )

        // 4. Build assignments for affected cells
        let affectedCells = [sourceCell, targetCell]
        var affectedAssignments: [String: [UInt32]] = [:]
        for cellID in affectedCells {
            affectedAssignments[cellID] = await gridState.getCellWindows(spaceID: spaceID, cellID: cellID)
        }

        // 5. Build cell modes and ratios from config+state hierarchy
        let (cellModes, cellRatios) = await buildCellModesAndRatios(
            cellIDs: affectedCells,
            spaceID: spaceID,
            layoutDef: layoutDef
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
        if offset.x != 0 || offset.y != 0 {
            for i in 0..<placements.count {
                placements[i] = GridWindowPlacement(
                    windowID: placements[i].windowID,
                    bounds: placements[i].bounds.offsetBy(dx: offset.x, dy: offset.y)
                )
            }
        }

        // 8. Apply placements via WindowManipulator
        await applyPlacementsViaAX(placements)

        // 9. Handle tab mode: raise next window in source cell if tabbed
        await raiseNextWindowIfTabbed(
            sourceCell: sourceCell,
            spaceID: spaceID,
            cellModes: cellModes,
            defaultMode: defaultMode
        )

        // 10. Focus the moved window
        try await gridFocus.focusWindowByID(windowID)

        // 11. Sync borders for current space
        let displayUUIDForBorders = gridFocus.findCurrentDisplayUUID(wmState, spaceID)
        await gridReconciler.syncBordersForSpace(spaceID, displayUUID: displayUUIDForBorders)

        return GridMoveResult(
            windowID: windowID,
            sourceCell: sourceCell,
            targetCell: targetCell,
            sourceSpace: spaceID,
            targetSpace: spaceID,
            crossDisplay: false
        )
    }

    // ============================================================
    // PRIVATE: moveWindowCrossDisplay
    // ============================================================

    private func moveWindowCrossDisplay(
        direction: GridDirection,
        windowID: UInt32,
        sourceCell: String,
        currentCellBounds: [String: CGRect],
        wmState: WindowManagerState,
        spaceID: String
    ) async throws -> GridMoveResult {
        guard let gridState = gridState,
              let gridConfig = gridConfig,
              let gridFocus = gridFocus,
              let windowManipulator = windowManipulator,
              let gridReconciler = gridReconciler else {
            throw GridWindowMoveError.noLayout
        }

        // 1. Find current display UUID
        let currentDisplayUUID = gridFocus.findCurrentDisplayUUID(wmState, spaceID)
        guard !currentDisplayUUID.isEmpty else {
            throw GridWindowMoveError.cannotDetermineDisplay
        }

        // 2. Find adjacent display
        var adjacentDisplay = gridFocus.findAdjacentDisplay(
            currentDisplayUUID: currentDisplayUUID,
            direction: direction,
            displays: wmState.displays
        )
        if adjacentDisplay == nil {
            adjacentDisplay = gridFocus.findOppositeDisplay(
                currentDisplayUUID: currentDisplayUUID,
                direction: direction,
                displays: wmState.displays
            )
        }
        guard let adjacentDisplay = adjacentDisplay else {
            throw GridWindowMoveError.noDisplayInDirection
        }

        // 3. Get cells on target display
        let (targetCellBounds, targetSpaceID) = try await gridFocus.getDisplayCells(adjacentDisplay)
        let targetSpaceIDStr = String(targetSpaceID)

        // 4. Map visual position to target display
        let currentDisplayBounds = findDisplayBounds(currentDisplayUUID, from: wmState)
        let currentBounds = currentCellBounds[sourceCell] ?? .zero
        let targetDisplayBounds = adjacentDisplay.visibleFrame ?? adjacentDisplay.frame ?? .zero
        let targetPoint = gridFocus.matchVisualPosition(
            sourceCell: currentBounds,
            sourceDisplay: currentDisplayBounds,
            targetDisplay: targetDisplayBounds
        )

        // 5. Find closest cell on target display
        let targetCell = gridFocus.findClosestCellToPoint(point: targetPoint, cellBounds: targetCellBounds)
        guard !targetCell.isEmpty else {
            throw GridWindowMoveError.noCellsOnAdjacentDisplay
        }

        // 6. Move window to target space via WindowManipulator
        let _ = windowManipulator.moveWindowToSpace(windowID: windowID, spaceID: targetSpaceID)

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
        if !sourceCellWindows.isEmpty {
            await applyPartialLayout(
                spaceID: spaceID,
                cellIDs: [sourceCell],
                displayBounds: currentDisplayBounds,
                displayUUID: currentDisplayUUID,
                displayName: findDisplayName(currentDisplayUUID, wmState: wmState)
            )
            // Handle tab mode raise for source cell
            let defaultMode = await MainActor.run { gridConfig.settings.defaultStackMode }
            let sourceLayoutID = await gridState.getCurrentLayout(spaceID: spaceID)
            let srcLayoutDef: GridLayoutDef? = try? await MainActor.run { try gridConfig.getLayout(id: sourceLayoutID) }
            if let layoutDef = srcLayoutDef {
                let (srcModes, _) = await buildCellModesAndRatios(
                    cellIDs: [sourceCell],
                    spaceID: spaceID,
                    layoutDef: layoutDef
                )
                await raiseNextWindowIfTabbed(
                    sourceCell: sourceCell,
                    spaceID: spaceID,
                    cellModes: srcModes,
                    defaultMode: defaultMode
                )
            }
        }

        // 10. Focus the moved window
        try await gridFocus.focusWindowByID(windowID)

        // 11. Sync borders on target display
        await gridReconciler.syncBordersForSpace(targetSpaceIDStr, displayUUID: adjacentDisplay.uuid)

        return GridMoveResult(
            windowID: windowID,
            sourceCell: sourceCell,
            targetCell: targetCell,
            sourceSpace: spaceID,
            targetSpace: targetSpaceIDStr,
            crossDisplay: true
        )
    }

    // ============================================================
    // PRIVATE: Shared helpers
    // ============================================================

    // applyPartialLayout: calculate and apply placements for specific cells
    private func applyPartialLayout(
        spaceID: String,
        cellIDs: [String],
        displayBounds: CGRect,
        displayUUID: String,
        displayName: String
    ) async {
        guard let gridState = gridState,
              let gridConfig = gridConfig else { return }

        let layoutID = await gridState.getCurrentLayout(spaceID: spaceID)
        guard !layoutID.isEmpty else { return }
        let layoutDefOpt: GridLayoutDef? = try? await MainActor.run { try gridConfig.getLayout(id: layoutID) }
        guard let layoutDef = layoutDefOpt else { return }

        let columnRatios = await gridState.getColumnRatios(spaceID: spaceID)
        let rowRatios = await gridState.getRowRatios(spaceID: spaceID)
        let calculated = GridLayout.calculateLayoutWithRatios(
            layout: layoutDef,
            screenRect: displayBounds,
            gap: 0,
            columnRatios: columnRatios,
            rowRatios: rowRatios
        )

        var assignments: [String: [UInt32]] = [:]
        for cellID in cellIDs {
            assignments[cellID] = await gridState.getCellWindows(spaceID: spaceID, cellID: cellID)
        }

        let (cellModes, cellRatios) = await buildCellModesAndRatios(
            cellIDs: cellIDs,
            spaceID: spaceID,
            layoutDef: layoutDef
        )

        let baseSpacing = await MainActor.run { gridConfig.getBaseSpacing() }
        let settingsPadding = await MainActor.run { gridConfig.getSettingsPadding() }
        let settingsWindowSpacing = await MainActor.run { gridConfig.getSettingsWindowSpacing() }
        let defaultMode = await MainActor.run { gridConfig.settings.defaultStackMode }

        var placements = GridLayout.calculateAllWindowPlacements(
            calculatedLayout: calculated,
            layout: layoutDef,
            assignments: assignments,
            cellModes: cellModes,
            cellRatios: cellRatios,
            defaultMode: defaultMode,
            baseSpacing: baseSpacing,
            settingsPadding: settingsPadding,
            settingsWindowSpacing: settingsWindowSpacing
        )

        let offset = await MainActor.run { gridConfig.getDisplayOffset(uuid: displayUUID, name: displayName) }
        if offset.x != 0 || offset.y != 0 {
            for i in 0..<placements.count {
                placements[i] = GridWindowPlacement(
                    windowID: placements[i].windowID,
                    bounds: placements[i].bounds.offsetBy(dx: offset.x, dy: offset.y)
                )
            }
        }

        await applyPlacementsViaAX(placements)
    }

    // buildCellModesAndRatios: resolve cell modes + split ratios for given cells
    // Priority: state override > layout cellModes > per-cell config > default
    func buildCellModesAndRatios(
        cellIDs: [String],
        spaceID: String,
        layoutDef: GridLayoutDef
    ) async -> (modes: [String: GridStackMode], ratios: [String: [Double]]) {
        guard let gridState = gridState else {
            return ([:], [:])
        }

        var cellModes: [String: GridStackMode] = [:]
        var cellRatios: [String: [Double]] = [:]

        for cellID in cellIDs {
            // 1. Check per-cell StackMode in layout definition
            for cell in layoutDef.cells {
                if cell.id == cellID && cell.stackMode != nil {
                    cellModes[cellID] = cell.stackMode!
                    break
                }
            }
            // 2. Check layout's cellModes map (overrides per-cell)
            if let mode = layoutDef.cellModes[cellID] {
                cellModes[cellID] = mode
            }
            // 3. State override (highest priority)
            if let stateMode = await gridState.getCellStackMode(spaceID: spaceID, cellID: cellID) {
                cellModes[cellID] = stateMode
            }

            let ratios = await gridState.getCellSplitRatios(spaceID: spaceID, cellID: cellID)
            if !ratios.isEmpty {
                cellRatios[cellID] = ratios
            }
        }

        return (cellModes, cellRatios)
    }

    // applyPlacementsViaAX: position windows using WindowManipulator
    private func applyPlacementsViaAX(_ placements: [GridWindowPlacement]) async {
        if placements.isEmpty { return }

        await withTaskGroup(of: Void.self) { group in
            for placement in placements {
                group.addTask { [weak self] in
                    guard let context = await ManipulationContext.from(windowID: placement.windowID) else {
                        jlog("warn.placement", data: ["wid": placement.windowID, "reason": "no_context"])
                        return
                    }
                    guard let manipulator = self?.windowManipulator else { return }
                    let success = await manipulator.setWindowFrame(
                        context: context,
                        frame: placement.bounds
                    )
                    if !success {
                        jlog("warn.placement", data: ["wid": placement.windowID, "reason": "ax_fail"])
                    }
                }
            }
        }
    }

    // raiseNextWindowIfTabbed: raise the remaining visible window in source cell
    // after a window is moved out of a tabbed cell
    private func raiseNextWindowIfTabbed(
        sourceCell: String,
        spaceID: String,
        cellModes: [String: GridStackMode],
        defaultMode: GridStackMode
    ) async {
        let mode = cellModes[sourceCell] ?? defaultMode
        guard mode == .tabs else { return }

        guard let gridState = gridState else { return }
        let cellWindows = await gridState.getCellWindows(spaceID: spaceID, cellID: sourceCell)
        guard !cellWindows.isEmpty else { return }

        // Focus the last-focused window in the source cell
        let spaceState = await gridState.getSpaceReadOnly(spaceID)
        let cellState = spaceState?.cells[sourceCell]
        var nextIdx = 0
        if let cellState = cellState {
            if cellState.lastFocusedWid != 0 {
                for (i, wid) in cellWindows.enumerated() {
                    if wid == cellState.lastFocusedWid {
                        nextIdx = i
                        break
                    }
                }
            } else if cellState.lastFocusedIdx >= 0 && cellState.lastFocusedIdx < cellWindows.count {
                nextIdx = cellState.lastFocusedIdx
            }
        }

        // Raise via WindowManipulator focus (just AX raise, don't change grid focus)
        guard let context = await ManipulationContext.from(windowID: cellWindows[nextIdx]) else { return }
        let _ = windowManipulator?.focusWindow(pid: context.pid, windowID: cellWindows[nextIdx])
    }

    // findDisplayBounds: look up display bounds from wmState
    private func findDisplayBounds(_ displayUUID: String, from wmState: WindowManagerState) -> CGRect {
        for display in wmState.displays {
            if display.uuid == displayUUID {
                return display.visibleFrame ?? display.frame ?? .zero
            }
        }
        return .zero
    }

    // findDisplayName: look up display name from wmState
    private func findDisplayName(_ displayUUID: String, wmState: WindowManagerState) -> String {
        for display in wmState.displays {
            if display.uuid == displayUUID {
                return display.name ?? ""
            }
        }
        return ""
    }
}
