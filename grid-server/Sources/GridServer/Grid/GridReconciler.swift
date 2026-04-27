//
// GridReconciler.swift
// GridServer
//
// Event-driven reconciler: subscribes to EventRouter, updates GridState,
// and syncs borders via SimpleBorderManager.
//

import Foundation
import CoreGraphics
import AppKit

struct PendingLaunchTarget {
    let spaceID: String
    let cellID: String
    let createdAt: CFAbsoluteTime
}

class GridReconciler: StateEventHandler {

    // Dependencies (set via setup)
    private weak var gridState: GridState?
    private weak var gridConfig: GridConfig?
    private weak var stateManager: StateManager?
    private weak var simpleBorderManager: SimpleBorderManager?

    // Weak references to GridApply and GridFocus for picker-launched window handling
    private weak var gridApply: GridApply?
    private weak var gridFocus: GridFocus?

    // Strong reference to StateValidator — GridReconciler is the owning reference
    // that keeps the validator (and its periodic timer) alive for process lifetime
    private var stateValidator: StateValidator?

    // Focus sweep: periodic timer that compares OS focus against GridState
    // and corrects drift from late/stale events.
    private var sweepTimer: DispatchSourceTimer?
    private let sweepInterval: TimeInterval = 0.3

    // Guards user commands during sleep/wake recovery.
    // Non-nil only while handleSystemWake is in progress.
    // Commands call awaitWakeCompletion() to wait for this to finish.
    private var wakeValidationTask: Task<Void, Never>? = nil

    // One-shot target: next tileable window created on target space claims this cell
    private var pendingLaunchTarget: PendingLaunchTarget?

    // Timeout for pending launch target (app may take time to launch)
    private let pendingLaunchTimeout: CFAbsoluteTime = 15.0

    // Ref-counted suppression for bulk operations (layout apply, picker, terminal, focus).
    // Managed exclusively via executeAction/beginAction/endAction -- no direct access.
    // Multiple callers can nest suppress/unsuppress without interfering.
    private var suppressionDepth: Int = 0
    private var suppressReconciliation: Bool { suppressionDepth > 0 }

    // Per-window fencing: OS focus events for fenced windows are dropped
    // until released or expired. Replaces the old move cooldown model.
    // Map from window ID to fence expiry time (CFAbsoluteTime).
    private var fencedWindows: [UInt32: CFAbsoluteTime] = [:]

    // Safety timeout: fences auto-expire after this duration to prevent deadlocks
    private let fenceTimeoutSeconds: CFAbsoluteTime = 5.0

    init() {}

    // MARK: - Public API

    // Opaque token returned by beginAction, consumed by endAction.
    // Records label and start time for logging.
    struct ActionToken {
        let label: String
        let startTime: CFAbsoluteTime
    }

    // executeAction: unified lifecycle wrapper for short-lived state-mutating actions.
    //
    // Lifecycle: suppress -> execute closure -> sync borders -> unsuppress
    //
    // Parameters:
    //   label: string for logging (e.g. "focus.left", "layout.apply")
    //   syncBorders: whether to sync borders on completion (default: true).
    //     Callers that do their own border sync inside the closure pass false.
    //   body: async throwing closure containing the action's work
    //
    // Error handling: if body throws, still unsuppress and sync (borders should reflect
    // whatever partial state change happened).
    func executeAction<T>(
        label: String,
        syncBorders: Bool = true,
        body: () async throws -> T
    ) async rethrows -> T {
        jlog("action.start", data: ["label": label])

        // 1. Suppress reconciler
        suppressionDepth += 1

        // 2. Execute the caller's work
        do {
            let result = try await body()

            // 3. Unsuppress
            suppressionDepth = max(0, suppressionDepth - 1)

            // 4. Sync borders if requested and depth reached 0
            if suppressionDepth == 0 && syncBorders {
                await syncBordersForCurrentSpace()
            }

            jlog("action.end", data: ["label": label])
            return result

        } catch {
            // Still unsuppress on error
            suppressionDepth = max(0, suppressionDepth - 1)

            if suppressionDepth == 0 && syncBorders {
                await syncBordersForCurrentSpace()
            }

            jlog("action.err", data: ["label": label, "err": "\(error)"])
            throw error
        }
    }

    // beginAction: start a long-lived suppression session.
    // Returns an ActionToken that must be passed to endAction when the session ends.
    // Used by nudge mode where suppression spans multiple keystrokes.
    func beginAction(label: String) -> ActionToken {
        suppressionDepth += 1
        jlog("action.begin", data: ["label": label, "depth": suppressionDepth])
        return ActionToken(label: label, startTime: CFAbsoluteTimeGetCurrent())
    }

    // endAction: end a long-lived suppression session started by beginAction.
    // Decrements suppression and optionally syncs borders when depth reaches 0.
    func endAction(_ token: ActionToken, syncBorders: Bool = true) {
        if suppressionDepth <= 0 {
            jlog("warn.action.end.underflow", data: ["label": token.label])
        }
        suppressionDepth = max(0, suppressionDepth - 1)
        jlog("action.end", data: [
            "label": token.label,
            "depth": suppressionDepth,
            "dur_ms": Int((CFAbsoluteTimeGetCurrent() - token.startTime) * 1000),
        ])
        if suppressionDepth == 0 && syncBorders {
            Task {
                await syncBordersForCurrentSpace()
            }
        }
    }

