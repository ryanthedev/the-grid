//
// GridReconciler.swift
// GridServer
//
// Event-driven reconciler: subscribes to EventRouter, updates GridState,
// and syncs borders via SimpleBorderManager.
//

import Foundation
import CoreGraphics

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

    // One-shot target: next tileable window created on target space claims this cell
    private var pendingLaunchTarget: PendingLaunchTarget?

    // Timeout for pending launch target (app may take time to launch)
    private let pendingLaunchTimeout: CFAbsoluteTime = 15.0

    // Ref-counted suppression for bulk operations (layout apply, picker, moves).
    // Multiple callers can nest suppress/unsuppress without interfering.
    private var suppressionDepth: Int = 0
    private var suppressReconciliation: Bool { suppressionDepth > 0 }

    // Move cooldown: after a cross-display move, ignore OS focus events
    // for non-target windows to prevent delayed appActivated from
    // bouncing borders to wrong windows.
    private var moveTargetWindowID: UInt32 = 0
    private var moveEndTime: CFAbsoluteTime = 0
    private let moveCooldownSeconds: CFAbsoluteTime = 1.0

    init() {}

    // MARK: - Public API

    // Increment/decrement suppression depth (called by GridApply, GridWindowMove, PickerManager).
    // syncOnResume: if true, triggers syncBordersForCurrentSpace when depth reaches 0.
    func setSuppressed(_ suppressed: Bool, syncOnResume: Bool = true) {
        if suppressed {
            suppressionDepth += 1
            jlog("reconcile.suppress.inc", data: ["depth": suppressionDepth])
        } else {
            if suppressionDepth <= 0 {
                jlog("warn.reconcile.suppress.underflow")
            }
            suppressionDepth = max(0, suppressionDepth - 1)
            jlog("reconcile.suppress.dec", data: ["depth": suppressionDepth])
            if suppressionDepth == 0 && syncOnResume {
                Task {
                    await syncBordersForCurrentSpace()
                }
            }
        }
    }

    // Track cross-display move target so we can ignore spurious OS focus events.
    // Call beginMove before the move, endMove after explicit border syncs.
    func beginMove(targetWindowID: UInt32) {
        moveTargetWindowID = targetWindowID
        suppressionDepth += 1
    }

    func endMove() {
        suppressionDepth = max(0, suppressionDepth - 1)
        moveEndTime = CFAbsoluteTimeGetCurrent()
    }

    // Clear move cooldown so explicit user actions (focus commands)
    // aren't suppressed by stale move tracking
    func clearMoveCooldown() {
        moveTargetWindowID = 0
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

    private var isInMoveCooldown: Bool {
        moveTargetWindowID != 0
            && (CFAbsoluteTimeGetCurrent() - moveEndTime) < moveCooldownSeconds
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

        jlog("reconcile.init")
    }

    // MARK: - StateEventHandler

    func handle(_ event: StateEvent, context: EventContext) async throws {
        // Focus events handle suppression/cooldown internally
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

        case .displayDisconnected(let displayUUID):
            handleDisplayDisconnected(displayUUID)

        default:
            // Ignore other events (app lifecycle, title changes, etc.)
            break
        }
    }

    // MARK: - Event Handlers

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

        // Auto-assign: find least-populated cell
        let leastPopulatedCell = findLeastPopulatedCell(assignments)

        if !leastPopulatedCell.isEmpty {
            await gridState.assignWindow(windowID, toCellID: leastPopulatedCell, inSpace: spaceID)

            // Sync borders after assignment
            await syncBordersForCurrentSpace()
        }

        jlog("reconcile.win.create", data: ["wid": windowID, "cell": leastPopulatedCell])
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
        try? await gridFocus?.focusWindowByID(windowID)

        // Sync borders to reflect new assignment
        await syncBordersForCurrentSpace()

        jlog("reconcile.win.create.picker", data: ["wid": windowID, "cell": target.cellID])
    }

    private func handleFocusChanged(_ focusState: FocusState) async {
        guard let gridState, let stateManager, let windowID = focusState.windowID else { return }

        // During suppression (active move), skip entirely — our move code
        // sets GridState focus explicitly, and OS events would overwrite it.
        if suppressReconciliation {
            jlog("reconcile.focus.suppressed", data: ["wid": windowID])
            return
        }

        // During cooldown after a cross-display move, skip ALL focus events.
        // The explicit border syncs already set correct state. OS fires delayed
        // appActivated events for 1-3 seconds that would undo our work.
        if isInMoveCooldown {
            jlog("reconcile.focus.cooldown", data: [
                "ignored": windowID,
                "expected": moveTargetWindowID,
                "age_ms": Int((CFAbsoluteTimeGetCurrent() - moveEndTime) * 1000),
            ])
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

    private func handleSystemWake() async {
        // Migrate space IDs (macOS may reassign them after sleep)
        guard let stateManager, let gridState else { return }
        let wmState = await stateManager.getState()

        // Build display -> space ID list map
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

        // After migration, sync borders for current space
        await syncBordersForCurrentSpace()
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

    private func handleDisplayDisconnected(_ displayUUID: String) {
        simpleBorderManager?.handleDisplayDisconnected(displayUUID: displayUUID)
    }

    // MARK: - Border Sync

    private func syncBordersForCurrentSpace() async {
        // Get current space and display from StateManager
        guard let stateManager else { return }

        let wmState = await stateManager.getState()
        guard let spaceID = findCurrentSpaceID(from: wmState),
              let displayUUID = findCurrentDisplayUUID(from: wmState) else {
            return
        }

        await syncBordersForSpace(spaceID, displayUUID: displayUUID)
    }

    func syncBordersForSpace(_ spaceID: String, displayUUID: String) async {
        guard let gridState, let gridConfig else { return }

        // Get layout for this space
        let layoutID = await gridState.getCurrentLayout(spaceID: spaceID)
        guard !layoutID.isEmpty else {
            // No layout -- clear borders by sending empty assignments
            simpleBorderManager?.setCellAssignments([:], forDisplay: displayUUID)
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

        // Send to SimpleBorderManager (atomic update with focus)
        simpleBorderManager?.setCellAssignments(
            windowToCellMap,
            forDisplay: displayUUID,
            focusedWindowID: focusedWID != 0 ? focusedWID : nil,
            cellStackModes: cellStackModes,
            windowOrder: windowOrder,
            displayFrame: bounds
        )
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

    private func findLeastPopulatedCell(_ assignments: [String: [UInt32]]) -> String {
        return assignments.keys.sorted().min { a, b in
            (assignments[a]?.count ?? 0) < (assignments[b]?.count ?? 0)
        } ?? ""
    }

    private func findCurrentSpaceIDAsync() async -> String? {
        guard let stateManager else { return nil }
        let wmState = await stateManager.getState()
        return findCurrentSpaceID(from: wmState)
    }
}
