import AppKit
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
    private weak var stateProvider: (any StateProvider)?
    private weak var windowManipulator: WindowManipulator?
    private weak var gridReconciler: GridReconciler?

    // Concrete StateManager ref for overrideActiveSpace (not on StateProvider).
    // Used only by cross-display focus navigation.
    private weak var stateManagerForOverride: StateManager?

    // Tracks recent focus-mismatch pairs to detect ping-pong loops across
    // repeated focusWindowByID calls. Bails to accept-OS-reality when the
    // same (requested, actual) pair flips >3 times within 2s.
    private var focusLoopDetector = FocusLoopDetector()

    init() {}

    func setup(
        gridState: GridState,
        gridConfig: GridConfig,
        stateProvider: any StateProvider,
        windowManipulator: WindowManipulator,
        stateManagerForOverride: StateManager? = nil
    ) {
        self.gridState = gridState
        self.gridConfig = gridConfig
        self.stateProvider = stateProvider
        self.windowManipulator = windowManipulator
        self.stateManagerForOverride = stateManagerForOverride
        jlog("focus.init")
    }

    // Set reconciler after creation (circular dependency resolution)
    func setReconciler(_ reconciler: GridReconciler) {
        self.gridReconciler = reconciler
    }

    // ============================================================
    // PUBLIC API (3 methods)
    // ============================================================

    // moveFocus: move focus to adjacent cell in direction
    func moveFocus(direction: GridDirection, opts: MoveFocusOpts) async throws -> UInt32 {
        guard let gridState = gridState,
              let gridConfig = gridConfig,
              let stateProvider = stateProvider else {
            throw GridFocusError.noLayout
        }

        // Get current OS state from StateManager
        let wmState = await stateProvider.getState()
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

        jlog("focus.move", data: [
            "dir": direction.rawValue,
            "cell": currentCell,
            "candidates": candidates.count,
            "allCells": calculated.cellBounds.count
        ])

        if candidates.isEmpty {
            // Try cross-display first
            do {
                let windowID = try await moveFocusCrossDisplay(
                    direction: direction,
                    wmState: wmState,
                    spaceID: spaceID,
                    currentCell: currentCell,
                    currentCellBounds: calculated.cellBounds
                )
                if opts.warpMouse {
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
            } catch {
                // Cross-display failed — fall through to wrap-around
            }

            // Wrap: find cells on opposite edge of current display
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
              let stateProvider = stateProvider else {
            throw GridFocusError.noLayout
        }

        // Get current space
        let wmState = await stateProvider.getState()
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

        var cellWindows = await gridState.getCellWindows(spaceID: spaceID, cellID: cellID)

        // Prune dead windows (closed but not yet cleaned up from GridState)
        var pruned = false
        cellWindows = cellWindows.filter { wid in
            if wmState.windows[String(wid)] != nil { return true }
            Task { await gridState.removeWindow(wid, fromSpace: spaceID) }
            jlog("focus.prune", data: ["wid": wid, "cell": cellID])
            pruned = true
            return false
        }

        guard !cellWindows.isEmpty else {
            throw GridFocusError.noWindowsInCell(cellID)
        }

        if cellWindows.count == 1 {
            let windowID = cellWindows[0]
            try await focusWindowByID(windowID)
            await gridState.setFocus(spaceID: spaceID, cellID: cellID, windowIndex: 0)
            return windowID
        }

        // Calculate next/prev index (wrapping), skipping unfocusable windows.
        // Some windows (e.g. zero-size Messages helpers) pass isTileable but
        // the OS refuses to focus them, causing an infinite mismatch loop.
        let startIdx = pruned ? 0 : max(0, min(spaceState.focusedWindow, cellWindows.count - 1))
        var tryIdx = startIdx

        for _ in 0..<cellWindows.count {
            if forward {
                tryIdx = (tryIdx + 1) % cellWindows.count
            } else {
                tryIdx = (tryIdx - 1 + cellWindows.count) % cellWindows.count
            }

            let windowID = cellWindows[tryIdx]
            let actualFocused = try await focusWindowByID(windowID)
            if actualFocused == windowID {
                await gridState.setFocus(spaceID: spaceID, cellID: cellID, windowIndex: tryIdx)
                return windowID
            }
            // Same-cell async race: the OS reported a different window as
            // focused, but that window is itself a member of this cell. This
            // happens when an appActivated notification from a prior ax.focus
            // arrives after our verification read. The first ax.focus call
            // DID take effect — accept reality, commit the requested index,
            // and stop iterating. Without this branch we'd issue extra
            // ax.focus calls that compound the race and ultimately throw a
            // spurious noWindowsInCell.
            if GridFocus.detectFocusRace(actual: actualFocused, cellWindows: cellWindows) {
                jlog("focus.cycle.race", data: [
                    "requested": Int(windowID),
                    "actual": Int(actualFocused),
                    "cell": cellID,
                ])
                await gridState.setFocus(spaceID: spaceID, cellID: cellID, windowIndex: tryIdx)
                return windowID
            }
            // OS focused a window outside this cell — genuinely unfocusable, try next
        }

        // All windows in cell were unfocusable
        throw GridFocusError.noWindowsInCell(cellID)
    }

    // detectFocusRace: pure predicate for the same-cell race branch in
    // cycleFocus. Returns true when the OS-reported actually-focused window
    // is itself a member of the cell we're cycling within — which means a
    // prior ax.focus call landed late and we should commit instead of
    // walking the rest of the list.
    static func detectFocusRace(actual: UInt32, cellWindows: [UInt32]) -> Bool {
        return cellWindows.contains(actual)
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
        guard let gridState = gridState,
              let stateProvider = stateProvider else {
            throw GridFocusError.noLayout
        }

        // Prune dead windows before focusing
        let wmState = await stateProvider.getState()
        var cellWindows = await gridState.getCellWindows(spaceID: spaceID, cellID: cellID)
        cellWindows = cellWindows.filter { wid in
            if wmState.windows[String(wid)] != nil { return true }
            Task { await gridState.removeWindow(wid, fromSpace: spaceID) }
            jlog("focus.prune", data: ["wid": wid, "cell": cellID])
            return false
        }
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
                } else {
                    // lastFocusedWid is not in this cell's window list --
                    // window moved to another cell/space or was pruned above.
                    // Log for diagnostics, then fall back to lastFocusedIdx.
                    jlog("focus.restore.stale", data: [
                        "wid": cellState.lastFocusedWid,
                        "cell": cellID,
                        "spaceID": spaceID,
                    ])
                    idx = max(0, min(cellState.lastFocusedIdx, cellWindows.count - 1))
                }
            } else {
                // No lastFocusedWid recorded -- use lastFocusedIdx
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

    // focusWindowByID: focus a window via WindowManipulator with mismatch retry.
    //
    // After the AX focus call, checks metadata.focusedWindowID (cached, no OS call).
    // If the OS focused a different window, retries AX focus once.
    // Logs on mismatch. Accepts reality after retry.
    //
    // Returns the actual focused window ID (requested ID if successful, or whatever
    // the OS actually focused if mismatch was accepted after retry).
    @discardableResult
    func focusWindowByID(_ windowID: UInt32) async throws -> UInt32 {
        guard let stateProvider = stateProvider,
              let windowManipulator = windowManipulator else {
            throw GridFocusError.windowNotFound(windowID)
        }

        // Look up window PID from StateManager
        let wmState = await stateProvider.getState()
        guard let windowState = wmState.windows[String(windowID)] else {
            throw GridFocusError.windowNotFound(windowID)
        }

        // Own-process windows (notification panel): use NSWindow on MainActor
        // AX calls on own-process execute in-place, crashing AppKit's main-thread assertion.
        let serverPID = ProcessInfo.processInfo.processIdentifier
        if windowState.pid == serverPID {
            await MainActor.run {
                guard let nsWindow = NSApp.windows.first(where: { $0.windowNumber == Int(windowID) }) else { return }
                NSApp.activate(ignoringOtherApps: true)
                nsWindow.makeKeyAndOrderFront(nil)
            }
            jlog("ax.focus", data: ["pid": windowState.pid, "wid": windowID])
            return windowID
        }

        // Attempt 1: AX focus
        let success = windowManipulator.focusWindow(pid: windowState.pid, windowID: windowID)
        if !success {
            throw GridFocusError.focusFailed(windowID)
        }

        // Yield one runloop tick before reading the verification state.
        // The macOS appActivated notification delivers focusedWindowID
        // updates asynchronously; without this yield, the verification
        // read can fire before the notification lands and report the
        // *previous* focused window as actual, producing a spurious
        // mismatch. The cycleFocus same-cell race branch is a backstop
        // for cases where a single yield isn't enough.
        await Task.yield()

        // Verify: read cached focused window ID (no OS call).
        // Re-read state after the focus call to see what the OS reports.
        let postState = await stateProvider.getState()
        let actualFocusedWID = postState.metadata.focusedWindowID

        if let actualWID = actualFocusedWID, actualWID != windowID {
            // Mismatch: OS focused a different window. Retry once.
            jlog("focus.mismatch", data: [
                "requested": Int(windowID),
                "actual": Int(actualWID),
                "retry": true,
            ])

            // Loop detection: if this pair has been flipping repeatedly across
            // recent calls, skip the retry and accept OS reality instead of
            // contributing to an unbounded ping-pong.
            if let trip = focusLoopDetector.observe(
                requested: windowID,
                actual: actualWID,
                now: CFAbsoluteTimeGetCurrent()
            ) {
                let lowWid = min(windowID, actualWID)
                let highWid = max(windowID, actualWID)
                jlog("focus.loop", data: [
                    "pair": [Int(lowWid), Int(highWid)],
                    "count": trip.count,
                    "dur_ms": trip.durationMs,
                ])
                jlog("focus.mismatch.accept", data: [
                    "requested": Int(windowID),
                    "actual": Int(actualWID),
                ])
                return actualWID
            }

            // Attempt 2: retry AX focus
            _ = windowManipulator.focusWindow(pid: windowState.pid, windowID: windowID)

            // Check again after retry
            let retryState = await stateProvider.getState()
            let retryActualWID = retryState.metadata.focusedWindowID

            if let retryWID = retryActualWID, retryWID != windowID {
                // Still mismatched after retry. Accept OS reality.
                jlog("focus.mismatch.accept", data: [
                    "requested": Int(windowID),
                    "actual": Int(retryWID),
                ])
                return retryWID
            }
        }

        return windowID
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
            jlog("focus.cross.err", msg: "cannot determine display", data: ["spaceID": spaceID])
            throw GridFocusError.cannotDetermineDisplay
        }

        jlog("focus.cross.try", data: [
            "dir": direction.rawValue,
            "display": String(currentDisplayUUID.prefix(8)),
            "displays": wmState.displays.count
        ])

        // Find adjacent display in direction
        var adjacentDisplay = findAdjacentDisplay(
            currentDisplayUUID: currentDisplayUUID,
            direction: direction,
            displays: wmState.displays
        )
        if adjacentDisplay == nil {
            jlog("focus.cross.no_adjacent", data: ["dir": direction.rawValue])
            // Try opposite display for wrap-around
            adjacentDisplay = findOppositeDisplay(
                currentDisplayUUID: currentDisplayUUID,
                direction: direction,
                displays: wmState.displays
            )
        }
        guard let adjacentDisplay = adjacentDisplay else {
            jlog("focus.cross.no_display", data: ["dir": direction.rawValue])
            throw GridFocusError.noDisplayInDirection
        }

        jlog("focus.cross.found", data: [
            "target": String(adjacentDisplay.uuid.prefix(8)),
            "targetSpace": adjacentDisplay.currentSpaceID
        ])

        // Get cells on target display
        let (targetCellBounds, targetSpaceID) = try await getDisplayCells(adjacentDisplay)
        let targetSpaceIDStr = String(targetSpaceID)
        let targetSpaceState = await gridState.getSpaceReadOnly(targetSpaceIDStr)

        jlog("focus.cross.cells", data: [
            "targetSpace": targetSpaceIDStr,
            "cells": targetCellBounds.count,
            "hasState": targetSpaceState != nil
        ])

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
        var windowID = try await focusCellByID(spaceID: targetSpaceIDStr, cellID: targetCell)

        // Tell StateManager the target space is now active so subsequent
        // syncBordersForCurrentSpace calls (from suppression release) use
        // the correct display. Without this, macOS metadata still reports
        // the source display as active (appActivated doesn't fire for
        // same-app cross-display focus).
        await stateManagerForOverride?.overrideActiveSpace(UInt64(targetSpaceID))

        // Check what the OS actually focused — AX may raise a different
        // window of the same app. Update GridState to match reality.
        let postState = await stateProvider?.getState()
        if let actualWID = postState?.metadata.focusedWindowID,
           actualWID != windowID {
            // OS focused a different window. Find it in the target cell
            // and update GridState to match.
            let cellWindows = await gridState.getCellWindows(spaceID: targetSpaceIDStr, cellID: targetCell)
            if let actualIdx = cellWindows.firstIndex(of: actualWID) {
                await gridState.setFocus(spaceID: targetSpaceIDStr, cellID: targetCell, windowIndex: actualIdx)
                windowID = actualWID
                jlog("focus.cross.corrected", data: [
                    "requested": windowID,
                    "actual": actualWID,
                ])
            }
        }

        // Explicitly sync borders for the target display.
        await gridReconciler?.syncBordersForSpace(targetSpaceIDStr, displayUUID: adjacentDisplay.uuid)

        return windowID
    }

    // ============================================================
    // PRIVATE: Display adjacency
    // ============================================================

    // findAdjacentDisplay: find display adjacent in direction
    func findAdjacentDisplay(
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
    func findOppositeDisplay(
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
    func findWrapTarget(
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
    func pickClosestCell(
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
    func matchVisualPosition(
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
    func findClosestCellToPoint(
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
    func getDisplayCells(
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
    func findCurrentDisplayUUID(
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
    func getDisplayBoundsForSpace(
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

    // findActiveSpaceID: find the focused display's active space
    // Uses metadata.activeSpaceID which tracks the display that has focus,
    // not just any display's active space (multi-monitor has one per display).
    func findActiveSpaceID(
        _ wmState: WindowManagerState
    ) -> String? {
        if let activeSpaceID = wmState.metadata.activeSpaceID {
            return String(activeSpaceID)
        }
        // Fallback: find any active space (single-monitor case)
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