    // Fence one or more windows so OS focus events for them are dropped.
    // Called by move commands before they begin mutating state.
    // reason: logging context only (not stored).
    func acquireFence(windowIDs: Set<UInt32>, reason: String) {
        guard !windowIDs.isEmpty else {
            jlog("warn.fence.empty", msg: "acquireFence called with empty set")
            return
        }
        let expiresAt = CFAbsoluteTimeGetCurrent() + fenceTimeoutSeconds
        for windowID in windowIDs {
            fencedWindows[windowID] = expiresAt
        }
        jlog("fence.acquire", data: [
            "wids": windowIDs.sorted().map { Int($0) },
            "reason": reason,
        ])
    }

    // Release fence for specific windows. Called after border sync completes.
    func releaseFence(windowIDs: Set<UInt32>) {
        for windowID in windowIDs {
            fencedWindows.removeValue(forKey: windowID)
        }
        jlog("fence.release", data: [
            "wids": windowIDs.sorted().map { Int($0) },
        ])
    }

    func setPendingLaunchTarget(_ target: PendingLaunchTarget?) {
        pendingLaunchTarget = target
        if let target {
            jlog("reconcile.pending.set", data: ["spaceID": target.spaceID, "cellID": target.cellID])
        }
    }

    func setApply(_ apply: GridApply) {
        self.gridApply = apply
    }

    func setFocus(_ focus: GridFocus) {
        self.gridFocus = focus
    }

    func setValidator(_ validator: StateValidator) {
        self.stateValidator = validator
    }

    // awaitWakeCompletion
    //
    // Called by GridCommandRouter before processing any command.
    // If wake validation is in progress, suspends the caller until it finishes.
    // Fast path (common case): wakeValidationTask is nil, returns immediately.
    func awaitWakeCompletion() async {
        await wakeValidationTask?.value
    }

    // Check if a window is currently fenced (not expired).
    // Lazily cleans up expired entries.
    private func isWindowFenced(_ windowID: UInt32) -> Bool {
        guard let expiresAt = fencedWindows[windowID] else {
            return false
        }

        if CFAbsoluteTimeGetCurrent() > expiresAt {
            // Fence expired -- safety timeout hit
            fencedWindows.removeValue(forKey: windowID)
            jlog("fence.expired", data: ["wid": Int(windowID)])
            return false
        }

        return true
    }

    // isCellMateOfFencedWindow: returns true if windowID shares a cell (in any
    // space) with at least one currently-active fenced window.
    // Called only after isWindowFenced returns false, so windowID itself is not
    // fenced. Performs lazy expiry cleanup on fencedWindows during iteration.
    // Returns false immediately when fencedWindows is empty (the common case).
    private func isCellMateOfFencedWindow(_ windowID: UInt32) async -> Bool {
        guard let gridState else { return false }

        // Collect active fenced window IDs, expiring stale entries as we go.
        let now = CFAbsoluteTimeGetCurrent()
        var activeFencedIDs: Set<UInt32> = []
        var expiredIDs: [UInt32] = []

        for (fencedWID, expiresAt) in fencedWindows {
            if now > expiresAt {
                expiredIDs.append(fencedWID)
            } else {
                activeFencedIDs.insert(fencedWID)
            }
        }

        for expiredID in expiredIDs {
            fencedWindows.removeValue(forKey: expiredID)
            jlog("fence.expired", data: ["wid": Int(expiredID)])
        }

        // Fast path: no active fences (normal operation outside of moves).
        if activeFencedIDs.isEmpty { return false }

        // For each space, check whether windowID and any fenced window share a cell.
        let spaceIDs = await gridState.getSpaceIDs()

        for spaceID in spaceIDs {
            guard let cellID = await gridState.getWindowCell(windowID: windowID, inSpace: spaceID) else {
                continue
            }

            let cellWindows = await gridState.getCellWindows(spaceID: spaceID, cellID: cellID)

            for cellWID in cellWindows where activeFencedIDs.contains(cellWID) {
                return true
            }
        }

        return false
    }

    // Store references, register with EventRouter
    func setup(
        gridState: GridState,
        gridConfig: GridConfig,
        stateManager: StateManager,
        simpleBorderManager: SimpleBorderManager
    ) {
        self.gridState = gridState
        self.gridConfig = gridConfig
        self.stateManager = stateManager
        self.simpleBorderManager = simpleBorderManager

        Task {
            await EventRouter.shared.register(self)
        }

        startSweepTimer()
        jlog("reconcile.init")
    }

    // MARK: - Focus Sweep

    // Start the periodic focus sweep timer.
    // Fires every 300ms on a utility queue; the actual work hops to the
    // reconciler's context via Task.
    private func startSweepTimer() {
        let queue = DispatchQueue(label: "com.thegrid.focussweep", qos: .userInteractive)
        let source = DispatchSource.makeTimerSource(queue: queue)
        source.schedule(
            deadline: .now() + sweepInterval,
            repeating: sweepInterval,
            leeway: .milliseconds(50)
        )
        source.setEventHandler { [weak self] in
            guard let self else { return }
            Task { await self.focusSweep() }
        }
        sweepTimer = source
        source.resume()
        jlog("sweep.timer.start", data: ["intervalMs": Int(sweepInterval * 1000)])
    }

