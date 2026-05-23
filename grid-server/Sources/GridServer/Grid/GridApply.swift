import AppKit
import Foundation
import CoreGraphics

// MARK: - Apply Options

struct GridApplyOptions: Sendable {
    var strategy: GridAssignmentStrategy = .position
    var displayFilter: String? = nil
}

// MARK: - Display Error

struct GridDisplayError: Sendable {
    let displayUUID: String
    let displayName: String
    let error: Error
}

// MARK: - Apply Errors

enum GridApplyError: Error, LocalizedError {
    case noLayout
    case layoutNotFound(String)
    case noDisplayBounds
    case allDisplaysFailed([GridDisplayError])

    var errorDescription: String? {
        switch self {
        case .noLayout: return "no layout applied"
        case .layoutNotFound(let id): return "layout not found: \(id)"
        case .noDisplayBounds: return "no display bounds"
        case .allDisplaysFailed(let errors): return "all displays failed: \(errors.count) errors"
        }
    }
}

// MARK: - GridApply

class GridApply {

    // Dependencies (weak references, set via setup)
    private weak var gridState: GridState?
    private weak var gridConfig: GridConfig?
    private weak var stateProvider: (any StateProvider)?
    private weak var windowController: (any WindowController)?
    private weak var gridReconciler: GridReconciler?
    private weak var simpleBorderManager: SimpleBorderManager?
    private weak var gridFocus: GridFocus?

    init() {}

    func setup(
        gridState: GridState,
        gridConfig: GridConfig,
        stateProvider: any StateProvider,
        windowController: any WindowController,
        gridReconciler: GridReconciler,
        simpleBorderManager: SimpleBorderManager,
        gridFocus: GridFocus
    ) {
        self.gridState = gridState
        self.gridConfig = gridConfig
        self.stateProvider = stateProvider
        self.windowController = windowController
        self.gridReconciler = gridReconciler
        self.simpleBorderManager = simpleBorderManager
        self.gridFocus = gridFocus
        jlog("apply.init")
    }

    // ============================================================
    // PUBLIC: applyLayout - full layout application orchestrator
    // ============================================================

    func applyLayout(
        spaceID: String,
        layoutID: String,
        strategy: GridAssignmentStrategy = .position
    ) async throws {
        guard let gridState = gridState,
              let gridConfig = gridConfig,
              let stateProvider = stateProvider,
              let gridFocus = gridFocus else {
            throw GridApplyError.noLayout
        }

        // syncBorders: false because applyLayout does its own syncBordersForSpace
        // at the end (step 14) with explicit space/display parameters. The generic
        // syncBordersForCurrentSpace would be redundant and potentially wrong
        // (it might sync the wrong display in multi-monitor setups).
        // If reconciler is nil (shouldn't happen but guard), run body directly.
        if let reconciler = gridReconciler {
            try await reconciler.executeAction(label: "layout.apply", syncBorders: false) {
                try await self.applyLayoutBody(
                    spaceID: spaceID,
                    layoutID: layoutID,
                    strategy: strategy,
                    gridState: gridState,
                    gridConfig: gridConfig,
                    stateProvider: stateProvider,
                    gridFocus: gridFocus
                )
            }
        } else {
            try await applyLayoutBody(
                spaceID: spaceID,
                layoutID: layoutID,
                strategy: strategy,
                gridState: gridState,
                gridConfig: gridConfig,
                stateProvider: stateProvider,
                gridFocus: gridFocus
            )
        }
    }

