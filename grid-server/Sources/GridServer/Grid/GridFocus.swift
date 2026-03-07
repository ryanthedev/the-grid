import CoreGraphics
import Foundation

// MARK: - Focus Options

struct MoveFocusOpts: Sendable {
    var wrapAround: Bool = false
    var extend: Bool = false
    var warpMouse: Bool = false
}

// MARK: - Focus Errors

enum GridFocusError: Error, LocalizedError {
    case noLayout
    case noCellsWithWindows
    case noCellInDirection
    case noWindowsInCell(String)
    case windowNotFound(UInt32)
    case focusFailed(UInt32)
    case cannotDetermineDisplay
    case noDisplayInDirection
    case noLayoutOnSpace(String)
    case noDisplayBounds
    case noCellsOnAdjacentDisplay

    var errorDescription: String? {
        switch self {
        case .noLayout: return "no layout applied"
        case .noCellsWithWindows: return "no cells with windows"
        case .noCellInDirection: return "no cell in direction"
        case .noWindowsInCell(let id): return "no windows in cell \(id)"
        case .windowNotFound(let id): return "window \(id) not found"
        case .focusFailed(let id): return "focus failed for window \(id)"
        case .cannotDetermineDisplay: return "cannot determine current display"
        case .noDisplayInDirection: return "no display in direction"
        case .noLayoutOnSpace(let id): return "no layout on space \(id)"
        case .noDisplayBounds: return "no display bounds"
        case .noCellsOnAdjacentDisplay: return "no cells on adjacent display"
        }
    }
}

// MARK: - GridFocus

class GridFocus {

    // Dependencies (weak references, set via setup)
    private weak var gridState: GridState?
    private weak var gridConfig: GridConfig?
    private weak var stateManager: StateManager?
    private weak var windowManipulator: WindowManipulator?

    init() {}

    func setup(
        gridState: GridState,
        gridConfig: GridConfig,
        stateManager: StateManager,
        windowManipulator: WindowManipulator
    ) {
        self.gridState = gridState
        self.gridConfig = gridConfig
        self.stateManager = stateManager
        self.windowManipulator = windowManipulator
        jlog("focus.init")
    }

    // ============================================================
    // PUBLIC API (3 methods)
    // ============================================================