    // Compare OS-level focused window against GridState focus.
    // If they diverge, correct GridState and sync borders.
    private func focusSweep() async {
        // Skip during suppressed actions — the action owns focus
        guard !suppressReconciliation else { return }
        guard let gridState, let stateManager else { return }

        let wmState = await stateManager.getState()
        guard let osWindowID = wmState.metadata.focusedWindowID, osWindowID != 0 else { return }

        // Resolve which display/space the OS-focused window is on
        guard let spaceID = await gridState.findSpaceContaining(windowID: osWindowID) else { return }

        // Compare against GridState's focused window for that space
        let gridFocusedWID = await gridState.getFocusedWindow(spaceID: spaceID)
        guard gridFocusedWID != osWindowID else { return }

        // Mismatch — correct GridState
        let cellID = await gridState.getWindowCell(windowID: osWindowID, inSpace: spaceID)
        guard let cellID else { return }

        let cellWindows = await gridState.getCellWindows(spaceID: spaceID, cellID: cellID)
        let windowIndex = cellWindows.firstIndex(of: osWindowID) ?? 0
        await gridState.setFocus(spaceID: spaceID, cellID: cellID, windowIndex: windowIndex)

        // Find display for this space and sync borders
        let displayUUID = findDisplayUUIDForSpace(spaceID, from: wmState)
            ?? findCurrentDisplayUUID(from: wmState)
        guard let displayUUID else { return }

        simpleBorderManager?.updateFocus(
            newFocusedWindow: osWindowID,
            displayUUID: displayUUID
        )
        await syncBordersForSpace(spaceID, displayUUID: displayUUID)

        jlog("sweep.correct", data: [
            "osWid": osWindowID,
            "gridWid": gridFocusedWID,
            "cell": cellID,
            "space": spaceID,
        ])
    }

    // MARK: - StateEventHandler

    func handle(_ event: StateEvent, context: EventContext) async throws {
        // Focus events handle suppression/fencing internally
        if case .focusChanged(let focusState) = event {
            await handleFocusChanged(focusState)
            return
        }

        // Check pending launch target for windowCreated BEFORE suppression guard.
        // Picker-launched windows must be claimed even during move suppression.
        if case .windowCreated(let windowID, let pid) = event {
            if pendingLaunchTarget != nil {
                await handlePendingLaunchWindow(windowID, pid)
                return
            }
        }

        // Space ID reassignment must always be processed — it affects GridState
        // integrity and cannot wait for suppression to end.
        if case .spaceIDReassigned(let oldSpaceID, let newSpaceID, let displayUUID) = event {
            await handleSpaceIDReassigned(
                oldSpaceID: oldSpaceID,
                newSpaceID: newSpaceID,
                displayUUID: displayUUID
            )
            return
        }

        // Skip other events when suppressed
        if suppressReconciliation {
            return
        }

        switch event {
        case .windowDestroyed(let windowID):
            await handleWindowDestroyed(windowID)

        case .windowCreated(let windowID, let pid):
            await handleWindowCreated(windowID, pid)

        case .systemWoke:
            await handleSystemWake()

        case .windowMoved(let windowID, let frame):
            handleWindowMoved(windowID, frame)

        case .windowMinimized(let windowID):
            await handleWindowMinimized(windowID)

        case .windowDeminimized(let windowID):
            await handleWindowDeminimized(windowID)

        case .displayConnected(let displayUUID):
            await handleDisplayConnected(displayUUID)

        case .displayDisconnected(let displayUUID):
            await handleDisplayDisconnected(displayUUID)

        case .appTerminated(let app):
            await handleAppTerminated(app)

        default:
            // Ignore other events (app lifecycle, title changes, etc.)
            break
        }
    }

    // MARK: - Event Handlers

    // handleAppTerminated: instrumentation-only scan over gridState cells.
    // When an app dies we want to tell, post-mortem, whether the crash was
    // correlated with cells still referencing wids owned by the dying pid.
    // Does NOT mutate state — the per-window AX destroy flow still runs.
    private func handleAppTerminated(_ app: NSRunningApplication) async {
        guard let gridState, let stateManager else { return }
        let pid = app.processIdentifier

        // Collect the per-space assignments snapshot from GridState.
        let spaceIDs = await gridState.getSpaceIDs()
        var assignmentsBySpace: [String: [String: [UInt32]]] = [:]
        for spaceID in spaceIDs {
            assignmentsBySpace[spaceID] = await gridState.getWindowAssignments(spaceID: spaceID)
        }

        // Build space→display map from wmState.
        let wmState = await stateManager.getState()
        var spaceToDisplay: [String: String] = [:]
        for (spaceID, space) in wmState.spaces {
            spaceToDisplay[spaceID] = space.displayUUID
        }

        let stale = AppTermReconciler.findStaleCells(
            pid: pid,
            wmState: wmState,
            assignmentsBySpace: assignmentsBySpace,
            spaceToDisplay: spaceToDisplay
        )

        let payload: [[String: Any]] = stale.map { entry in
            [
                "display": entry.display,
                "cell": entry.cell,
                "wids": entry.wids.map { Int($0) }
            ]
        }

        jlog("app.term.reconcile", data: [
            "app": app.localizedName ?? "?",
            "pid": Int(pid),
            "displays_with_stale_wids": payload
        ])
    }