    // applyLayoutBody: the actual layout application work, extracted so executeAction
    // can wrap it without duplicating the guard-let boilerplate.
    private func applyLayoutBody(
        spaceID: String,
        layoutID: String,
        strategy: GridAssignmentStrategy,
        gridState: GridState,
        gridConfig: GridConfig,
        stateProvider: any StateProvider,
        gridFocus: GridFocus
    ) async throws {
        jlog("layout.apply.start", data: ["lid": layoutID, "sid": spaceID])

        // 1. Get layout definition
        let layoutDef = try await MainActor.run { try gridConfig.getLayout(id: layoutID) }

        // 2. Get display bounds for this space
        let wmState = await stateProvider.getState()
        let displayBounds = gridFocus.getDisplayBoundsForSpace(spaceID, wmState: wmState)

        // 3. Get existing track ratios (preserve when reapplying same layout)
        let existingLayoutID = await gridState.getCurrentLayout(spaceID: spaceID)
        var columnRatios: [Double]? = nil
        var rowRatios: [Double]? = nil
        if existingLayoutID == layoutID {
            columnRatios = await gridState.getColumnRatios(spaceID: spaceID)
            rowRatios = await gridState.getRowRatios(spaceID: spaceID)
        }

        // 4. Calculate grid layout (gap=0, padding handles spacing)
        let calculated = GridLayout.calculateLayoutWithRatios(
            layout: layoutDef,
            screenRect: displayBounds,
            gap: 0,
            columnRatios: columnRatios,
            rowRatios: rowRatios
        )

        // 5. Filter tileable windows from StateManager
        let exclusions = await MainActor.run { gridConfig.getWindowExclusions() }
        let rejected = await gridState.getRejectedWindows()
        let tileableWindows = filterTileableFromState(
            wmState: wmState,
            spaceID: spaceID,
            exclusions: exclusions,
            rejectedWindows: rejected
        )

        // 6. Get previous assignments from GridState
        let previousAssignments = await gridState.getWindowAssignments(spaceID: spaceID)

        // 7. Assign windows to cells
        let appRules = await MainActor.run { gridConfig.appRules }
        let assignment = GridAssignment.assignWindows(
            windows: tileableWindows,
            layout: layoutDef,
            cellBounds: calculated.cellBounds,
            appRules: appRules,
            previousAssignments: previousAssignments,
            strategy: strategy,
            bundleIDLookup: { pid in
                wmState.applications[String(pid)]?.bundleIdentifier
            }
        )

        // 8. Build cell modes and ratios from config+state
        let allCellIDs = layoutDef.cells.map { $0.id }
        var cellModes: [String: GridStackMode] = [:]
        var cellRatios: [String: [Double]] = [:]

        for cellID in allCellIDs {
            // layout cell-level stackMode
            for cell in layoutDef.cells {
                if cell.id == cellID && cell.stackMode != nil {
                    cellModes[cellID] = cell.stackMode!
                    break
                }
            }
            // layout cellModes map
            if let mode = layoutDef.cellModes[cellID] {
                cellModes[cellID] = mode
            }
            // state override
            if let stateMode = await gridState.getCellStackMode(spaceID: spaceID, cellID: cellID) {
                cellModes[cellID] = stateMode
            }

            let ratios = await gridState.getCellSplitRatios(spaceID: spaceID, cellID: cellID)
            if !ratios.isEmpty {
                // Adjust ratios to match actual window count
                let windowCount = assignment.assignments[cellID]?.count ?? 0
                if ratios.count != windowCount {
                    cellRatios[cellID] = GridLayout.adjustRatiosForWindowCount(ratios, newCount: windowCount)
                } else {
                    cellRatios[cellID] = ratios
                }
            }
        }

        // 9. Calculate window placements
        let baseSpacing = await MainActor.run { gridConfig.getBaseSpacing() }
        let settingsPadding = await MainActor.run { gridConfig.getSettingsPadding() }
        let settingsWindowSpacing = await MainActor.run { gridConfig.getSettingsWindowSpacing() }
        let defaultMode = await MainActor.run { gridConfig.settings.defaultStackMode }

        var placements = GridLayout.calculateAllWindowPlacements(
            calculatedLayout: calculated,
            layout: layoutDef,
            assignments: assignment.assignments,
            cellModes: cellModes,
            cellRatios: cellRatios,
            defaultMode: defaultMode,
            baseSpacing: baseSpacing,
            settingsPadding: settingsPadding,
            settingsWindowSpacing: settingsWindowSpacing
        )

        // 10. Apply display offset
        let displayUUID = gridFocus.findCurrentDisplayUUID(wmState, spaceID)
        let displayName = findDisplayName(displayUUID, wmState: wmState)
        let offset = await MainActor.run { gridConfig.getDisplayOffset(uuid: displayUUID, name: displayName) }
        if offset.x != 0 || offset.y != 0 {
            placements = placements.map { p in
                GridWindowPlacement(
                    windowID: p.windowID,
                    bounds: p.bounds.offsetBy(dx: offset.x, dy: offset.y)
                )
            }
        }

        // 11. Apply placements via WindowManipulator (parallel via TaskGroup)
        let failedIDs = await applyPlacementsViaAX(placements)

        // 12. Keep assignments even if AX placement failed — windows that can't be
        //     resized (e.g. iOS Simulator) still belong to their cell. Dead windows
        //     are cleaned up by reconciler destroy events.
        let finalAssignments = assignment.assignments
        if !failedIDs.isEmpty {
            jlog("layout.apply.ax_partial", data: ["failed": failedIDs.sorted()])
        }

        // 13. Update GridState
        if existingLayoutID != layoutID {
            // Switching layouts: reset state
            let layoutIndex = await MainActor.run { gridConfig.getLayoutIDs().firstIndex(of: layoutID) ?? 0 }
            await gridState.setCurrentLayout(spaceID: spaceID, layoutID: layoutID, layoutIndex: layoutIndex)
        }

        await gridState.setWindowAssignments(spaceID: spaceID, assignments: finalAssignments)

        // 14. Sync borders (explicit space/display -- not generic "current space")
        await gridReconciler?.syncBordersForSpace(spaceID, displayUUID: displayUUID)

        jlog("layout.apply.done", data: ["lid": layoutID, "placements": placements.count])
    }