    // moveFocus: move focus to adjacent cell in direction
    func moveFocus(direction: GridDirection, opts: MoveFocusOpts) async throws -> UInt32 {
        guard let gridState = gridState,
              let gridConfig = gridConfig,
              let stateManager = stateManager else {
            throw GridFocusError.noLayout
        }

        // Get current OS state from StateManager
        let wmState = await stateManager.getState()
        guard let spaceID = findActiveSpaceID(wmState) else {
            throw GridFocusError.noLayout
        }

        // Get grid state for this space
        guard let spaceState = await gridState.getSpaceReadOnly(spaceID),
              !spaceState.currentLayoutId.isEmpty else {
            throw GridFocusError.noLayout
        }

        // Calculate layout bounds for current display
        let layoutDef = try await MainActor.run { try gridConfig.getLayout(id: spaceState.currentLayoutId) }
        let baseSpacing = await MainActor.run { gridConfig.getBaseSpacing() }
        let displayBounds = getDisplayBoundsForSpace(spaceID, wmState: wmState)
        let columnRatios = await gridState.getColumnRatios(spaceID: spaceID)
        let rowRatios = await gridState.getRowRatios(spaceID: spaceID)
        let calculated = GridLayout.calculateLayoutWithRatios(
            layout: layoutDef,
            screenRect: displayBounds,
            gap: baseSpacing,
            columnRatios: columnRatios,
            rowRatios: rowRatios
        )

        // Find current focused cell
        var currentCell = await gridState.getFocusedCell(spaceID: spaceID)
        if currentCell == nil {
            currentCell = findFirstCellWithWindows(spaceState)
        }
        guard let currentCell = currentCell else {
            throw GridFocusError.noCellsWithWindows
        }

        // Find adjacent cells on current display
        let adjacentMap = GridLayout.getAdjacentCells(cellID: currentCell, cellBounds: calculated.cellBounds)
        var candidates = adjacentMap[direction] ?? []

        if candidates.isEmpty {
            // Try cross-display if extend enabled
            if opts.extend {
                let windowID = try await moveFocusCrossDisplay(
                    direction: direction,
                    wmState: wmState,
                    spaceID: spaceID,
                    currentCell: currentCell,
                    currentCellBounds: calculated.cellBounds
                )
                if opts.warpMouse {
                    // Warp to the target cell on the target display
                    // Re-fetch state to get the new focused cell's bounds
                    let newSpaceID = findActiveSpaceIDAfterCrossDisplay(direction, wmState: wmState)
                    if let newSpaceID = newSpaceID {
                        let newFocusedCell = await gridState.getFocusedCell(spaceID: newSpaceID)
                        if let newFocusedCell = newFocusedCell {
                            let targetDisplay = findAdjacentOrOppositeDisplay(
                                currentDisplayUUID: findCurrentDisplayUUID(wmState, spaceID),
                                direction: direction,
                                displays: wmState.displays
                            )
                            if let targetDisplay = targetDisplay {
                                let (targetCellBounds, _) = try await getDisplayCells(targetDisplay)
                                warpMouseToCell(newFocusedCell, targetCellBounds)
                            }
                        }
                    }
                }
                return windowID
            }

            if !opts.wrapAround {
                throw GridFocusError.noCellInDirection
            }

            // Wrap: find cells on opposite edge
            candidates = findWrapTarget(direction: direction, currentCell: currentCell, cellBounds: calculated.cellBounds)
            if candidates.isEmpty {
                throw GridFocusError.noCellInDirection
            }
        }

        // Pick closest candidate by center distance
        let targetCell = pickClosestCell(currentCell: currentCell, candidates: candidates, cellBounds: calculated.cellBounds)

        // Focus the target cell (updates GridState, triggers AX focus)
        let windowID = try await focusCellByID(spaceID: spaceID, cellID: targetCell)

        // Warp mouse to focused window center if requested
        if opts.warpMouse {
            warpMouseToCell(targetCell, calculated.cellBounds)
        }

        return windowID
    }

    // cycleFocus: cycle to next/prev window within focused cell
    func cycleFocus(forward: Bool) async throws -> UInt32 {
        guard let gridState = gridState,
              let stateManager = stateManager else {
            throw GridFocusError.noLayout
        }

        // Get current space
        let wmState = await stateManager.getState()
        guard let spaceID = findActiveSpaceID(wmState) else {
            throw GridFocusError.noLayout
        }
        guard let spaceState = await gridState.getSpaceReadOnly(spaceID),
              !spaceState.currentLayoutId.isEmpty else {
            throw GridFocusError.noLayout
        }

        // Find focused cell
        var cellID = spaceState.focusedCell
        if cellID.isEmpty {
            guard let firstCell = findFirstCellWithWindows(spaceState) else {
                throw GridFocusError.noCellsWithWindows
            }
            cellID = firstCell
        }

        let cellWindows = await gridState.getCellWindows(spaceID: spaceID, cellID: cellID)
        guard !cellWindows.isEmpty else {
            throw GridFocusError.noWindowsInCell(cellID)
        }

        if cellWindows.count == 1 {
            // Only one window, just ensure it's focused
            let windowID = cellWindows[0]
            try await focusWindowByID(windowID)
            await gridState.setFocus(spaceID: spaceID, cellID: cellID, windowIndex: 0)
            return windowID
        }

        // Calculate next/prev index (wrapping)
        let currentIdx = spaceState.focusedWindow
        let clampedIdx = max(0, min(currentIdx, cellWindows.count - 1))
        let newIdx: Int
        if forward {
            newIdx = (clampedIdx + 1) % cellWindows.count
        } else {
            newIdx = (clampedIdx - 1 + cellWindows.count) % cellWindows.count
        }

        let windowID = cellWindows[newIdx]
        try await focusWindowByID(windowID)
        await gridState.setFocus(spaceID: spaceID, cellID: cellID, windowIndex: newIdx)

        return windowID
    }