    private func handleWindowDestroyed(_ windowID: UInt32) async {
        // Remove window from GridState (all spaces)
        await gridState?.removeWindowFromAllSpaces(windowID)

        // Tell border manager to clean up borders for this window
        simpleBorderManager?.handleWindowDestroyed(windowID: windowID)

        // Sync borders for current space (assignments changed)
        await syncBordersForCurrentSpace()

        jlog("reconcile.win.destroy", data: ["wid": windowID])
    }

    private func handleWindowCreated(_ windowID: UInt32, _ pid: pid_t) async {
        // Get current state to find which space we're on
        guard let stateManager else {
            jlog("reconcile.win.create.bail", data: ["wid": windowID, "reason": "no_stateManager"])
            return
        }
        let wmState = await stateManager.getState()

        // Find the current space ID from active spaces
        guard let spaceID = findCurrentSpaceID(from: wmState) else {
            jlog("reconcile.win.create.bail", data: ["wid": windowID, "reason": "no_spaceID"])
            return
        }

        // Check if there's an active layout for this space
        guard let gridState else {
            jlog("reconcile.win.create.bail", data: ["wid": windowID, "reason": "no_gridState"])
            return
        }
        let layoutID = await gridState.getCurrentLayout(spaceID: spaceID)
        if layoutID.isEmpty {
            jlog("reconcile.win.create.bail", data: ["wid": windowID, "reason": "no_layout", "space": spaceID])
            return
        }

        // Get the window state from StateManager
        guard let windowState = wmState.windows[String(windowID)] else {
            jlog("reconcile.win.create.bail", data: [
                "wid": windowID,
                "reason": "not_in_state",
                "space": spaceID,
                "windowCount": wmState.windows.count
            ])
            return
        }

        // Check if window is tileable
        guard isTileable(window: windowState) else {
            await gridState.rejectWindow(windowID)
            jlog("reconcile.win.create.bail", data: [
                "wid": windowID,
                "reason": "not_tileable",
                "role": windowState.role ?? "nil",
                "subrole": windowState.subrole ?? "nil",
                "w": windowState.frame.width,
                "h": windowState.frame.height
            ])
            return
        }

        // Check window classification
        let appName = windowState.appName ?? ""
        let category = classifyWindow(window: windowState, appName: appName)
        if category != .standard {
            jlog("reconcile.win.create.bail", data: [
                "wid": windowID,
                "reason": "not_standard",
                "category": String(describing: category),
                "app": appName
            ])
            return
        }

        // Skip if window is already assigned (e.g., via pending launch target from poll)
        let assignments = await gridState.getWindowAssignments(spaceID: spaceID)
        for (_, windowIDs) in assignments {
            if windowIDs.contains(windowID) {
                jlog("reconcile.win.create.skip", data: ["wid": windowID, "reason": "already_assigned"])
                return
            }
        }

        // Check locked rules: if window matches a locked app rule, assign to its reserved cell.
        // Search current space first, then all spaces (the locked cell may be on another display).
        let appRules = await MainActor.run { gridConfig?.appRules ?? [] }
        let bundleID = wmState.applications[String(windowState.pid)]?.bundleIdentifier
        let lockedCell = getLockedCell(
            appName: appName,
            bundleID: bundleID,
            appRules: appRules
        )

        if let lockedCell {
            // Try current space first
            if assignments[lockedCell] != nil {
                await gridState.assignWindow(windowID, toCellID: lockedCell, inSpace: spaceID)
                try? await gridApply?.applyCellLayout(spaceID: spaceID, cellID: lockedCell)
                await syncBordersForCurrentSpace()
                jlog("reconcile.win.create.locked", data: [
                    "wid": windowID,
                    "cell": lockedCell,
                    "space": spaceID,
                    "app": appName,
                ])
                return
            }

            // Current space doesn't have the locked cell — search other spaces
            let allSpaceIDs = await gridState.getSpaceIDs()
            for otherSpaceID in allSpaceIDs where otherSpaceID != spaceID {
                let otherLayout = await gridState.getCurrentLayout(spaceID: otherSpaceID)
                guard !otherLayout.isEmpty else { continue }
                let otherAssignments = await gridState.getWindowAssignments(spaceID: otherSpaceID)
                if otherAssignments[lockedCell] != nil {
                    await gridState.assignWindow(windowID, toCellID: lockedCell, inSpace: otherSpaceID)
                    let displayUUID = findDisplayUUIDForSpace(otherSpaceID, from: wmState)
                    if let displayUUID {
                        try? await gridApply?.applyCellLayout(spaceID: otherSpaceID, cellID: lockedCell)
                        await syncBordersForSpace(otherSpaceID, displayUUID: displayUUID)
                    }
                    jlog("reconcile.win.create.locked", data: [
                        "wid": windowID,
                        "cell": lockedCell,
                        "space": otherSpaceID,
                        "crossDisplay": true,
                        "app": appName,
                    ])
                    return
                }
            }
        }

        // Auto-assign: find least-populated cell, skipping locked cells
        let locked = lockedCellIDs(appRules: appRules)
        let targetCell = findLeastPopulatedCell(assignments, excludeCells: locked)

        if !targetCell.isEmpty {
            await gridState.assignWindow(windowID, toCellID: targetCell, inSpace: spaceID)

            // Sync borders after assignment
            await syncBordersForCurrentSpace()
        }

        jlog("reconcile.win.create", data: ["wid": windowID, "cell": targetCell])
    }

