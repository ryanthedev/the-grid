import AppKit
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
    var warpMouse: Bool = false
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
    case windowMoveFailed(UInt32)

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
        case .windowMoveFailed(let id): return "moveWindowToSpace failed for window \(id)"
        }
    }
}

// MARK: - GridWindowMove helpers

extension GridWindowMove {
    // shouldAbortCrossDisplayMove: pure predicate that decides whether to abort
    // a cross-display move when the SLS move call returns false. Extracted for
    // unit testability independent of the AX boundary.
    static func shouldAbortCrossDisplayMove(moved: Bool) -> Bool {
        return !moved
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

    // Track last-moved window to prevent rapid moves from picking up
    // the wrong window due to delayed OS focus events
    private var lastMovedWindowID: UInt32 = 0
    private var lastMoveTime: CFAbsoluteTime = 0
    private let rapidMoveThreshold: CFAbsoluteTime = 1.0

    // Save focusedCell before cross-display move overwrites it,
    // so it can be restored when the window leaves that space
    private var savedFocusedCells: [String: String] = [:]

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
        let moveStart = CFAbsoluteTimeGetCurrent()
        guard let gridState = gridState,
              let gridConfig = gridConfig,
              let stateManager = stateManager,
              let gridFocus = gridFocus else {
            throw GridWindowMoveError.noLayout
        }

        // 1. Get space state
        let wmState = await stateManager.getState()
        let setupStateMs = Int((CFAbsoluteTimeGetCurrent() - moveStart) * 1000)
        guard let activeSpaceID = gridFocus.findActiveSpaceID(wmState) else {
            throw GridWindowMoveError.noLayout
        }
        // 2. Determine which window to move
        // On rapid moves (< 1s), prefer the last-moved window because
        // delayed OS focus events may have changed getFocusedWindow.
        // Also fix spaceID if the window crossed displays (metadata may be stale).
        var spaceID = activeSpaceID
        let windowID: UInt32
        if opts.windowID != 0 {
            windowID = opts.windowID
        } else {
            let now = CFAbsoluteTimeGetCurrent()
            let isRapidMove = lastMovedWindowID != 0
                && (now - lastMoveTime) < rapidMoveThreshold
            if isRapidMove {
                // Find the window's actual space (may differ from activeSpaceID
                // after a cross-display move where metadata hasn't caught up)
                if let actualSpace = await gridState.findSpaceContaining(windowID: lastMovedWindowID) {
                    spaceID = actualSpace
                    windowID = lastMovedWindowID
                } else {
                    windowID = await gridState.getFocusedWindow(spaceID: spaceID)
                }
            } else {
                windowID = await gridState.getFocusedWindow(spaceID: spaceID)
            }
        }
        guard windowID != 0 else {
            throw GridWindowMoveError.noFocusedWindow
        }

        // 3. Get space state (re-fetch in case rapid-move corrected spaceID)
        guard let spaceState = await gridState.getSpaceReadOnly(spaceID),
              !spaceState.currentLayoutId.isEmpty else {
            throw GridWindowMoveError.noLayout
        }

        // 4. Find source cell
        let sourceCell = await gridState.getWindowCell(windowID: windowID, inSpace: spaceID)
        guard let sourceCell = sourceCell else {
            throw GridWindowMoveError.windowNotInCell(windowID)
        }

        // 5. Calculate layout and find adjacent cells
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
        let setupMs = Int((CFAbsoluteTimeGetCurrent() - moveStart) * 1000)
        if candidates.isEmpty {
            // Try cross-display if extend enabled
            if opts.extend {
                jlog("winmove.setup", data: [
                    "dir": direction.rawValue,
                    "setup_ms": setupMs,
                    "state_ms": setupStateMs,
                    "cross": true,
                ])
                let result = try await moveWindowCrossDisplay(
                    direction: direction,
                    windowID: windowID,
                    sourceCell: sourceCell,
                    currentCellBounds: calculated.cellBounds,
                    wmState: wmState,
                    spaceID: spaceID,
                    warpMouse: opts.warpMouse
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
            wmState: wmState,
            warpMouse: opts.warpMouse
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
        wmState: WindowManagerState,
        warpMouse: Bool = false
    ) async throws -> GridMoveResult {
        guard let gridState = gridState,
              let gridConfig = gridConfig,
              let gridFocus = gridFocus,
              let gridReconciler = gridReconciler else {
            throw GridWindowMoveError.noLayout
        }

        // Fence the moved window before any state mutation
        let fencedIDs: Set<UInt32> = [windowID]
        gridReconciler.acquireFence(windowIDs: fencedIDs, reason: "move.same")

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

        // 6. Batch all config reads into single MainActor hop
        let displayUUID = gridFocus.findCurrentDisplayUUID(wmState, spaceID)
        let displayName = findDisplayName(displayUUID, wmState: wmState)
        let (baseSpacing, settingsPadding, settingsWindowSpacing, defaultMode, offset) = await MainActor.run {
            (gridConfig.getBaseSpacing(),
             gridConfig.getSettingsPadding(),
             gridConfig.getSettingsWindowSpacing(),
             gridConfig.settings.defaultStackMode,
             gridConfig.getDisplayOffset(uuid: displayUUID, name: displayName))
        }

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

        // 9. Skip tab raise for same-display moves — repositioning the moved
        // window via AX reveals the underlying window naturally. Calling
        // focusWindow on the remaining window activates its app, causing a
        // visible flash (e.g. Messages appearing briefly) before we refocus
        // the moved window.

        // 10. Focus the moved window
        try await gridFocus.focusWindowByID(windowID)

        // 10b. Warp mouse cursor to target cell center
        if warpMouse, let targetBounds = calculated.cellBounds[targetCell] {
            CGWarpMouseCursorPosition(CGPoint(x: targetBounds.midX, y: targetBounds.midY))
        }

        // 11. Await border sync (fenced: OS events for this window are blocked)
        let displayUUIDForBorders = gridFocus.findCurrentDisplayUUID(wmState, spaceID)
        await gridReconciler.syncBordersForSpace(spaceID, displayUUID: displayUUIDForBorders)

        // Release fence after border sync completes
        gridReconciler.releaseFence(windowIDs: fencedIDs)

        // Track for rapid-move detection
        lastMovedWindowID = windowID
        lastMoveTime = CFAbsoluteTimeGetCurrent()

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
        spaceID: String,
        warpMouse: Bool = false
    ) async throws -> GridMoveResult {
        let t0 = CFAbsoluteTimeGetCurrent()
        guard let gridState = gridState,
              let _ = gridConfig,
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
        let t1 = CFAbsoluteTimeGetCurrent()
        let (targetCellBounds, targetSpaceID) = try await gridFocus.getDisplayCells(adjacentDisplay)
        let targetSpaceIDStr = String(targetSpaceID)
        let t2 = CFAbsoluteTimeGetCurrent()

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

        // 6. Fence the moved window before SLS move and state mutation
        let fencedIDs: Set<UInt32> = [windowID]
        gridReconciler.acquireFence(windowIDs: fencedIDs, reason: "move.cross")

        // 6b. Move window to target space via WindowManipulator.
        // Abort and release the fence when the SLS move fails — GridState must
        // not be mutated for a move that the OS did not honor (#16).
        let t3 = CFAbsoluteTimeGetCurrent()
        let moved = windowManipulator.moveWindowToSpace(windowID: windowID, spaceID: targetSpaceID)
        let t4 = CFAbsoluteTimeGetCurrent()

        if GridWindowMove.shouldAbortCrossDisplayMove(moved: moved) {
            gridReconciler.releaseFence(windowIDs: fencedIDs)
            jlog("err.move.cross_display", data: [
                "wid": Int(windowID),
                "targetSpace": String(targetSpaceID),
                "reason": "moveWindowToSpace.failed",
            ])
            throw GridWindowMoveError.windowMoveFailed(windowID)
        }

        // 7. Update state on both source and target spaces
        await gridState.removeWindow(windowID, fromSpace: spaceID)

        // Restore source space's focusedCell if it was saved during a previous
        // cross-display move (prevents stale focusedCell after window bounces back)
        if let saved = savedFocusedCells.removeValue(forKey: spaceID) {
            let sourceState = await gridState.getSpaceReadOnly(spaceID)
            if let ss = sourceState, let cellState = ss.cells[saved], !cellState.windows.isEmpty {
                await gridState.setFocus(spaceID: spaceID, cellID: saved, windowIndex: cellState.lastFocusedIdx)
            }
        }

        // Save target space's focusedCell before overwriting (only first time)
        if savedFocusedCells[targetSpaceIDStr] == nil {
            let prevFocused = await gridState.getFocusedCell(spaceID: targetSpaceIDStr)
            if let prev = prevFocused, !prev.isEmpty {
                savedFocusedCells[targetSpaceIDStr] = prev
            }
        }

        await gridState.prependWindow(windowID, toCellID: targetCell, inSpace: targetSpaceIDStr)
        await gridState.setFocus(spaceID: targetSpaceIDStr, cellID: targetCell, windowIndex: 0)
        let t5 = CFAbsoluteTimeGetCurrent()

        // 8. (Fence acquired above at step 6 -- replaces beginMove)

        // 9. Apply layouts on target and source displays in parallel
        let sourceCellWindows = await gridState.getCellWindows(spaceID: spaceID, cellID: sourceCell)
        let sourceDisplayName = findDisplayName(currentDisplayUUID, wmState: wmState)

        await withTaskGroup(of: Void.self) { group in
            group.addTask { [self] in
                await applyPartialLayout(
                    spaceID: targetSpaceIDStr,
                    cellIDs: [targetCell],
                    displayBounds: targetDisplayBounds,
                    displayUUID: adjacentDisplay.uuid,
                    displayName: adjacentDisplay.name ?? ""
                )
            }
            if !sourceCellWindows.isEmpty {
                group.addTask { [self] in
                    await applyPartialLayout(
                        spaceID: spaceID,
                        cellIDs: [sourceCell],
                        displayBounds: currentDisplayBounds,
                        displayUUID: currentDisplayUUID,
                        displayName: sourceDisplayName
                    )
                }
            }
        }
        let t6 = CFAbsoluteTimeGetCurrent()

        // 10. Skip tab raise for cross-display moves — we're leaving the source
        // display entirely, and raising a window there fires a spurious OS focus
        // event that races with our focusWindowByID on rapid repeated moves.
        let t7 = CFAbsoluteTimeGetCurrent()

        // 11. Focus the moved window (do this LAST so it's the final focus state)
        try await gridFocus.focusWindowByID(windowID)
        // Tell StateManager the target space is now active so subsequent
        // focus/move commands don't use stale metadata from delayed OS events
        await stateManager?.overrideActiveSpace(targetSpaceID)
        let t8 = CFAbsoluteTimeGetCurrent()

        // 11b. Warp mouse cursor to target cell center on target display
        if warpMouse, let targetBounds = targetCellBounds[targetCell] {
            CGWarpMouseCursorPosition(CGPoint(x: targetBounds.midX, y: targetBounds.midY))
        }

        // 12. Sync borders while fenced (no race with OS events).
        // Source FIRST, target LAST -- SimpleBorderManager dispatches to main
        // queue async, so the last setCellAssignments wins the global focus.
        await gridReconciler.syncBordersForSpace(spaceID, displayUUID: currentDisplayUUID)
        await gridReconciler.syncBordersForSpace(targetSpaceIDStr, displayUUID: adjacentDisplay.uuid)

        // Release fence after both border syncs complete
        gridReconciler.releaseFence(windowIDs: fencedIDs)

        let tTotal = CFAbsoluteTimeGetCurrent()
        jlog("winmove.cross.timing", data: [
            "wid": windowID,
            "dir": direction.rawValue,
            "total_ms": Int((tTotal - t0) * 1000),
            "find_adj_ms": Int((t1 - t0) * 1000),
            "get_cells_ms": Int((t2 - t1) * 1000),
            "sls_move_ms": Int((t4 - t3) * 1000),
            "state_update_ms": Int((t5 - t4) * 1000),
            "apply_layout_ms": Int((t6 - t5) * 1000),
            "tab_raise_ms": Int((t7 - t6) * 1000),
            "focus_ms": Int((t8 - t7) * 1000),
        ])

        // Track for rapid-move detection
        lastMovedWindowID = windowID
        lastMoveTime = CFAbsoluteTimeGetCurrent()

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

        // Batch all MainActor config reads into a single hop
        struct ConfigSnapshot: Sendable {
            let layoutDef: GridLayoutDef?
            let baseSpacing: Double
            let padding: GridPadding?
            let windowSpacing: GridPaddingValue?
            let defaultMode: GridStackMode
            let offset: GridDisplayOffset
        }
        let config = await MainActor.run {
            ConfigSnapshot(
                layoutDef: try? gridConfig.getLayout(id: layoutID),
                baseSpacing: gridConfig.getBaseSpacing(),
                padding: gridConfig.getSettingsPadding(),
                windowSpacing: gridConfig.getSettingsWindowSpacing(),
                defaultMode: gridConfig.settings.defaultStackMode,
                offset: gridConfig.getDisplayOffset(uuid: displayUUID, name: displayName)
            )
        }
        guard let layoutDef = config.layoutDef else { return }

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

        var placements = GridLayout.calculateAllWindowPlacements(
            calculatedLayout: calculated,
            layout: layoutDef,
            assignments: assignments,
            cellModes: cellModes,
            cellRatios: cellRatios,
            defaultMode: config.defaultMode,
            baseSpacing: config.baseSpacing,
            settingsPadding: config.padding,
            settingsWindowSpacing: config.windowSpacing
        )

        if config.offset.x != 0 || config.offset.y != 0 {
            for i in 0..<placements.count {
                placements[i] = GridWindowPlacement(
                    windowID: placements[i].windowID,
                    bounds: placements[i].bounds.offsetBy(dx: config.offset.x, dy: config.offset.y)
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

        let serverPID = ProcessInfo.processInfo.processIdentifier

        await withTaskGroup(of: Void.self) { group in
            for placement in placements {
                group.addTask { [weak self] in
                    guard let context = await ManipulationContext.from(windowID: placement.windowID) else {
                        jlog("warn.placement", data: ["wid": placement.windowID, "reason": "no_context"])
                        return
                    }

                    // Own-process window: use NSWindow.setFrame on MainActor
                    if context.pid == serverPID {
                        let bounds = placement.bounds
                        await MainActor.run {
                            guard let nsWindow = NSApp.windows.first(where: { $0.windowNumber == Int(placement.windowID) }) else { return }
                            let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
                            let flippedY = primaryHeight - bounds.origin.y - bounds.height
                            nsWindow.setFrame(NSRect(x: bounds.origin.x, y: flippedY, width: bounds.width, height: bounds.height), display: true)
                        }
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