    // focusCell: focus a specific cell by ID
    func focusCell(spaceID: String, cellID: String) async throws -> UInt32 {
        return try await focusCellByID(spaceID: spaceID, cellID: cellID)
    }

    // ============================================================
    // PRIVATE: Core focus mechanics
    // ============================================================

    // focusCellByID: focus a cell, restoring last-focused window
    private func focusCellByID(spaceID: String, cellID: String) async throws -> UInt32 {
        guard let gridState = gridState else {
            throw GridFocusError.noLayout
        }

        let cellWindows = await gridState.getCellWindows(spaceID: spaceID, cellID: cellID)
        guard !cellWindows.isEmpty else {
            throw GridFocusError.noWindowsInCell(cellID)
        }

        // Determine which window to focus
        // Priority: lastFocusedWid > lastFocusedIdx > first window
        let spaceState = await gridState.getSpaceReadOnly(spaceID)
        let cellState = spaceState?.cells[cellID]

        var idx = 0
        if let cellState = cellState {
            // Try lastFocusedWid first (stable across reorders)
            if cellState.lastFocusedWid != 0 {
                if let foundIdx = cellWindows.firstIndex(of: cellState.lastFocusedWid) {
                    idx = foundIdx
                }
            } else {
                // Fall back to lastFocusedIdx
                idx = max(0, min(cellState.lastFocusedIdx, cellWindows.count - 1))
            }
        }

        let windowID = cellWindows[idx]

        // Do the AX focus
        try await focusWindowByID(windowID)

        // Update GridState focus tracking
        await gridState.setFocus(spaceID: spaceID, cellID: cellID, windowIndex: idx)

        return windowID
    }

    // focusWindowByID: focus a window via WindowManipulator
    private func focusWindowByID(_ windowID: UInt32) async throws {
        guard let stateManager = stateManager,
              let windowManipulator = windowManipulator else {
            throw GridFocusError.windowNotFound(windowID)
        }

        // Look up window PID from StateManager
        let wmState = await stateManager.getState()
        guard let windowState = wmState.windows[String(windowID)] else {
            throw GridFocusError.windowNotFound(windowID)
        }

        // Call WindowManipulator directly (no RPC)
        let success = windowManipulator.focusWindow(pid: windowState.pid, windowID: windowID)
        if !success {
            throw GridFocusError.focusFailed(windowID)
        }
    }

    // ============================================================
    // PRIVATE: Cross-display focus
    // ============================================================

    // moveFocusCrossDisplay: handle focus movement to adjacent display
    private func moveFocusCrossDisplay(
        direction: GridDirection,
        wmState: WindowManagerState,
        spaceID: String,
        currentCell: String,
        currentCellBounds: [String: CGRect]
    ) async throws -> UInt32 {
        guard let gridState = gridState else {
            throw GridFocusError.noLayout
        }

        // Find current display UUID
        let currentDisplayUUID = findCurrentDisplayUUID(wmState, spaceID)
        guard !currentDisplayUUID.isEmpty else {
            throw GridFocusError.cannotDetermineDisplay
        }

        // Find adjacent display in direction
        var adjacentDisplay = findAdjacentDisplay(
            currentDisplayUUID: currentDisplayUUID,
            direction: direction,
            displays: wmState.displays
        )
        if adjacentDisplay == nil {
            // Try opposite display for wrap-around
            adjacentDisplay = findOppositeDisplay(
                currentDisplayUUID: currentDisplayUUID,
                direction: direction,
                displays: wmState.displays
            )
        }
        guard let adjacentDisplay = adjacentDisplay else {
            throw GridFocusError.noDisplayInDirection
        }

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
            targetSpaceState: targetSpaceState,
            targetCellBounds: targetCellBounds,
            currentCellBounds: currentBounds,
            currentDisplayBounds: currentDisplayBounds,
            targetDisplayBounds: targetDisplayBounds
        )
        guard !targetCell.isEmpty else {
            throw GridFocusError.noCellsOnAdjacentDisplay
        }

