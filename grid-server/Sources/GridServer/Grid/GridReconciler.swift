//
// GridReconciler.swift
// GridServer
//
// Event-driven reconciler: subscribes to EventRouter, updates GridState,
// and syncs borders via SimpleBorderManager.
//

import Foundation
import CoreGraphics

class GridReconciler: StateEventHandler {

    // Dependencies (set via setup)
    private weak var gridState: GridState?
    private weak var gridConfig: GridConfig?
    private weak var stateManager: StateManager?
    private weak var simpleBorderManager: SimpleBorderManager?

    // Suppression flag for bulk operations (layout apply)
    private var suppressReconciliation: Bool = false

    init() {}

    // MARK: - Public API

    // Set suppression (called by GridApply in Phase 6)
    func setSuppressed(_ suppressed: Bool) {
        suppressReconciliation = suppressed
        if !suppressed {
            // Unsuppressed: trigger a full border sync for current space
            Task {
                await syncBordersForCurrentSpace()
            }
        }
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
        // Always track focus even when suppressed
        if case .focusChanged(let focusState) = event {
            await handleFocusChanged(focusState)
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
        guard let stateManager else { return }
        let wmState = await stateManager.getState()

        // Find the current space ID from active spaces
        guard let spaceID = findCurrentSpaceID(from: wmState) else { return }

        // Check if there's an active layout for this space
        guard let gridState else { return }
        let layoutID = await gridState.getCurrentLayout(spaceID: spaceID)
        if layoutID.isEmpty { return }

        // Get the window state from StateManager
        guard let windowState = wmState.windows[String(windowID)] else { return }

        // Check if window is tileable
        guard isTileable(window: windowState) else { return }

        // Check window classification
        let appName = windowState.appName ?? ""
        let category = classifyWindow(window: windowState, appName: appName)
        if category != .standard { return }

        // Auto-assign: find least-populated cell
        let assignments = await gridState.getWindowAssignments(spaceID: spaceID)
        let leastPopulatedCell = findLeastPopulatedCell(assignments)

        if !leastPopulatedCell.isEmpty {
            await gridState.assignWindow(windowID, toCellID: leastPopulatedCell, inSpace: spaceID)

            // Sync borders after assignment
            await syncBordersForCurrentSpace()
        }

        jlog("reconcile.win.create", data: ["wid": windowID, "cell": leastPopulatedCell])
    }

    private func handleFocusChanged(_ focusState: FocusState) async {
        // Always track focus, even when suppressed
        let spaceID = String(focusState.spaceID)
        guard let gridState, let windowID = focusState.windowID else { return }

        // Detect space change
        let spaceChanged = focusState.previousSpaceID != nil
            && focusState.previousSpaceID != focusState.spaceID

        if spaceChanged {
            await handleSpaceChanged(
                newSpaceID: spaceID,
                displayUUID: focusState.displayUUID
            )
        }

        // Update GridState focus to match OS focus
        let cellID = await gridState.getWindowCell(windowID: windowID, inSpace: spaceID)
        if let cellID {
            // Find window index in cell
            let cellWindows = await gridState.getCellWindows(spaceID: spaceID, cellID: cellID)
            let windowIndex = cellWindows.firstIndex(of: windowID) ?? 0
            await gridState.setFocus(spaceID: spaceID, cellID: cellID, windowIndex: windowIndex)
        }

        // Update border focus (always, even when suppressed for focus tracking,
        // but skip border sync when suppressed)
        if !suppressReconciliation {
            simpleBorderManager?.updateFocus(
                newFocusedWindow: windowID,
                displayUUID: focusState.displayUUID
            )
        }

        // If display changed, sync borders for new display
        if focusState.previousDisplayUUID != nil
            && focusState.previousDisplayUUID != focusState.displayUUID {
            // Cross-display focus change: sync borders for new display
            if !suppressReconciliation {
                await syncBordersForSpace(spaceID, displayUUID: focusState.displayUUID)
            }
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

    private func syncBordersForSpace(_ spaceID: String, displayUUID: String) async {
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
        for (spaceKey, space) in wmState.spaces {
            if space.isActive {
                return spaceKey
            }
        }
        return nil
    }

    private func findCurrentDisplayUUID(from wmState: WindowManagerState) -> String? {
        for (_, space) in wmState.spaces {
            if space.isActive {
                return space.displayUUID
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