    private func handlePendingLaunchWindow(_ windowID: UInt32, _ pid: pid_t) async {
        guard let target = pendingLaunchTarget else {
            // No target (race condition safety) -- fall through
            await handleWindowCreated(windowID, pid)
            return
        }

        // Always clear target first (one-shot: prevents retry on failure)
        pendingLaunchTarget = nil

        // Check timeout
        let elapsed = CFAbsoluteTimeGetCurrent() - target.createdAt
        if elapsed > pendingLaunchTimeout {
            jlog("reconcile.pending.expired", data: ["elapsed": elapsed])
            await handleWindowCreated(windowID, pid)
            return
        }

        // Get window state from StateManager
        guard let stateManager else { return }
        let wmState = await stateManager.getState()
        guard let windowState = wmState.windows[String(windowID)] else {
            await handleWindowCreated(windowID, pid)
            return
        }

        // Validate: must be tileable
        if !isTileable(window: windowState) {
            await handleWindowCreated(windowID, pid)
            return
        }

        // Validate: must be standard category
        let appName = windowState.appName ?? ""
        let category = classifyWindow(window: windowState, appName: appName)
        if category != .standard {
            await handleWindowCreated(windowID, pid)
            return
        }

        // Validate: window appeared on the target space
        let actualSpaceID = findCurrentSpaceID(from: wmState)
        if actualSpaceID == nil || actualSpaceID != target.spaceID {
            jlog("reconcile.pending.space.mismatch", data: [
                "expected": target.spaceID,
                "actual": actualSpaceID ?? "nil",
            ])
            await handleWindowCreated(windowID, pid)
            return
        }

        // Validate: target space has an active layout
        guard let gridState else { return }
        let layoutID = await gridState.getCurrentLayout(spaceID: target.spaceID)
        if layoutID.isEmpty {
            await handleWindowCreated(windowID, pid)
            return
        }

        // All checks passed: assign to target cell
        await gridState.prependWindow(windowID, toCellID: target.cellID, inSpace: target.spaceID)
        await gridState.setFocus(spaceID: target.spaceID, cellID: target.cellID, windowIndex: 0)

        // Apply layout to position all windows in the cell
        try? await gridApply?.applyCellLayout(spaceID: target.spaceID, cellID: target.cellID)

        // Focus the new window via accessibility
        _ = try? await gridFocus?.focusWindowByID(windowID)

        // Sync borders to reflect new assignment
        await syncBordersForCurrentSpace()

        jlog("reconcile.win.create.picker", data: ["wid": windowID, "cell": target.cellID])
    }

    private func handleFocusChanged(_ focusState: FocusState) async {
        guard let gridState, let stateManager, let windowID = focusState.windowID else { return }

        // During suppression (bulk ops: layout apply, picker, terminal, focus),
        // skip entirely -- the caller sets GridState focus explicitly.
        if suppressReconciliation {
            jlog("reconcile.focus.suppressed", data: ["wid": windowID])
            return
        }

        // Check fence: if this window is fenced, drop the OS event.
        // Fences are per-window: other windows' events pass through normally.
        if isWindowFenced(windowID) {
            jlog("reconcile.focus.fenced", data: ["wid": windowID])
            return
        }

        // Cell-level fence guard: if this window is NOT directly fenced but shares a
        // cell with a fenced window, drop the event. This prevents collateral OS focus
        // events (e.g., a previously-focused co-cell window surfacing briefly) from
        // overwriting the lastFocusedWid that a move command set intentionally.
        if await isCellMateOfFencedWindow(windowID) {
            jlog("reconcile.focus.fenced.cell", data: ["wid": windowID])
            return
        }

        // Resolve spaceID and displayUUID.
        // Primary: look up the window's actual space from GridState (authoritative
        // after moves, since we update GridState synchronously).
        // Fallback: metadata.activeSpaceID (for windows not yet in GridState).
        var spaceID: String
        var displayUUID: String

        if let gridSpaceID = await gridState.findSpaceContaining(windowID: windowID) {
            // Window is tracked in GridState — use its actual space
            spaceID = gridSpaceID
            let wmState = await stateManager.getState()
            displayUUID = findDisplayUUIDForSpace(gridSpaceID, from: wmState) ?? ""
        } else if focusState.spaceID != 0 {
            // Event carries space info (rare but handle it)
            spaceID = String(focusState.spaceID)
            displayUUID = focusState.displayUUID
        } else {
            // Window not in GridState — fall back to metadata
            let wmState = await stateManager.getState()
            guard let resolved = findCurrentSpaceID(from: wmState) else { return }
            spaceID = resolved
            displayUUID = findCurrentDisplayUUID(from: wmState) ?? ""
        }

        // Detect space change
        let spaceChanged = focusState.previousSpaceID != nil
            && focusState.previousSpaceID != focusState.spaceID
            && focusState.spaceID != 0

        if spaceChanged {
            await handleSpaceChanged(
                newSpaceID: spaceID,
                displayUUID: displayUUID
            )
        }

        // Update GridState focus to match OS focus
        let cellID = await gridState.getWindowCell(windowID: windowID, inSpace: spaceID)
        if let cellID {
            let cellWindows = await gridState.getCellWindows(spaceID: spaceID, cellID: cellID)
            let windowIndex = cellWindows.firstIndex(of: windowID) ?? 0
            await gridState.setFocus(spaceID: spaceID, cellID: cellID, windowIndex: windowIndex)
        }

        // Update border focus and sync
        if !displayUUID.isEmpty {
            simpleBorderManager?.updateFocus(
                newFocusedWindow: windowID,
                displayUUID: displayUUID
            )
            await syncBordersForSpace(spaceID, displayUUID: displayUUID)
        }
    }

