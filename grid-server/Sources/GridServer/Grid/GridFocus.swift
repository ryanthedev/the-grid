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
    case allWindowsUnfocusable(String)
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
        case .allWindowsUnfocusable(let id): return "no focusable window in cell \(id)"
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
    private weak var windowController: (any WindowController)?
    private weak var gridReconciler: GridReconciler?

    // Concrete StateManager ref for overrideActiveSpace (not on StateProvider).
    // Used only by cross-display focus navigation.
    private weak var stateManagerForOverride: StateManager?

    // Tracks recent focus attempts to detect ping-pong loops across repeated
    // focusWindowByID calls. Actor-isolated (#35): GridFocus is a plain class
    // invoked concurrently from the command path, the reconciler event path,
    // and the 300ms sweep — a bare struct field raced its backing Array.
    private let focusLoopActor = FocusLoopActor()

    init() {}

    func setup(
        gridState: GridState,
        gridConfig: GridConfig,
        stateProvider: any StateProvider,
        windowController: any WindowController,
        stateManagerForOverride: StateManager? = nil
    ) {
        self.gridState = gridState
        self.gridConfig = gridConfig
        self.stateProvider = stateProvider
        self.windowController = windowController
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

        // #8: order candidates by closeness, then pick the first that actually
        // has windows. Pressing toward an empty cell (e.g. the usually-empty
        // 'notify' cell) must skip to the next non-empty cell / wrap target
        // instead of dead-ending on noWindowsInCell.
        let orderedCandidates = orderCandidatesByCloseness(
            currentCell: currentCell, candidates: candidates, cellBounds: calculated.cellBounds)
        let candidateCounts = await cellWindowCounts(
            spaceID: spaceID, cellIDs: orderedCandidates)
        guard let targetCell = selectNonEmptyCandidate(
            orderedCandidates: orderedCandidates, cellWindowCounts: candidateCounts) else {
            jlog("focus.skip_empty", data: [
                "dir": direction.rawValue,
                "cell": currentCell,
                "candidates": orderedCandidates.count,
            ])
            throw GridFocusError.noCellInDirection
        }

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

        let rawCellWindows = await gridState.getCellWindows(spaceID: spaceID, cellID: cellID)

        // Prune dead windows (closed but not yet cleaned up from GridState).
        // #42: await the removeWindow BEFORE the later setFocus so setFocus
        // indexes the pruned state — a detached Task could land after setFocus,
        // which then recorded a dead/wrong successor.
        var cellWindows: [UInt32] = []
        var pruned = false
        for wid in rawCellWindows {
            if wmState.windows[String(wid)] != nil {
                cellWindows.append(wid)
                continue
            }
            await gridState.removeWindow(wid, fromSpace: spaceID)
            jlog("focus.prune", data: ["wid": wid, "cell": cellID])
            pruned = true
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

            // Attempt AX focus. A stale/unfocusable candidate — e.g. an
            // Activity Monitor window whose cached state still reports role
            // "AXWindow" but no longer resolves via AX (logged upstream as
            // ax.fail not_in_list -> warn.focus no_ax_element) — makes
            // focusWindowByID throw focusFailed. The old code let that throw
            // propagate, aborting the whole cycle, so focus prev/next silently
            // no-oped whenever the cycle landed on the stale window first.
            // Treat it like the outside-cell mismatch below: skip to the next
            // candidate. This restores the loop's original "skip unfocusable
            // windows" intent, which the throw short-circuited.
            let attempt: CycleFocusAttempt
            do {
                attempt = .focused(try await focusWindowByID(windowID))
            } catch let error as GridFocusError {
                switch error {
                case .focusFailed, .windowNotFound:
                    jlog("focus.cycle.skip", data: [
                        "wid": Int(windowID),
                        "cell": cellID,
                        "reason": "unfocusable",
                    ])
                    continue
                default:
                    throw error
                }
            }

            // Same-cell async race: the OS reported a different window as
            // focused, but that window is itself a member of this cell. This
            // happens when an appActivated notification from a prior ax.focus
            // arrives after our verification read. The first ax.focus call
            // DID take effect — accept reality, commit the requested index,
            // and stop iterating. Without this branch we'd issue extra
            // ax.focus calls that compound the race and ultimately throw a
            // spurious noWindowsInCell.
            guard GridFocus.shouldCommitFocus(
                requested: windowID,
                attempt: attempt,
                cellWindows: cellWindows
            ) else {
                // OS focused a window outside this cell — genuinely
                // unfocusable, try the next index.
                continue
            }

            if case .focused(let actual) = attempt, actual != windowID {
                jlog("focus.cycle.race", data: [
                    "requested": Int(windowID),
                    "actual": Int(actual),
                    "cell": cellID,
                ])
            }
            await gridState.setFocus(spaceID: spaceID, cellID: cellID, windowIndex: tryIdx)
            return windowID
        }

        // All windows in cell were unfocusable
        throw GridFocusError.allWindowsUnfocusable(cellID)
    }

    // detectFocusRace: pure predicate for the same-cell race branch in
    // cycleFocus. Returns true when the OS-reported actually-focused window
    // is itself a member of the cell we're cycling within — which means a
    // prior ax.focus call landed late and we should commit instead of
    // walking the rest of the list.
    static func detectFocusRace(actual: UInt32, cellWindows: [UInt32]) -> Bool {
        return cellWindows.contains(actual)
    }

    // CycleFocusAttempt: the outcome of one focusWindowByID call inside the
    // cycleFocus loop. `.failed` means the window had no resolvable AX element
    // (stale/unfocusable — focusWindowByID threw focusFailed/windowNotFound);
    // `.focused` carries the wid the OS reported as focused.
    enum CycleFocusAttempt: Equatable {
        case focused(UInt32)
        case failed
    }

    // shouldCommitFocus: pure decision for one iteration of the cycleFocus
    // loop. Returns true when the requested window's index should be committed
    // and returned; false when the loop should skip to the next candidate.
    //
    // - .failed (unfocusable / no AX element): skip. This is the fix for the
    //   stale-window no-op — a candidate that cannot be focused must not abort
    //   the cycle, it simply isn't a valid successor.
    // - .focused(actual) where actual == requested: exact success, commit.
    // - .focused(actual) where actual is another member of this cell: a
    //   same-cell late-notification race (see detectFocusRace), commit.
    // - .focused(actual) otherwise: the OS focused a window outside the cell,
    //   the requested window is genuinely unfocusable — skip.
    static func shouldCommitFocus(
        requested: UInt32,
        attempt: CycleFocusAttempt,
        cellWindows: [UInt32]
    ) -> Bool {
        switch attempt {
        case .failed:
            return false
        case .focused(let actual):
            return actual == requested
                || detectFocusRace(actual: actual, cellWindows: cellWindows)
        }
    }

    // focusCandidateOrder: the order in which a cell's windows are tried when
    // focusing the cell itself (as opposed to cycling within it). The restored
    // window comes first; the rest follow in list order, wrapping, so no
    // candidate is tried twice and none is skipped.
    //
    // Directional focus used to try only the preferred index and abort if it
    // failed. A cell holding one unfocusable window — Spotify exposes a CG
    // window with zero AX windows behind it — then dead-ended every direction:
    // once focus landed there, `focus left/right/up/down` all threw
    // focusFailed on the same wid until the user clicked something manually.
    // cycleFocus already skipped unfocusable candidates; this is the same
    // intent for the directional path.
    static func focusCandidateOrder(preferredIdx: Int, windowCount: Int) -> [Int] {
        guard windowCount > 0 else { return [] }
        let start = max(0, min(preferredIdx, windowCount - 1))
        return (0..<windowCount).map { (start + $0) % windowCount }
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

        // Prune dead windows before focusing.
        // #42: await the removeWindow before the later setFocus so the focus
        // index is computed against the pruned list (not a detached race).
        let wmState = await stateProvider.getState()
        let rawCellWindows = await gridState.getCellWindows(spaceID: spaceID, cellID: cellID)
        var cellWindows: [UInt32] = []
        for wid in rawCellWindows {
            if wmState.windows[String(wid)] != nil {
                cellWindows.append(wid)
                continue
            }
            await gridState.removeWindow(wid, fromSpace: spaceID)
            jlog("focus.prune", data: ["wid": wid, "cell": cellID])
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

        // Try the restored window first, then the cell's other windows. A
        // candidate the OS refuses to focus must not abort the whole command —
        // see focusCandidateOrder for the dead-end this fixes.
        for candidateIdx in GridFocus.focusCandidateOrder(
            preferredIdx: idx,
            windowCount: cellWindows.count
        ) {
            let windowID = cellWindows[candidateIdx]

            let attempt: CycleFocusAttempt
            do {
                attempt = .focused(try await focusWindowByID(windowID))
            } catch let error as GridFocusError {
                switch error {
                case .focusFailed, .windowNotFound:
                    jlog("focus.cell.skip", data: [
                        "wid": Int(windowID),
                        "cell": cellID,
                        "reason": "unfocusable",
                    ])
                    continue
                default:
                    throw error
                }
            }

            // Same decision the cycle path uses: commit on an exact hit or a
            // same-cell late-notification race, skip when the OS focused
            // something outside this cell.
            guard GridFocus.shouldCommitFocus(
                requested: windowID,
                attempt: attempt,
                cellWindows: cellWindows
            ) else { continue }

            await gridState.setFocus(spaceID: spaceID, cellID: cellID, windowIndex: candidateIdx)
            return windowID
        }

        throw GridFocusError.allWindowsUnfocusable(cellID)
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
              let windowController = windowController else {
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

        // Attempt 1: AX focus.
        // #21: success now reflects the real AX/CG result. A false result means
        // focus genuinely did not move — propagate it instead of pretending.
        let success = await windowController.focusWindow(windowID: windowID, pid: windowState.pid)
        if !success {
            jlog("warn.focus", data: ["reason": "focus_returned_false", "wid": Int(windowID)])
            throw GridFocusError.focusFailed(windowID)
        }

        // #7: a successful port call is authoritative for the requested window —
        // it IS now focused. The event-fed cache (metadata.focusedWindowID) lags
        // a main-runloop round trip, so reading it here historically reported the
        // PREVIOUS window and triggered a spurious second raise. We no longer
        // double-raise off the stale cache.
        //
        // Record the focus synchronously where a StateManager is wired so the
        // cache converges immediately (the cross-display path wires this; the
        // command path's StateManager updates via the AX event).
        await stateManagerForOverride?.setFocusedWindow(windowID)

        // Yield one runloop tick so an in-flight appActivated notification for a
        // genuine OS focus steal (not our own lagging event) can land before the
        // loop-detection read below.
        await Task.yield()

        // Per-requested-window loop detection (#43): only used to bail out of a
        // persistent OS re-steal. The detector observes the actual cache value
        // (including the nil-actual case). On a trip we accept OS reality.
        let postState = await stateProvider.getState()
        let actualFocusedWID = postState.metadata.focusedWindowID

        // Self-match (or cache not yet updated to a *different* window): the
        // requested focus stands — return it without any retry.
        if actualFocusedWID == nil || actualFocusedWID == windowID {
            return windowID
        }

        // The cache reports a DIFFERENT window. This is either our own lagging
        // event (benign) or a real OS re-steal. Consult the per-requested-window
        // detector; a sustained loop trips and we accept reality.
        let actualWID = actualFocusedWID!
        if let trip = await focusLoopActor.observeRequested(
            requested: windowID,
            actual: actualWID,
            now: CFAbsoluteTimeGetCurrent()
        ) {
            jlog("focus.loop", data: [
                "requested": Int(windowID),
                "actual": Int(actualWID),
                "count": trip.count,
                "dur_ms": trip.durationMs,
            ])
            jlog("focus.mismatch.accept", data: [
                "requested": Int(windowID),
                "actual": Int(actualWID),
            ])
            return actualWID
        }

        // Not a sustained loop: trust our successful raise for the requested
        // window. Downstream same-cell handling (cycleFocus.detectFocusRace)
        // covers the genuine late-notification case.
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

    // orderCandidatesByCloseness: sort candidate cells by center distance to the
    // current cell (closest first), with a deterministic cellID tiebreaker.
    // Feeds the #8 empty-cell skip so the nearest NON-EMPTY cell wins.
    func orderCandidatesByCloseness(
        currentCell: String,
        candidates: [String],
        cellBounds: [String: CGRect]
    ) -> [String] {
        guard let currentBounds = cellBounds[currentCell] else { return candidates }
        let currentCenter = currentBounds.center
        return candidates.sorted { a, b in
            let da = distance(cellBounds[a]?.center, currentCenter)
            let db = distance(cellBounds[b]?.center, currentCenter)
            if da != db { return da < db }
            return a < b
        }
    }

    // distance: euclidean distance, or +inf for a missing point.
    private func distance(_ p: CGPoint?, _ q: CGPoint) -> Double {
        guard let p else { return .greatestFiniteMagnitude }
        let dx = p.x - q.x
        let dy = p.y - q.y
        return sqrt(dx * dx + dy * dy)
    }

    // cellWindowCounts: live window count per candidate cell (for #8 skip).
    private func cellWindowCounts(spaceID: String, cellIDs: [String]) async -> [String: Int] {
        guard let gridState else { return [:] }
        var counts: [String: Int] = [:]
        for cellID in cellIDs {
            let windows = await gridState.getCellWindows(spaceID: spaceID, cellID: cellID)
            counts[cellID] = windows.count
        }
        return counts
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

// MARK: - Test Helpers

extension GridFocus {

    // _test_setup: minimal wiring for tests -- injects windowController port
    // without full GridCommandRouter wiring.
    func _test_setup(
        gridState: GridState,
        stateProvider: any StateProvider,
        windowController: any WindowController
    ) {
        self.gridState = gridState
        self.stateProvider = stateProvider
        self.windowController = windowController
    }
}