    // ============================================================
    // PUBLIC: reapplyLayout - reapply current layout with optional strategy override
    // ============================================================

    func reapplyLayout(
        spaceID: String,
        strategy: GridAssignmentStrategy = .preserve
    ) async throws {
        guard let gridState = gridState else {
            throw GridApplyError.noLayout
        }

        let layoutID = await gridState.getCurrentLayout(spaceID: spaceID)
        guard !layoutID.isEmpty else {
            throw GridApplyError.noLayout
        }

        try await applyLayout(spaceID: spaceID, layoutID: layoutID, strategy: strategy)
    }

    // ============================================================
    // PUBLIC: applyCellLayout - apply layout changes to a single cell only
    // ============================================================

    func applyCellLayout(spaceID: String, cellID: String) async throws {
        guard let gridState = gridState,
              let gridConfig = gridConfig,
              let stateProvider = stateProvider,
              let gridFocus = gridFocus else {
            throw GridApplyError.noLayout
        }

        jlog("layout.cell.start", data: ["cellID": cellID, "sid": spaceID])

        // 1. Get layout
        let layoutID = await gridState.getCurrentLayout(spaceID: spaceID)
        guard !layoutID.isEmpty else {
            throw GridApplyError.noLayout
        }
        let layoutDef = try await MainActor.run { try gridConfig.getLayout(id: layoutID) }

        // 2. Get display bounds
        let wmState = await stateProvider.getState()
        let displayBounds = gridFocus.getDisplayBoundsForSpace(spaceID, wmState: wmState)

        // 3. Calculate full layout (needed for cell bounds with track ratios)
        let columnRatios = await gridState.getColumnRatios(spaceID: spaceID)
        let rowRatios = await gridState.getRowRatios(spaceID: spaceID)
        let calculated = GridLayout.calculateLayoutWithRatios(
            layout: layoutDef,
            screenRect: displayBounds,
            gap: 0,
            columnRatios: columnRatios,
            rowRatios: rowRatios
        )

        // 4. Get target cell's windows
        let cellWindows = await gridState.getCellWindows(spaceID: spaceID, cellID: cellID)
        if cellWindows.isEmpty {
            return
        }

        // 5. Build single-cell assignment
        let singleAssignment = [cellID: cellWindows]

        // 6. Build cell modes + ratios
        var cellModes: [String: GridStackMode] = [:]
        if let stateMode = await gridState.getCellStackMode(spaceID: spaceID, cellID: cellID) {
            cellModes[cellID] = stateMode
        }

        var cellRatios: [String: [Double]] = [:]
        let ratios = await gridState.getCellSplitRatios(spaceID: spaceID, cellID: cellID)
        if !ratios.isEmpty {
            cellRatios[cellID] = ratios
        }

        // 7. Calculate placements for this cell
        let baseSpacing = await MainActor.run { gridConfig.getBaseSpacing() }
        let settingsPadding = await MainActor.run { gridConfig.getSettingsPadding() }
        let settingsWindowSpacing = await MainActor.run { gridConfig.getSettingsWindowSpacing() }
        let defaultMode = await MainActor.run { gridConfig.settings.defaultStackMode }

        var placements = GridLayout.calculateAllWindowPlacements(
            calculatedLayout: calculated,
            layout: layoutDef,
            assignments: singleAssignment,
            cellModes: cellModes,
            cellRatios: cellRatios,
            defaultMode: defaultMode,
            baseSpacing: baseSpacing,
            settingsPadding: settingsPadding,
            settingsWindowSpacing: settingsWindowSpacing
        )

        // 8. Apply display offset
        let displayUUID = gridFocus.findCurrentDisplayUUID(wmState, spaceID)
        let displayName = findDisplayName(displayUUID, wmState: wmState)
        let offset = await MainActor.run { gridConfig.getDisplayOffset(uuid: displayUUID, name: displayName) }
        if offset.x != 0 || offset.y != 0 {
            placements = placements.map { p in
                GridWindowPlacement(
                    windowID: p.windowID,
                    bounds: p.bounds.offsetBy(dx: offset.x, dy: offset.y)
                )
            }
        }

        // 9. Apply placements
        await applyPlacementsViaAX(placements)

        // 10. Sync borders
        await gridReconciler?.syncBordersForSpace(spaceID, displayUUID: displayUUID)
    }