    private func handleSpaceChanged(newSpaceID: String, displayUUID: String) async {
        // When user switches spaces, the new space may or may not have a layout
        guard let gridState else { return }

        let layoutID = await gridState.getCurrentLayout(spaceID: newSpaceID)
        if !layoutID.isEmpty {
            // Space has a layout -- sync borders for it
            await syncBordersForSpace(newSpaceID, displayUUID: displayUUID)
        }
        // No layout on this space -- borders will be empty
        // (SimpleBorderManager handles this via empty assignments on next sync)

        jlog("reconcile.space.change", data: ["space": newSpaceID, "display": displayUUID])
    }

    // macOS reassigned a space ID on a display (fullscreen app create/destroy).
    // Migrate GridState from the old ID to the new one so window assignments
    // survive, and reset AX orphan counts so the validator doesn't prune
    // windows that are only transiently invisible during the shuffle.
    private func handleSpaceIDReassigned(
        oldSpaceID: String,
        newSpaceID: String,
        displayUUID: String
    ) async {
        guard let gridState else { return }

        let migratedWids = await gridState.migrateSpace(from: oldSpaceID, to: newSpaceID)

        if !migratedWids.isEmpty {
            // Reset orphan tracking — these windows are real, just briefly
            // invisible to AX during the space ID transition.
            await stateValidator?.resetOrphanCounts(for: migratedWids)

            // Sync borders for the new space ID so they don't go blank.
            await syncBordersForSpace(newSpaceID, displayUUID: displayUUID)

            jlog("reconcile.space.reassign", data: [
                "old": oldSpaceID,
                "new": newSpaceID,
                "display": displayUUID,
                "migratedWindows": migratedWids.count,
            ])
        } else {
            jlog("reconcile.space.reassign.noop", data: [
                "old": oldSpaceID,
                "new": newSpaceID,
                "display": displayUUID,
            ])
        }
    }

    private func handleSystemWake() async {
        guard let stateManager, let gridState else { return }

        jlog("reconcile.wake.start")

        // Capture wmState once for consistency across all steps
        let wmState = await stateManager.getState()

        // Store the validation work as a tracked task so commands can await completion
        // via awaitWakeCompletion(). The task reference is cleared on completion.
        let task = Task { [weak self] in
            guard let self else { return }

            // Step 1: Migrate space IDs (macOS may reassign after sleep)
            var displaySpaces: [String: [String]] = [:]
            for display in wmState.displays {
                var spaceIDs: [String] = []
                for (spaceKey, space) in wmState.spaces {
                    if space.displayUUID == display.uuid {
                        spaceIDs.append(spaceKey)
                    }
                }
                // Sort by space ID for positional matching
                displaySpaces[display.uuid] = spaceIDs.sorted()
            }

            let migrated = await gridState.migrateSpaceIDs(currentDisplaySpaces: displaySpaces)
            if migrated {
                jlog("reconcile.wake.migrated")
            }

            // Step 1.5: Reset AX orphan counts before validate runs so
            // pre-sleep stale counts cannot push real windows past the
            // 2-cycle prune threshold during the wake stabilization window.
            await self.stateValidator?.resetAllOrphanCounts()

            // Step 2: Full state validation after migration.
            // Re-fetch wmState so validator sees correct space IDs post-migration.
            let freshWmState = await stateManager.getState()
            await self.stateValidator?.validate(wmState: freshWmState)

            // Step 2.5: Reapply layouts on every active space. Display
            // reconnect already does this (handleDisplayConnected); wake
            // must too, otherwise windows do not snap back into cells
            // after sleep. refreshAllDisplays does not throw — failures
            // are returned as a per-display error array.
            jlog("reconcile.wake.refresh.start")
            let refreshErrors = await self.gridApply?.refreshAllDisplays() ?? []
            if !refreshErrors.isEmpty {
                jlog("warn.reconcile.wake.refresh.errors",
                     data: ["errorCount": refreshErrors.count])
            }

            // Step 3: Sync borders for current space
            await self.syncBordersForCurrentSpace()

            jlog("reconcile.wake.done")

            // Clear the task reference so subsequent commands pass through immediately
            self.wakeValidationTask = nil
        }
        wakeValidationTask = task

        // Await the task so handleSystemWake() itself doesn't return until
        // everything is done. This preserves the existing guarantee that wake
        // handling is synchronous from the event handler's perspective.
        await task.value
    }