        // Focus the cell on the target space
        let windowID = try await focusCellByID(spaceID: targetSpaceIDStr, cellID: targetCell)

        // NOTE: Border sync handled automatically by GridReconciler's focusChanged handler

        return windowID
    }

    // ============================================================
    // PRIVATE: Display adjacency
    // ============================================================

    // findAdjacentDisplay: find display adjacent in direction
    private func findAdjacentDisplay(
        currentDisplayUUID: String,
        direction: GridDirection,
        displays: [DisplayState]
    ) -> DisplayState? {
        let edgeTolerance = 5.0

        // Find current display
        guard let currentDisplay = displays.first(where: { $0.uuid == currentDisplayUUID }),
              let currentFrame = currentDisplay.visibleFrame ?? currentDisplay.frame else {
            return nil
        }

        // Collect candidate displays with their edge distances
        var candidates: [(display: DisplayState, edgeDist: Double)] = []

        for display in displays {
            if display.uuid == currentDisplayUUID { continue }
            guard let candidateFrame = display.visibleFrame ?? display.frame else { continue }

            switch direction {
            case .left:
                let edgeDist = currentFrame.minX - candidateFrame.maxX
                if currentFrame.overlapsVertically(with: candidateFrame)
                    && edgeDist > -edgeTolerance {
                    candidates.append((display, edgeDist))
                }
            case .right:
                let edgeDist = candidateFrame.minX - currentFrame.maxX
                if currentFrame.overlapsVertically(with: candidateFrame)
                    && edgeDist > -edgeTolerance {
                    candidates.append((display, edgeDist))
                }
            case .up:
                let edgeDist = currentFrame.minY - candidateFrame.maxY
                if currentFrame.overlapsHorizontally(with: candidateFrame)
                    && edgeDist > -edgeTolerance {
                    candidates.append((display, edgeDist))
                }
            case .down:
                let edgeDist = candidateFrame.minY - currentFrame.maxY
                if currentFrame.overlapsHorizontally(with: candidateFrame)
                    && edgeDist > -edgeTolerance {
                    candidates.append((display, edgeDist))
                }
            }
        }

        if candidates.isEmpty { return nil }

        // Sort by absolute edge distance (closest first), UUID tiebreaker
        candidates.sort { a, b in
            let distA = abs(a.edgeDist)
            let distB = abs(b.edgeDist)
            if distA != distB { return distA < distB }
            return a.display.uuid < b.display.uuid
        }

        return candidates[0].display
    }

    // findOppositeDisplay: find display on opposite edge for wrap-around
    private func findOppositeDisplay(
        currentDisplayUUID: String,
        direction: GridDirection,
        displays: [DisplayState]
    ) -> DisplayState? {
        guard displays.count >= 2 else { return nil }
        guard let currentDisplay = displays.first(where: { $0.uuid == currentDisplayUUID }),
              let currentFrame = currentDisplay.visibleFrame ?? currentDisplay.frame else {
            return nil
        }

        var candidate: DisplayState? = nil
        var candidateValue: Double = 0

        for display in displays {
            if display.uuid == currentDisplayUUID { continue }
            guard let frame = display.visibleFrame ?? display.frame else { continue }

            switch direction {
            case .left:
                // Wrap left -> find rightmost display overlapping vertically
                if currentFrame.overlapsVertically(with: frame) {
                    let rightEdge = frame.maxX
                    if candidate == nil || rightEdge > candidateValue {
                        candidate = display
                        candidateValue = rightEdge
                    }
                }
            case .right:
                // Wrap right -> find leftmost display overlapping vertically
                if currentFrame.overlapsVertically(with: frame) {
                    if candidate == nil || frame.minX < candidateValue {
                        candidate = display
                        candidateValue = frame.minX
                    }
                }
            case .up:
                // Wrap up -> find bottommost display overlapping horizontally
                if currentFrame.overlapsHorizontally(with: frame) {
                    let bottomEdge = frame.maxY
                    if candidate == nil || bottomEdge > candidateValue {
                        candidate = display
                        candidateValue = bottomEdge
                    }
                }
            case .down:
                // Wrap down -> find topmost display overlapping horizontally
                if currentFrame.overlapsHorizontally(with: frame) {
                    if candidate == nil || frame.minY < candidateValue {
                        candidate = display
                        candidateValue = frame.minY
                    }
                }
            }
        }

        return candidate
    }

    // ============================================================
    // PRIVATE: Cell selection helpers
    // ============================================================

    // findWrapTarget: find cells on opposite edge for wrap within display
    private func findWrapTarget(
        direction: GridDirection,
        currentCell: String,
        cellBounds: [String: CGRect]
    ) -> [String] {
        guard let current = cellBounds[currentCell] else { return [] }

        // Collect all cells that overlap in perpendicular axis (excluding current)
        var candidates: [String] = []
        for (cellID, bounds) in cellBounds where cellID != currentCell {
            switch direction {
            case .left, .right:
                if current.overlapsVertically(with: bounds) {
                    candidates.append(cellID)
                }
            case .up, .down:
                if current.overlapsHorizontally(with: bounds) {
                    candidates.append(cellID)
                }
            }
        }

        if candidates.isEmpty { return [] }

        // Filter to only cells at the extreme opposite edge
        switch direction {
        case .left:
            // Wrap left: keep only the rightmost cells
            let maxVal = candidates.compactMap { cellBounds[$0]?.maxX }.max() ?? 0
            candidates = candidates.filter { cellBounds[$0]?.maxX == maxVal }
        case .right:
            // Wrap right: keep only the leftmost cells
            let minVal = candidates.compactMap { cellBounds[$0]?.minX }.min() ?? 0
            candidates = candidates.filter { cellBounds[$0]?.minX == minVal }
        case .up:
            // Wrap up: keep only the bottommost cells
            let maxVal = candidates.compactMap { cellBounds[$0]?.maxY }.max() ?? 0
            candidates = candidates.filter { cellBounds[$0]?.maxY == maxVal }
        case .down:
            // Wrap down: keep only the topmost cells
            let minVal = candidates.compactMap { cellBounds[$0]?.minY }.min() ?? 0
            candidates = candidates.filter { cellBounds[$0]?.minY == minVal }
        }

        return candidates
    }

    // pickClosestCell: pick cell closest to current cell's center
    private func pickClosestCell(
        currentCell: String,
        candidates: [String],
        cellBounds: [String: CGRect]
    ) -> String {
        if candidates.count <= 1 { return candidates.first ?? "" }

        guard let currentBounds = cellBounds[currentCell] else { return candidates[0] }
        let currentCenter = currentBounds.center

        var closest = candidates[0]
        var closestDist = Double.greatestFiniteMagnitude

        for cellID in candidates {
            guard let bounds = cellBounds[cellID] else { continue }
            let center = bounds.center
            let dx = center.x - currentCenter.x
            let dy = center.y - currentCenter.y
            let dist = sqrt(dx * dx + dy * dy)
            if dist < closestDist || (dist == closestDist && cellID < closest) {
                closestDist = dist
                closest = cellID
            }
        }

        return closest
    }

    // matchVisualPosition: map position from source to target display
    private func matchVisualPosition(
        sourceCell: CGRect,
        sourceDisplay: CGRect,
        targetDisplay: CGRect
    ) -> CGPoint {
        let cellCenter = sourceCell.center
        let normX = sourceDisplay.width > 0
            ? (cellCenter.x - sourceDisplay.minX) / sourceDisplay.width
            : 0.5
        let normY = sourceDisplay.height > 0
            ? (cellCenter.y - sourceDisplay.minY) / sourceDisplay.height
            : 0.5
        let targetX = targetDisplay.minX + normX * targetDisplay.width
        let targetY = targetDisplay.minY + normY * targetDisplay.height
        return CGPoint(x: targetX, y: targetY)
    }

    // findClosestCellToPoint: find cell whose center is closest to point
    private func findClosestCellToPoint(
        point: CGPoint,
        cellBounds: [String: CGRect]
    ) -> String {
        if cellBounds.isEmpty { return "" }

        var closestCell = ""
        var closestDist = Double.greatestFiniteMagnitude

        for (cellID, bounds) in cellBounds {
            let center = bounds.center
            let dx = center.x - point.x
            let dy = center.y - point.y
            let dist = sqrt(dx * dx + dy * dy)
            if dist < closestDist || (dist == closestDist && cellID < closestCell) {
                closestDist = dist
                closestCell = cellID
            }
        }

        return closestCell
    }

    // selectCrossDisplayTargetCell: choose cell when crossing displays
    private func selectCrossDisplayTargetCell(
        targetSpaceState: GridSpaceStateData?,
        targetCellBounds: [String: CGRect],
        currentCellBounds: CGRect,
        currentDisplayBounds: CGRect,
        targetDisplayBounds: CGRect
    ) -> String {
        // Check if target space has a previously focused cell with windows
        if let targetSpace = targetSpaceState,
           !targetSpace.focusedCell.isEmpty,
           targetCellBounds[targetSpace.focusedCell] != nil,
           let cellState = targetSpace.cells[targetSpace.focusedCell],
           !cellState.windows.isEmpty {
            return targetSpace.focusedCell
        }

        // Fall back to closest cell WITH WINDOWS based on visual position mapping
        let targetPoint = matchVisualPosition(
            sourceCell: currentCellBounds,
            sourceDisplay: currentDisplayBounds,
            targetDisplay: targetDisplayBounds
        )

        // Filter to only cells with windows on target space
        var cellsWithWindows: [String: CGRect] = [:]
        if let targetSpace = targetSpaceState {
            for (cellID, bounds) in targetCellBounds {
                if let cellState = targetSpace.cells[cellID], !cellState.windows.isEmpty {
                    cellsWithWindows[cellID] = bounds
                }
            }
        }

        if !cellsWithWindows.isEmpty {
            return findClosestCellToPoint(point: targetPoint, cellBounds: cellsWithWindows)
        }

        // No cells with windows
        return ""
    }

    // ============================================================
    // PRIVATE: Display/space helpers
    // ============================================================

    // getDisplayCells: calculate cell bounds for a display's active space
    private func getDisplayCells(
        _ display: DisplayState
    ) async throws -> (cellBounds: [String: CGRect], spaceID: UInt64) {
        guard let gridState = gridState,
              let gridConfig = gridConfig else {
            throw GridFocusError.noLayout
        }

        let spaceID = display.currentSpaceID
        let spaceIDStr = String(spaceID)

        let layoutID = await gridState.getCurrentLayout(spaceID: spaceIDStr)
        guard !layoutID.isEmpty else {
            throw GridFocusError.noLayoutOnSpace(spaceIDStr)
        }

        let layoutDef = try await MainActor.run { try gridConfig.getLayout(id: layoutID) }
        let baseSpacing = await MainActor.run { gridConfig.getBaseSpacing() }

        guard let displayBounds = display.visibleFrame ?? display.frame else {
            throw GridFocusError.noDisplayBounds
        }

        let columnRatios = await gridState.getColumnRatios(spaceID: spaceIDStr)
        let rowRatios = await gridState.getRowRatios(spaceID: spaceIDStr)

        let calculated = GridLayout.calculateLayoutWithRatios(
            layout: layoutDef,
            screenRect: displayBounds,
            gap: baseSpacing,
            columnRatios: columnRatios,
            rowRatios: rowRatios
        )

        return (calculated.cellBounds, spaceID)
    }

    // findCurrentDisplayUUID: determine current display from space state
    private func findCurrentDisplayUUID(
        _ wmState: WindowManagerState,
        _ spaceID: String
    ) -> String {
        // Match space ID to display via active space
        for display in wmState.displays {
            if String(display.currentSpaceID) == spaceID {
                return display.uuid
            }
        }
        return ""
    }

    // getDisplayBounds: get visible frame for a display UUID
    private func getDisplayBounds(
        _ displayUUID: String,
        _ displays: [DisplayState]
    ) -> CGRect {
        for display in displays {
            if display.uuid == displayUUID {
                return display.visibleFrame ?? display.frame ?? .zero
            }
        }
        return .zero
    }

    // getDisplayBoundsForSpace: get display bounds for a space ID
    private func getDisplayBoundsForSpace(
        _ spaceID: String,
        wmState: WindowManagerState
    ) -> CGRect {
        let uuid = findCurrentDisplayUUID(wmState, spaceID)
        if uuid.isEmpty { return .zero }
        return getDisplayBounds(uuid, wmState.displays)
    }

    // findFirstCellWithWindows: deterministic first cell with windows
    private func findFirstCellWithWindows(
        _ spaceState: GridSpaceStateData
    ) -> String? {
        let sortedCellIDs = spaceState.cells.keys.sorted()
        for cellID in sortedCellIDs {
            if let cell = spaceState.cells[cellID], !cell.windows.isEmpty {
                return cellID
            }
        }
        return nil
    }

    // findActiveSpaceID: find the active space from WindowManagerState
    private func findActiveSpaceID(
        _ wmState: WindowManagerState
    ) -> String? {
        for (spaceKey, space) in wmState.spaces {
            if space.isActive {
                return spaceKey
            }
        }
        return nil
    }

    // warpMouseToCell: move cursor to center of cell bounds
    private func warpMouseToCell(
        _ cellID: String,
        _ cellBounds: [String: CGRect]
    ) {
        guard let bounds = cellBounds[cellID] else { return }
        let center = bounds.center
        CGWarpMouseCursorPosition(center)
    }

    // findActiveSpaceIDAfterCrossDisplay: find the target space for cross-display
    private func findActiveSpaceIDAfterCrossDisplay(
        _ direction: GridDirection,
        wmState: WindowManagerState
    ) -> String? {
        // After cross-display focus, the target space might not be "active" yet
        // from wmState perspective. Look for the display in direction and return its space.
        guard let activeSpaceID = findActiveSpaceID(wmState) else { return nil }
        let currentUUID = findCurrentDisplayUUID(wmState, activeSpaceID)
        guard !currentUUID.isEmpty else { return nil }

        let targetDisplay = findAdjacentOrOppositeDisplay(
            currentDisplayUUID: currentUUID,
            direction: direction,
            displays: wmState.displays
        )
        guard let targetDisplay = targetDisplay else { return nil }
        return String(targetDisplay.currentSpaceID)
    }

    // findAdjacentOrOppositeDisplay: helper combining adjacent + opposite lookup
    private func findAdjacentOrOppositeDisplay(
        currentDisplayUUID: String,
        direction: GridDirection,
        displays: [DisplayState]
    ) -> DisplayState? {
        if let adj = findAdjacentDisplay(
            currentDisplayUUID: currentDisplayUUID,
            direction: direction,
            displays: displays
        ) {
            return adj
        }
        return findOppositeDisplay(
            currentDisplayUUID: currentDisplayUUID,
            direction: direction,
            displays: displays
        )
    }
}