    // ============================================================
    // PUBLIC: refreshAllDisplays - refresh layouts on all connected displays
    // ============================================================

    func refreshAllDisplays(displayFilter: String? = nil) async -> [GridDisplayError] {
        guard let stateProvider = stateProvider,
              let gridState = gridState,
              let gridConfig = gridConfig else {
            return []
        }

        jlog("layout.refresh_all.start")

        let wmState = await stateProvider.getState()
        var errors: [GridDisplayError] = []
        var processedCount = 0

        for display in wmState.displays {
            // Skip if display filter is set and doesn't match
            if let filter = displayFilter, display.uuid != filter {
                continue
            }
            processedCount += 1

            // Find active space ID for this display
            guard let spaceID = findSpaceIDForDisplay(display.uuid, wmState: wmState) else {
                errors.append(GridDisplayError(
                    displayUUID: display.uuid,
                    displayName: display.name ?? "unknown",
                    error: GridApplyError.noDisplayBounds
                ))
                continue
            }

            // Check if space has existing layout state
            let layoutID = await gridState.getCurrentLayout(spaceID: spaceID)
            let strategy: GridAssignmentStrategy
            let targetLayoutID: String

            if !layoutID.isEmpty {
                // Reapply existing layout with preserve strategy
                targetLayoutID = layoutID
                strategy = .preserve
            } else {
                // No layout: apply default
                let defaultLayoutDef: GridLayoutDef? = try? await MainActor.run { try gridConfig.getLayout(id: "default") }
                if defaultLayoutDef != nil {
                    targetLayoutID = "default"
                } else {
                    targetLayoutID = "single-tabbed"
                }
                strategy = .position
            }

            // Apply layout
            do {
                try await applyLayout(spaceID: spaceID, layoutID: targetLayoutID, strategy: strategy)
            } catch {
                errors.append(GridDisplayError(
                    displayUUID: display.uuid,
                    displayName: display.name ?? "unknown",
                    error: error
                ))
            }
        }

        if let filter = displayFilter, processedCount == 0 {
            errors.append(GridDisplayError(
                displayUUID: filter,
                displayName: "unknown",
                error: GridApplyError.noDisplayBounds
            ))
        }

        jlog("layout.refresh_all.done", data: ["processed": processedCount, "errors": errors.count])
        return errors
    }