    private func handleWindowMoved(_ windowID: UInt32, _ frame: CGRect) {
        // Forward to border manager for position tracking
        simpleBorderManager?.handleWindowMoved(windowID: windowID, newFrame: frame)
    }

    private func handleWindowMinimized(_ windowID: UInt32) async {
        // Minimized window should be removed from cell assignment
        guard let gridState else { return }

        let currentSpaceID = await findCurrentSpaceIDAsync()
        if let spaceID = currentSpaceID {
            await gridState.removeWindow(windowID, fromSpace: spaceID)
            await syncBordersForCurrentSpace()
        }

        jlog("reconcile.win.min", data: ["wid": windowID])
    }

    private func handleWindowDeminimized(_ windowID: UInt32) async {
        // Treat like a new window creation for tiling purposes
        guard let stateManager else { return }
        let wmState = await stateManager.getState()
        guard let windowState = wmState.windows[String(windowID)] else { return }

        let pid = windowState.pid
        await handleWindowCreated(windowID, pid)

        jlog("reconcile.win.unmin", data: ["wid": windowID])
    }

    // handleDisplayConnected
    //
    // Triggered when a display is reconnected (e.g., external monitor plugged back in).
    // GridState retains the layout and window assignments from before disconnect.
    // Re-syncs borders and reapplies layouts for the reconnected display.
    private func handleDisplayConnected(_ displayUUID: String) async {
        jlog("reconcile.display.connect", data: ["display": displayUUID])

        // Short delay allows macOS to stabilize space/window state after reconnect
        // before we query it. Without this, wmState may not yet reflect new spaces.
        // 500ms is enough for display negotiation; short enough to feel instant.
        try? await Task.sleep(for: .milliseconds(500))

        // Reapply layouts and sync borders for the reconnected display.
        // refreshAllDisplays handles: find active space, check layout,
        // reapply window positions, sync borders.
        let errors = await gridApply?.refreshAllDisplays(displayFilter: displayUUID) ?? []

        if !errors.isEmpty {
            jlog("warn.reconcile.display.connect.errors",
                 data: ["display": displayUUID, "errorCount": errors.count])
        }
    }

    // handleDisplayDisconnected
    //
    // Enhanced disconnect handler. Previous behavior only cleaned up borders.
    // New behavior also prunes GridState window assignments for spaces on the
    // disconnected display, preventing zombies from accumulating.
    //
    // Why windows but not spaces: macOS may keep space IDs alive for disconnected
    // displays. pruneDeadSpaces() (StateValidator) handles space cleanup when the
    // IDs are actually gone. Removing windows eagerly prevents zombie assignments
    // in cells while preserving layout config for reconnect.
    private func handleDisplayDisconnected(_ displayUUID: String) async {
        jlog("reconcile.display.disconnect", data: ["display": displayUUID])

        // Existing: clean up border state for this display
        simpleBorderManager?.handleDisplayDisconnected(displayUUID: displayUUID)

        // New: prune GridState window assignments for spaces on this display
        guard let gridState, let stateManager else { return }
        let wmState = await stateManager.getState()

        // Find all space IDs that belong to this display in the current wmState
        let affectedSpaceIDs = wmState.spaces.compactMap { (spaceID, space) -> String? in
            space.displayUUID == displayUUID ? spaceID : nil
        }

        if affectedSpaceIDs.isEmpty {
            jlog("reconcile.display.disconnect.no_spaces", data: ["display": displayUUID])
            return
        }

        // For each affected space, remove all window assignments.
        // Windows will reappear via windowCreated events when the display reconnects
        // and the user's apps are still running.
        for spaceID in affectedSpaceIDs {
            let assignments = await gridState.getWindowAssignments(spaceID: spaceID)
            for (_, windowIDs) in assignments {
                for windowID in windowIDs {
                    await gridState.removeWindow(windowID, fromSpace: spaceID)
                    jlog("reconcile.display.disconnect.prune",
                         data: ["wid": Int(windowID), "space": spaceID, "display": displayUUID])
                }
            }
        }
    }

    // MARK: - Border Sync

    private func syncBordersForCurrentSpace(source: String = "reconcile") async {
        // Get current space and display from StateManager
        guard let stateManager else { return }

        let wmState = await stateManager.getState()
        guard let spaceID = findCurrentSpaceID(from: wmState),
              let displayUUID = findCurrentDisplayUUID(from: wmState) else {
            return
        }

        await syncBordersForSpace(spaceID, displayUUID: displayUUID, source: source)
    }

    // Compute the live wids known to StateManager for a display — used as the
    // `live_wids` payload on bdr.empty so post-mortem can tell what windows
    // the state machine believed existed when an empty assignment was sent.
    private func computeLiveWids(displayUUID: String, wmState: WindowManagerState) -> [UInt32] {
        var wids: [UInt32] = []
        for (_, win) in wmState.windows {
            if win.displayUUID == displayUUID {
                wids.append(win.id)
            }
        }
        return wids
    }