    // ============================================================
    // PRIVATE: Shared helpers
    // ============================================================

    // applyPlacementsViaAX: position windows via WindowManipulator
    // Own-process windows (notification panel) use NSWindow.setFrame on MainActor
    // because AX calls on own-process windows execute in-place on the calling
    // thread, crashing AppKit's main-thread assertion.
    @discardableResult
    private func applyPlacementsViaAX(_ placements: [GridWindowPlacement]) async -> Set<UInt32> {
        if placements.isEmpty { return [] }

        let serverPID = ProcessInfo.processInfo.processIdentifier

        let failedIDs = await withTaskGroup(of: UInt32?.self, returning: Set<UInt32>.self) { group in
            for placement in placements {
                group.addTask { [weak self] in
                    guard let context = await ManipulationContext.from(windowID: placement.windowID) else {
                        jlog("warn.placement", data: ["wid": placement.windowID, "reason": "no_context"])
                        return placement.windowID
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
                        return nil
                    }

                    guard let controller = self?.windowController else { return placement.windowID }
                    let success = await controller.setWindowFrame(
                        windowID: placement.windowID,
                        pid: context.pid,
                        frame: placement.bounds
                    )
                    if !success {
                        jlog("warn.placement", data: ["wid": placement.windowID, "reason": "ax_fail"])
                        return placement.windowID
                    }
                    return nil
                }
            }

            var failed = Set<UInt32>()
            for await result in group {
                if let wid = result {
                    failed.insert(wid)
                }
            }
            return failed
        }

        return failedIDs
    }

    // filterTileableFromState: get tileable windows for a space from StateManager
    private func filterTileableFromState(
        wmState: WindowManagerState,
        spaceID: String,
        exclusions: GridWindowExclusion,
        rejectedWindows: Set<UInt32> = []
    ) -> [WindowState] {
        var tileable: [WindowState] = []

        // Convert spaceID string to UInt64 for comparison with window spaces
        let spaceIDInt = UInt64(spaceID) ?? 0

        for (_, windowState) in wmState.windows {
            // Check if window is on this space
            guard windowState.spaces.contains(spaceIDInt) else { continue }

            // Skip windows rejected by the reconciler at creation
            if rejectedWindows.contains(windowState.id) { continue }

            // Check tileable
            guard isTileable(window: windowState) else { continue }

            // Check exclusions
            let appName = windowState.appName ?? ""
            if isExcluded(window: windowState, appName: appName, exclusions: exclusions) {
                continue
            }

            tileable.append(windowState)
        }

        return tileable
    }

    // findSpaceIDForDisplay: find the active space ID for a display
    private func findSpaceIDForDisplay(
        _ displayUUID: String,
        wmState: WindowManagerState
    ) -> String? {
        // Use display.currentSpaceID directly (avoids non-deterministic space iteration)
        if let display = wmState.displays.first(where: { $0.uuid == displayUUID }),
           display.currentSpaceID != 0 {
            return String(display.currentSpaceID)
        }
        // Fallback: iterate spaces
        for (spaceKey, space) in wmState.spaces {
            if space.displayUUID == displayUUID && space.isActive {
                return spaceKey
            }
        }
        return nil
    }

    // findDisplayName: look up display name
    private func findDisplayName(
        _ displayUUID: String,
        wmState: WindowManagerState
    ) -> String {
        for display in wmState.displays {
            if display.uuid == displayUUID {
                return display.name ?? ""
            }
        }
        return ""
    }
}

// MARK: - Test Helpers

extension GridApply {

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

    // _test_applyPlacements: delegates to applyPlacementsViaAX so tests
    // can verify WindowController port wiring without full layout setup.
    func _test_applyPlacements(_ placements: [GridWindowPlacement]) async -> Set<UInt32> {
        return await applyPlacementsViaAX(placements)
    }
}