    func syncBordersForSpace(_ spaceID: String, displayUUID: String, source: String = "reconcile") async {
        guard let gridState, let gridConfig else { return }

        // Get layout for this space
        let layoutID = await gridState.getCurrentLayout(spaceID: spaceID)
        guard !layoutID.isEmpty else {
            // No layout -- clear borders by sending empty assignments
            if let borderManager = simpleBorderManager {
                let liveWids: [UInt32]
                if let stateManager {
                    let wmState = await stateManager.getState()
                    liveWids = computeLiveWids(displayUUID: displayUUID, wmState: wmState)
                } else {
                    liveWids = []
                }
                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    borderManager.setCellAssignments(
                        [:],
                        forDisplay: displayUUID,
                        source: "no_layout:\(source)",
                        liveWids: liveWids,
                        completion: { continuation.resume() }
                    )
                }
            }
            return
        }

        // Get layout definition (GridConfig is @MainActor)
        let layoutDef: GridLayoutDef
        do {
            layoutDef = try await MainActor.run { try gridConfig.getLayout(id: layoutID) }
        } catch {
            return
        }

        // Get display bounds for layout calculation
        guard let stateManager else { return }
        let wmState = await stateManager.getState()
        guard let bounds = findDisplayBounds(displayUUID: displayUUID, from: wmState) else {
            return
        }

        // Calculate cell bounds
        let columnRatios = await gridState.getColumnRatios(spaceID: spaceID)
        let rowRatios = await gridState.getRowRatios(spaceID: spaceID)
        let baseSpacing = await MainActor.run { gridConfig.getBaseSpacing() }
        // Calculate layout to validate it exists; cell bounds used by border manager
        _ = GridLayout.calculateLayoutWithRatios(
            layout: layoutDef,
            screenRect: bounds,
            gap: baseSpacing,
            columnRatios: columnRatios,
            rowRatios: rowRatios
        )

        // Build window-to-cell assignments map
        let spaceAssignments = await gridState.getWindowAssignments(spaceID: spaceID)
        var windowToCellMap: [UInt32: String] = [:]
        var cellStackModes: [String: String] = [:]
        var windowOrder: [String: [UInt32]] = [:]

        for (cellID, windowIDs) in spaceAssignments {
            for wid in windowIDs {
                windowToCellMap[wid] = cellID
            }
            windowOrder[cellID] = windowIDs

            // Get stack mode for cell
            let mode = await gridState.getCellStackMode(spaceID: spaceID, cellID: cellID)
            cellStackModes[cellID] = mode?.rawValue ?? "tabs"
        }

        // Get focused window
        let focusedWID = await gridState.getFocusedWindow(spaceID: spaceID)

        // Send to SimpleBorderManager and await completion on main queue.
        // withCheckedContinuation bridges the DispatchQueue.main.async boundary
        // so that fence releases in GridWindowMove wait for border work to finish.
        if let borderManager = simpleBorderManager {
            let liveWids = computeLiveWids(displayUUID: displayUUID, wmState: wmState)
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                borderManager.setCellAssignments(
                    windowToCellMap,
                    forDisplay: displayUUID,
                    focusedWindowID: focusedWID != 0 ? focusedWID : nil,
                    cellStackModes: cellStackModes,
                    windowOrder: windowOrder,
                    displayFrame: bounds,
                    source: source,
                    liveWids: liveWids,
                    completion: { continuation.resume() }
                )
            }
        }
    }

    // MARK: - Helpers

    private func findCurrentSpaceID(from wmState: WindowManagerState) -> String? {
        // Use metadata.activeSpaceID which tracks the focused display's space
        // (with multiple monitors, each display has its own active space)
        if let activeSpaceID = wmState.metadata.activeSpaceID {
            return String(activeSpaceID)
        }
        for (spaceKey, space) in wmState.spaces {
            if space.isActive {
                return spaceKey
            }
        }
        return nil
    }

    private func findCurrentDisplayUUID(from wmState: WindowManagerState) -> String? {
        // Use metadata.activeDisplayUUID which tracks the focused display
        if let activeDisplayUUID = wmState.metadata.activeDisplayUUID {
            return activeDisplayUUID
        }
        for (_, space) in wmState.spaces {
            if space.isActive {
                return space.displayUUID
            }
        }
        return nil
    }

    private func findDisplayUUIDForSpace(_ spaceID: String, from wmState: WindowManagerState) -> String? {
        for display in wmState.displays {
            if String(display.currentSpaceID) == spaceID {
                return display.uuid
            }
        }
        return nil
    }

    private func findDisplayBounds(displayUUID: String, from wmState: WindowManagerState) -> CGRect? {
        for display in wmState.displays {
            if display.uuid == displayUUID {
                return display.visibleFrame ?? display.frame
            }
        }
        return nil
    }

    private func findLeastPopulatedCell(
        _ assignments: [String: [UInt32]],
        excludeCells: Set<String> = []
    ) -> String {
        let candidates = assignments.keys.filter { !excludeCells.contains($0) }
        return candidates.sorted().min { a, b in
            (assignments[a]?.count ?? 0) < (assignments[b]?.count ?? 0)
        } ?? ""
    }

    private func findCurrentSpaceIDAsync() async -> String? {
        guard let stateManager else { return nil }
        let wmState = await stateManager.getState()
        return findCurrentSpaceID(from: wmState)
    }
}
