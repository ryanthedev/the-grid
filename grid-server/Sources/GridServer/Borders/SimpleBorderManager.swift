//
// SimpleBorderManager.swift
// GridServer
//
// Orchestrates per-window borders for all windows in the active cell:
// - Active window border (focused window)
// - Inactive window borders (other windows in active cell)
//

import Foundation
import CoreGraphics
import AppKit  // For NSWorkspace (focus query)

// Private AX API for getting window ID from AX element
@_silgen_name("_AXUIElementGetWindow")
private func _AXUIElementGetWindow(_ element: AXUIElement, _ windowID: UnsafeMutablePointer<UInt32>) -> AXError

/// Manages per-window borders for all windows in the active cell
///
/// **Visual behavior:**
/// - Focused window gets active border style (red by default)
/// - Other windows in active cell get inactive border style (gray by default, or hidden if disabled)
/// - Windows in inactive cells have no borders
///
/// **Thread Safety**: All methods must be called on the main queue.
// @unchecked Sendable: all mutable state is accessed on DispatchQueue.main.
// The class is not an actor but guarantees thread safety via main queue dispatch.
class SimpleBorderManager: @unchecked Sendable {
    private let connectionID: Int32

    // MARK: - State from CLI (via IPC) - Per-Display Storage

    /// Cell assignments received from CLI, keyed by display UUID
    /// displayUUID → (windowID → cellID)
    private var cellAssignmentsPerDisplay: [String: [UInt32: String]] = [:]

    /// Cell stack modes received from CLI, keyed by display UUID
    /// displayUUID → (cellID → stackMode)
    private var cellStackModesPerDisplay: [String: [String: String]] = [:]

    /// Window order per cell received from CLI, keyed by display UUID
    /// displayUUID → (cellID → [windowID])
    private var windowOrderPerDisplay: [String: [String: [UInt32]]] = [:]

    /// Display frame received from CLI, keyed by display UUID
    /// displayUUID → CGRect
    private var displayFramePerDisplay: [String: CGRect] = [:]

    /// Current display UUID for focused window (used for lookups)
    private var currentDisplayUUID: String?

    // MARK: - Focus State

    /// Currently focused window ID (gets active style)
    private var focusedWindowID: UInt32?

    /// Currently active cell ID (cell containing focused window)
    private var activeCellID: String?

    /// Whether active cell has multiple windows (tabbed mode - single border, retarget on focus change)
    private var isActiveCellTabbed: Bool = false

    /// True while nudge mode is active — active border uses nudge style instead of config style
    private var isNudgeModeActive: Bool = false

    // MARK: - Border Management (Role-Based)

    /// Reentrancy guard - prevents concurrent border operations
    private var isUpdating: Bool = false

    /// Active border (for focused window)
    private var activeBorder: BorderWindow?

    /// Inactive borders (other windows in active cell)
    /// windowID → BorderWindow
    private var inactiveBorders: [UInt32: BorderWindow] = [:]

    // MARK: - Border Pool (Memory Optimization)

    /// Pool of hidden, reusable borders to avoid SkyLight window churn.
    /// When borders are no longer needed, they're hidden and added here.
    /// When new borders are needed, we pull from this pool and retarget.
    private var freePool: [BorderWindow] = []

    /// Maximum pool size - prevents unbounded memory growth.
    /// 10 is chosen to handle typical workspace configurations (2-3 cells with 2-4 windows each)
    /// while keeping CoreAnimation backing store memory bounded (~80MB max at 8MB per border).
    private let maxPoolSize = 10

    init(connectionID: Int32) {
        self.connectionID = connectionID

        // Register for config changes to refresh border styles (no rebuild, just style update)
        BorderConfigManager.shared.onConfigChanged = { [weak self] in
            DispatchQueue.main.async {
                self?.handleConfigChangedImpl()
            }
        }
    }

    deinit {
        // Clear callback immediately (safe from any thread)
        BorderConfigManager.shared.onConfigChanged = nil

        if Thread.isMainThread {
            cleanupImpl()
        } else {
            // Capture borders before async dispatch - don't block with sync
            let active = activeBorder
            let inactive = Array(inactiveBorders.values)
            let pooled = freePool
            DispatchQueue.main.async {
                active?.destroy()
                for border in inactive {
                    border.destroy()
                }
                // Also destroy pooled borders
                for border in pooled {
                    border.destroy()
                }
            }
        }
    }

    // MARK: - IPC Handlers (receive data from CLI)

    /// Set cell assignments received from CLI for a specific display
    /// - Parameters:
    ///   - assignments: Window-to-cell mappings
    ///   - displayUUID: Target display
    ///   - focusedWindowID: Optional - if provided, updates focus atomically (prevents race conditions)
    ///   - cellStackModes: Optional - cellID → stackMode ("tabs", "vertical", "horizontal")
    ///   - windowOrder: Optional - cellID → [windowID] ordered array for focus cycling
    ///   - displayFrame: Optional - display frame for layout context
    func setCellAssignments(_ assignments: [UInt32: String], forDisplay displayUUID: String, focusedWindowID: UInt32? = nil, cellStackModes: [String: String] = [:], windowOrder: [String: [UInt32]]? = nil, displayFrame: CGRect? = nil, source: String = "unknown", liveWids: [UInt32]? = nil, completion: (() -> Void)? = nil) {
        let span = CurrentSpan.current
        DispatchQueue.main.async { [weak self, span] in
            CurrentSpan.$current.withValue(span) {
                self?.setCellAssignmentsImpl(assignments, forDisplay: displayUUID, focusedWindowID: focusedWindowID, cellStackModes: cellStackModes, windowOrder: windowOrder, displayFrame: displayFrame, source: source, liveWids: liveWids)
                completion?()
            }
        }
    }

    private func setCellAssignmentsImpl(_ assignments: [UInt32: String], forDisplay displayUUID: String, focusedWindowID newFocusedWindow: UInt32? = nil, cellStackModes: [String: String] = [:], windowOrder: [String: [UInt32]]? = nil, displayFrame: CGRect? = nil, source: String = "unknown", liveWids: [UInt32]? = nil) {
        // Reentrancy guard
        guard !isUpdating else { return }
        isUpdating = true
        defer { isUpdating = false }

        let oldAssignments = cellAssignmentsPerDisplay[displayUUID]
        cellAssignmentsPerDisplay[displayUUID] = assignments
        cellStackModesPerDisplay[displayUUID] = cellStackModes

        // Store optional window order and display frame
        if let windowOrder = windowOrder {
            windowOrderPerDisplay[displayUUID] = windowOrder
        }
        if let displayFrame = displayFrame {
            displayFramePerDisplay[displayUUID] = displayFrame
        }

        // If focusedWindowID is provided, update focus atomically (prevents race conditions)
        // This is the key fix: assignments + focus happen in single main queue dispatch
        if let newFocused = newFocusedWindow,
           let cellID = assignments[newFocused] {
            let previousCellID = activeCellID
            let previousDisplayUUID = currentDisplayUUID
            let previousFocusedWindow = focusedWindowID

            // Update state
            focusedWindowID = newFocused
            activeCellID = cellID
            currentDisplayUUID = displayUUID

            // Detect display OR cell change
            let displayChanged = displayUUID != previousDisplayUUID
            if displayChanged || cellID != previousCellID {
                rebuildBorderPool(source: displayChanged ? "atomic-displayChange" : "atomic-cellChange")
            } else if newFocused != previousFocusedWindow {
                // Same cell, different window: reassign border roles
                let stackMode = cellStackModes[cellID] ?? "tabs"
                isActiveCellTabbed = (stackMode == "tabs")
                reassignBorders(previousFocused: previousFocusedWindow)
            } else {
                // Same cell, same window: position-only refresh (windows may have moved
                // during suppressed operations like layout apply or swap).
                // Avoids the expensive release-reacquire cycle of a full rebuild.
                refreshBorderPositions()
            }
        } else if displayUUID == currentDisplayUUID {
            // No focus update requested - existing behavior for current display
            let oldCellID = activeCellID
            if let focused = focusedWindowID, let cellID = assignments[focused] {
                activeCellID = cellID
                // Use actual stackMode instead of window count
                let stackMode = cellStackModes[cellID] ?? "tabs"
                isActiveCellTabbed = (stackMode == "tabs")
            }

            let assignmentsChanged = oldAssignments != assignments
            let cellChanged = oldCellID != activeCellID

            if assignmentsChanged || cellChanged {
                rebuildBorderPool(source: "setCellAssignments")
            }
        } else if currentDisplayUUID == nil {
            // Edge case: new window appeared and focused before any assignments
            if let focused = focusedWindowID ?? queryCurrentFocusedWindow(),
               let cellID = assignments[focused] {
                focusedWindowID = focused
                activeCellID = cellID
                currentDisplayUUID = displayUUID
                rebuildBorderPool(source: "setCellAssignments-init")
            }
        }

        // Convert UInt32 keys to String for JSON serialization
        let assignmentsStr = Dictionary(uniqueKeysWithValues: assignments.map { (String($0.key), $0.value) })
        let prevStr: [String: String]? = oldAssignments.map {
            Dictionary(uniqueKeysWithValues: $0.map { (String($0.key), $0.value) })
        }

        let cells = Array(Set(assignments.values)).sorted()

        JSONLogger.shared.log("bdr.assignments", data: [
            "display": displayUUID,
            "cells": cells,
            "count": assignments.count,
            "assignments": assignmentsStr,
            "prev": prevStr as Any,
            "atomicFocus": newFocusedWindow as Any
        ])

        // Companion diagnostic: empty-assignments is a recurring pre-crash
        // pattern. Emit sibling event with source context so post-mortem can
        // tell which code path produced the empty set.
        if assignments.isEmpty {
            JSONLogger.shared.log("bdr.empty", data: [
                "prev_count": oldAssignments?.count ?? 0,
                "source": source,
                "display": displayUUID,
                "live_wids": (liveWids ?? []).sorted().map { Int($0) }
            ])
        }
    }

    // MARK: - Focus Management

    /// Update focus when a different window becomes active
    /// This is the main entry point for focus changes from CLI
    /// - Parameters:
    ///   - newFocusedWindow: The window ID that now has focus
    ///   - displayUUID: The display where the window is located (from CLI)
    func updateFocus(newFocusedWindow: UInt32, displayUUID: String) {
        let span = CurrentSpan.current
        DispatchQueue.main.async { [weak self, span] in
            CurrentSpan.$current.withValue(span) {
                self?.updateFocusImpl(newFocusedWindow: newFocusedWindow, displayUUID: displayUUID)
            }
        }
    }

    private func updateFocusImpl(newFocusedWindow: UInt32, displayUUID: String) {
        // Reentrancy guard
        guard !isUpdating else { return }
        isUpdating = true
        defer { isUpdating = false }

        // Ignore focus on our own overlay windows
        if isOurOverlayWindow(newFocusedWindow) { return }

        // Look up cell assignment on the specified display (trust CLI's displayUUID)
        guard let assignments = cellAssignmentsPerDisplay[displayUUID],
              let cellID = assignments[newFocusedWindow] else {
            // Window not assigned on this display - ignore
            return
        }

        let previousCellID = activeCellID
        let previousDisplayUUID = currentDisplayUUID
        let previousFocusedWindow = focusedWindowID

        // Update state
        focusedWindowID = newFocusedWindow
        activeCellID = cellID
        currentDisplayUUID = displayUUID

        // Detect display OR cell change - cell IDs are not globally unique
        let displayChanged = displayUUID != previousDisplayUUID

        if displayChanged || cellID != previousCellID {
            // DIFFERENT CELL OR DISPLAY: rebuild entire pool
            let source = displayChanged ? "updateFocus-displayChange" : "updateFocus-cellChange"
            rebuildBorderPool(source: source)
            Task {
                JSONLogger.shared.log("bdr.cell_change", data: [
                    "cell": cellID,
                    "wid": newFocusedWindow,
                    "displayChanged": displayChanged
                ])
            }
        } else if newFocusedWindow != previousFocusedWindow {
            // SAME CELL, DIFFERENT WINDOW: reassign roles
            reassignBorders(previousFocused: previousFocusedWindow)
            Task {
                JSONLogger.shared.log("bdr.focus_change", data: [
                    "cell": cellID,
                    "wid": newFocusedWindow
                ])
            }
        }
        // Same window refocused - no action needed
    }

    /// Handle window moved (update window border position)
    func handleWindowMoved(windowID: UInt32, newFrame: CGRect) {
        let span = CurrentSpan.current
        DispatchQueue.main.async { [weak self, span] in
            CurrentSpan.$current.withValue(span) {
                self?.handleWindowMovedImpl(windowID: windowID, newFrame: newFrame)
            }
        }
    }

    private func handleWindowMovedImpl(windowID: UInt32, newFrame: CGRect) {
        // Find which border tracks this window
        if focusedWindowID == windowID, let border = activeBorder {
            border.update(targetFrame: newFrame)
        } else if let border = inactiveBorders[windowID] {
            border.update(targetFrame: newFrame)
        }
        // else: window not in active cell, ignore
    }

    /// Handle window destroyed (remove border for destroyed window)
    func handleWindowDestroyed(windowID: UInt32) {
        let span = CurrentSpan.current
        DispatchQueue.main.async { [weak self, span] in
            CurrentSpan.$current.withValue(span) {
                self?.handleWindowDestroyedImpl(windowID: windowID)
            }
        }
    }

    private func handleWindowDestroyedImpl(windowID: UInt32) {
        // Remove from inactive pool
        if let border = inactiveBorders.removeValue(forKey: windowID) {
            border.destroy()
            Task {
                JSONLogger.shared.log("bdr.destroy", data: [
                    "wid": windowID,
                    "role": "inactive"
                ])
            }
        }

        // If it was the active border, destroy it
        // Focus will shift and trigger handleFocusChanged
        if focusedWindowID == windowID, let border = activeBorder {
            border.destroy()
            activeBorder = nil
            focusedWindowID = nil
            Task {
                JSONLogger.shared.log("bdr.destroy", data: [
                    "wid": windowID,
                    "role": "active"
                ])
            }
        }

        // Clean up from all display caches to prevent unbounded growth
        for displayUUID in cellAssignmentsPerDisplay.keys {
            cellAssignmentsPerDisplay[displayUUID]?.removeValue(forKey: windowID)
        }
    }

    /// Handle display disconnected (clean up display-specific state)
    func handleDisplayDisconnected(displayUUID: String) {
        let span = CurrentSpan.current
        DispatchQueue.main.async { [weak self, span] in
            CurrentSpan.$current.withValue(span) {
                self?.handleDisplayDisconnectedImpl(displayUUID: displayUUID)
            }
        }
    }

    private func handleDisplayDisconnectedImpl(displayUUID: String) {
        // Remove cached assignments and stack modes for this display
        cellAssignmentsPerDisplay.removeValue(forKey: displayUUID)
        cellStackModesPerDisplay.removeValue(forKey: displayUUID)
        windowOrderPerDisplay.removeValue(forKey: displayUUID)
        displayFramePerDisplay.removeValue(forKey: displayUUID)

        // If this was the active display, release borders to pool
        if currentDisplayUUID == displayUUID {
            releaseAllBordersToPool()
            currentDisplayUUID = nil
            activeCellID = nil
            // Keep focusedWindowID - focus will shift and trigger new state
        }

        Task {
            JSONLogger.shared.log("bdr.display_disconnect", data: ["uuid": displayUUID])
        }
    }

    // MARK: - Nudge Mode

    /// Switch the active border between normal config style and amber nudge style.
    /// Must be called on the main queue (dispatches internally if called off-thread).
    func setNudgeMode(active: Bool) {
        DispatchQueue.main.async { [weak self] in
            self?.setNudgeModeImpl(active: active)
        }
    }

    private func setNudgeModeImpl(active: Bool) {
        isNudgeModeActive = active

        if active {
            if let border = activeBorder, let nudgeStyle = buildNudgeStyle() {
                updateBorderStyle(border, style: nudgeStyle, isActive: true)
            }
        } else {
            // Restore normal active style now that nudge session has ended
            if let border = activeBorder {
                applyActiveStyle(to: border)
            }
        }

        jlog("bdr.nudge", data: ["active": active])
    }

    /// Build the amber nudge border style, inheriting width/radius/glow/shadow from config.
    private func buildNudgeStyle() -> BorderStyle? {
        let baseStyle = BorderConfigManager.shared.activeStyle

        return BorderStyle(
            color: CGColor(red: 1.0, green: 0.75, blue: 0.0, alpha: 1.0),
            width: baseStyle.width,
            cornerRadius: baseStyle.cornerRadius,
            opacity: baseStyle.opacity,
            styleType: baseStyle.styleType,
            glowRadius: baseStyle.glowRadius,
            glowColor: baseStyle.glowColor,
            glowOpacity: baseStyle.glowOpacity,
            glowSpread: baseStyle.glowSpread,
            shadowRadius: baseStyle.shadowRadius,
            shadowOffset: baseStyle.shadowOffset,
            shadowColor: baseStyle.shadowColor,
            shadowOpacity: baseStyle.shadowOpacity
            // stackIndicator intentionally omitted: nudge mode is free-form positioning,
            // the indicator would be visually confusing. Restored by applyActiveStyle on exit.
        )
    }

    // MARK: - Private Helpers

    /// Check if a window ID belongs to one of our overlay windows
    private func isOurOverlayWindow(_ windowID: UInt32) -> Bool {
        // Check active border
        if let active = activeBorder, active.windowID == windowID {
            return true
        }
        // Check inactive borders
        for (_, border) in inactiveBorders {
            if border.windowID == windowID {
                return true
            }
        }
        return false
    }

    // MARK: - Query Methods

    /// Query border info for a specific window
    /// Returns: (borderWindowID, targetWindowID, rgba, width, isVisible, isFocused) or nil if no border exists
    func queryBorderInfo(forWindowID windowID: UInt32) -> [String: Any]? {
        // Must be called on main queue for thread safety
        var result: [String: Any]?

        if Thread.isMainThread {
            result = queryBorderInfoImpl(forWindowID: windowID)
        } else {
            DispatchQueue.main.sync {
                result = self.queryBorderInfoImpl(forWindowID: windowID)
            }
        }

        return result
    }

    private func queryBorderInfoImpl(forWindowID windowID: UInt32) -> [String: Any]? {
        // Find border for this window (active or inactive)
        let border: BorderWindow?
        if focusedWindowID == windowID {
            border = activeBorder
        } else {
            border = inactiveBorders[windowID]
        }

        guard let border = border else {
            return nil
        }

        guard let styleInfo = border.styleInfo else {
            return [
                "borderWindowID": border.windowID,
                "targetWindowID": border.targetWindowID,
                "hasStyle": false,
                "isVisible": border.isVisible,
                "isFocused": windowID == focusedWindowID
            ]
        }

        return [
            "borderWindowID": border.windowID,
            "targetWindowID": border.targetWindowID,
            "hasStyle": true,
            "rgba": styleInfo.color,
            "width": styleInfo.width,
            "isVisible": styleInfo.isVisible,
            "isFocused": windowID == focusedWindowID
        ]
    }

    // MARK: - Cleanup

    /// Clean up all resources
    func cleanup() {
        let span = CurrentSpan.current
        DispatchQueue.main.async { [weak self, span] in
            CurrentSpan.$current.withValue(span) {
                self?.cleanupImpl()
            }
        }
    }

    private func cleanupImpl() {
        // Clear config callback to prevent retain issues
        BorderConfigManager.shared.onConfigChanged = nil

        // Destroy all active borders
        destroyAllBorders()

        // Drain the pool (destroy all pooled borders)
        drainPool()
    }

    // MARK: - Border Pool Management

    /// Destroy all borders (active and inactive)
    private func destroyAllBorders() {
        let activeCount = activeBorder != nil ? 1 : 0
        let inactiveCount = inactiveBorders.count

        Task {
            JSONLogger.shared.log("bdr.destroyAll.enter", data: [
                "activeCount": activeCount,
                "inactiveCount": inactiveCount
            ])
        }

        if let border = activeBorder {
            border.destroy()
            activeBorder = nil
        }

        for (_, border) in inactiveBorders {
            border.destroy()
        }
        inactiveBorders.removeAll()
    }

    /// Reassign borders when focus changes within the same cell (no destroy/recreate).
    /// Tabbed mode: retarget the single active border to the new window.
    /// Split mode: promote/demote active/inactive borders.
    private func reassignBorders(previousFocused: UInt32?) {
        guard let newFocused = focusedWindowID else { return }
        let config = BorderConfigManager.shared

        if isActiveCellTabbed {
            // Tabbed mode: retarget the single active border (no inactive borders exist)
            if let border = activeBorder {
                border.retarget(to: newFocused)
                // Reapply active style (updates stack indicator for new index)
                applyActiveStyle(to: border)
            } else {
                // Edge case: no active border -- acquire one
                if let border = acquireBorder(for: newFocused) {
                    activeBorder = border
                    applyActiveStyle(to: border)
                }
            }
            // No inactive borders to manage in tabbed mode
        } else {
            // Split mode: demote previous active, promote new active
            if let prevWindow = previousFocused, let border = activeBorder {
                updateBorderStyle(border, style: config.inactiveStyle)
                inactiveBorders[prevWindow] = border
                activeBorder = nil
            }

            if let border = inactiveBorders.removeValue(forKey: newFocused) {
                // Border exists in inactive pool -- promote it
                activeBorder = border
                applyActiveStyle(to: border)
            } else {
                // Edge case: window appeared without a border
                if let border = acquireBorder(for: newFocused) {
                    activeBorder = border
                    applyActiveStyle(to: border)
                    Task {
                        JSONLogger.shared.log("warn.bdr.missing", data: ["wid": newFocused])
                    }
                }
            }
        }
    }

    /// Rebuild borders for the active cell (called on cell change or layout apply).
    /// Mode-aware: tabbed cells get exactly 1 border (for focused window),
    /// split cells get 1 border per visible window.
    private func rebuildBorderPool(source: String = "unknown") {
        // Release existing borders to pool (hide, don't destroy)
        releaseAllBordersToPool()

        // Get windows in active cell
        guard let cellID = activeCellID,
              let displayUUID = currentDisplayUUID,
              let assignments = cellAssignmentsPerDisplay[displayUUID] else {
            return
        }

        let windowsInCell = assignments.filter { $0.value == cellID }.map { $0.key }
        let config = BorderConfigManager.shared

        // Determine stack mode for cell
        let stackModes = cellStackModesPerDisplay[displayUUID] ?? [:]
        let stackMode = stackModes[cellID] ?? "tabs"
        isActiveCellTabbed = (stackMode == "tabs")

        if isActiveCellTabbed {
            // Tabbed mode: only the focused window gets a border
            let targetWindow: UInt32?
            if let focused = focusedWindowID, windowsInCell.contains(focused) {
                targetWindow = focused
            } else if let firstWindow = windowsInCell.first {
                // No focused window known yet -- use first window in cell
                targetWindow = firstWindow
            } else {
                targetWindow = nil
            }

            if let targetWindow, let border = acquireBorder(for: targetWindow) {
                activeBorder = border
                applyActiveStyle(to: border)
            }
            // No inactive borders in tabbed mode
        } else {
            // Split mode (vertical or horizontal): all windows visible, each gets a border
            for windowID in windowsInCell {
                guard let border = acquireBorder(for: windowID) else { continue }

                if windowID == focusedWindowID {
                    activeBorder = border
                    applyActiveStyle(to: border)
                } else {
                    inactiveBorders[windowID] = border
                    updateBorderStyle(border, style: config.inactiveStyle, isActive: false)
                }
            }
        }

        Task {
            JSONLogger.shared.log("bdr.rebuild", data: [
                "source": source,
                "cell": cellID,
                "count": isActiveCellTabbed ? (activeBorder != nil ? 1 : 0) : windowsInCell.count,
                "focused": focusedWindowID ?? 0,
                "tabbed": isActiveCellTabbed,
                "poolSize": freePool.count
            ])
        }
    }

    /// Update positions of all active borders without release/reacquire cycle.
    /// Called when the same cell and same focused window are re-sent (e.g., after
    /// layout apply or window swap repositions windows within the same cell).
    private func refreshBorderPositions() {
        var refreshCount = 0

        // Refresh active border position
        if let border = activeBorder {
            var frame = CGRect.zero
            if SLSGetWindowBounds(connectionID, border.targetWindowID, &frame) == .success {
                border.update(targetFrame: frame)
                refreshCount += 1
            }
        }

        // Refresh inactive border positions
        for (_, border) in inactiveBorders {
            var frame = CGRect.zero
            if SLSGetWindowBounds(connectionID, border.targetWindowID, &frame) == .success {
                border.update(targetFrame: frame)
                refreshCount += 1
            }
        }

        Task {
            JSONLogger.shared.log("bdr.refresh", data: [
                "cell": activeCellID ?? "nil",
                "count": refreshCount
            ])
        }
    }

    /// Create a border for a window
    private func createBorder(for windowID: UInt32) -> BorderWindow? {
        let border = BorderWindow(connectionID: connectionID, targetWindowID: windowID)
        guard border.create() else {
            Task {
                JSONLogger.shared.log("err.bdr.create", data: ["wid": windowID])
            }
            return nil
        }

        // Get initial position
        var frame = CGRect.zero
        guard SLSGetWindowBounds(connectionID, windowID, &frame) == .success else {
            border.destroy()
            Task {
                JSONLogger.shared.log("err.bdr.bounds", data: ["wid": windowID])
            }
            return nil
        }

        border.update(targetFrame: frame)
        return border
    }

    /// Acquire a border from the pool, or create a new one if pool is empty.
    /// This is the primary way to get a border - avoids SkyLight window churn.
    private func acquireBorder(for windowID: UInt32) -> BorderWindow? {
        // Thread safety: all pool operations must run on main queue
        dispatchPrecondition(condition: .onQueue(.main))

        // Try to reuse a pooled border first
        if let pooledBorder = freePool.popLast() {
            // Retarget the pooled border to the new window
            pooledBorder.retarget(to: windowID)

            // Get current frame for the new target
            var frame = CGRect.zero
            guard SLSGetWindowBounds(connectionID, windowID, &frame) == .success else {
                // Can't get bounds - destroy border to avoid corrupted state
                pooledBorder.destroy()
                Task {
                    JSONLogger.shared.log("err.bdr.acquire_bounds", data: ["wid": windowID])
                }
                return nil
            }

            pooledBorder.update(targetFrame: frame)
            return pooledBorder
        }

        // Pool empty - create a new border
        return createBorder(for: windowID)
    }

    /// Release a border back to the pool instead of destroying it.
    /// If the pool is full, the border is destroyed.
    private func releaseBorder(_ border: BorderWindow) {
        // Thread safety: all pool operations must run on main queue
        dispatchPrecondition(condition: .onQueue(.main))

        // Hide the border immediately
        border.hide(reason: "pool_release")

        // If pool is full, destroy the oldest border to make room
        if freePool.count >= maxPoolSize {
            let oldest = freePool.removeFirst()
            oldest.destroy()
            Task {
                JSONLogger.shared.log("bdr.pool.evict", data: [
                    "wid": oldest.windowID,
                    "poolSize": freePool.count
                ])
            }
        }

        // Add to pool
        freePool.append(border)
    }

    /// Release all active borders to the pool (used when switching cells)
    private func releaseAllBordersToPool() {
        let activeCount = activeBorder != nil ? 1 : 0
        let inactiveCount = inactiveBorders.count

        // Release active border
        if let border = activeBorder {
            releaseBorder(border)
            activeBorder = nil
        }

        // Release inactive borders
        for (_, border) in inactiveBorders {
            releaseBorder(border)
        }
        inactiveBorders.removeAll()

        Task {
            JSONLogger.shared.log("bdr.pool.releaseAll", data: [
                "activeCount": activeCount,
                "inactiveCount": inactiveCount,
                "poolSize": freePool.count
            ])
        }
    }

    /// Drain the pool - destroy all pooled borders (used on shutdown)
    private func drainPool() {
        let count = freePool.count
        for border in freePool {
            border.destroy()
        }
        freePool.removeAll()

        Task {
            JSONLogger.shared.log("bdr.pool.drain", data: ["count": count])
        }
    }

    /// Debug: Cycle active border through colors to verify style updates work
    func debugBorders() {
        DispatchQueue.main.async { [weak self] in
            self?.debugBordersImpl()
        }
    }

    private func debugBordersImpl() {
        guard let border = activeBorder else {
            JSONLogger.shared.log("dbg.borders", msg: "no active border")
            return
        }

        let colors: [(CGFloat, CGFloat, CGFloat, String)] = [
            (1.0, 0.0, 0.0, "red"),
            (0.0, 1.0, 0.0, "green"),
            (0.0, 0.0, 1.0, "blue"),
            (1.0, 1.0, 0.0, "yellow"),
            (1.0, 0.0, 1.0, "magenta"),
        ]

        for (i, (r, g, b, name)) in colors.enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(i) * 0.5) { [weak border] in
                guard let border = border else { return }
                let color = CGColor(red: r, green: g, blue: b, alpha: 1.0)
                let style = BorderStyle(
                    color: color,
                    width: 5.0,
                    cornerRadius: 12.0,
                    opacity: 1.0,
                    styleType: .round,
                    glowRadius: nil, glowColor: nil, glowOpacity: nil, glowSpread: nil,
                    shadowRadius: nil, shadowOffset: nil, shadowColor: nil, shadowOpacity: nil
                )
                border.updateStyle(style: style, styleType: "debug-\(name)")
            }
        }

        // Restore original style after cycling
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
            self?.handleConfigChangedImpl()
        }
    }

    /// Handle config change - update styles only (no rebuild)
    private func handleConfigChangedImpl() {
        guard !isUpdating else { return }
        isUpdating = true
        defer { isUpdating = false }

        let config = BorderConfigManager.shared

        // Update active border — skip when nudge mode is active because nudge
        // owns the active border color for the session duration
        if !isNudgeModeActive {
            if let border = activeBorder {
                applyActiveStyle(to: border)
            }
        }

        // Inactive border styles always update (nudge mode does not affect them)
        for (_, border) in inactiveBorders {
            updateBorderStyle(border, style: config.inactiveStyle, isActive: false)
        }

        Task {
            JSONLogger.shared.log("bdr.config_change", data: [:])
        }
    }

    /// Update a border's style
    private func updateBorderStyle(_ border: BorderWindow, style: BorderStyle?, isActive: Bool = false) {
        if let style = style {
            // Get current frame from target window
            var frame = CGRect.zero
            if SLSGetWindowBounds(connectionID, border.targetWindowID, &frame) == .success {
                border.update(targetFrame: frame, style: style)
            }
            border.updateStyle(style: style, styleType: isActive ? "active" : "inactive")
        } else {
            border.updateStyle(style: nil, styleType: "hidden")
        }
    }

    /// Compute stack indicator for active border
    /// Always returns indicator (for position), even for single window
    private func computeStackIndicator() -> StackIndicator? {
        guard let cellID = activeCellID,
              let displayUUID = currentDisplayUUID,
              let assignments = cellAssignmentsPerDisplay[displayUUID],
              let focused = focusedWindowID else {
            return nil
        }

        // Use CLI-provided window order if available, otherwise fallback to sorted IDs
        let windowsInCell: [UInt32]
        if let providedOrder = windowOrderPerDisplay[displayUUID]?[cellID] {
            windowsInCell = providedOrder
        } else {
            windowsInCell = assignments.filter { $0.value == cellID }.map { $0.key }.sorted()
        }
        let currentIndex = windowsInCell.firstIndex(of: focused) ?? 0

        // Determine which edge faces screen center
        let position = computeInwardEdge(for: focused)

        return StackIndicator(
            totalCount: windowsInCell.count,
            currentIndex: currentIndex,
            position: position,
            lineLength: 12,
            lineWidth: 3,
            spacing: 6
        )
    }

    /// Compute which edge of the window faces toward screen center
    private func computeInwardEdge(for windowID: UInt32) -> StackIndicatorPosition {
        // Get window frame
        var windowFrame = CGRect.zero
        guard SLSGetWindowBounds(connectionID, windowID, &windowFrame) == .success else {
            return .leftCenter  // fallback
        }

        // Get display bounds for the current display (multi-monitor aware)
        guard let uuid = currentDisplayUUID,
              let displayFrame = displayFramePerDisplay[uuid] else {
            // No display frame available - CLI must send displayFrame
            jlog("err.stack.noDisplayFrame", data: [
                "currentDisplayUUID": currentDisplayUUID as Any,
                "displayFramePerDisplayKeys": Array(displayFramePerDisplay.keys),
                "windowID": windowID
            ])
            return .leftCenter
        }

        // Window center relative to display origin (handles multi-monitor offsets)
        let relativeWindowX = windowFrame.midX - displayFrame.origin.x
        let relativeWindowY = windowFrame.midY - displayFrame.origin.y

        // Display center relative to its own origin
        let displayCenterX = displayFrame.width / 2
        let displayCenterY = displayFrame.height / 2

        // Calculate offset from display center (signed)
        let offsetX = relativeWindowX - displayCenterX  // positive = right of center
        let offsetY = relativeWindowY - displayCenterY  // positive = below center (Quartz coords)

        // Pick the axis with the larger offset - that's the more "outward" direction
        // The inward edge is opposite to the outward direction
        if abs(offsetX) >= abs(offsetY) {
            // X axis dominates: left/right edge
            return offsetX > 0 ? .leftCenter : .rightCenter
        } else {
            // Y axis dominates: top/bottom edge
            return offsetY > 0 ? .topCenter : .bottomCenter
        }
    }

    /// Apply active style with stack indicator attached.
    /// When nudge mode is active, applies nudge style instead of config style and returns early
    /// (no stack indicator during free-form positioning).
    private func applyActiveStyle(to border: BorderWindow) {
        // Nudge mode owns the active border color for the session duration
        if isNudgeModeActive {
            if let nudgeStyle = buildNudgeStyle() {
                updateBorderStyle(border, style: nudgeStyle, isActive: true)
            }
            return
        }

        let config = BorderConfigManager.shared
        var style = config.activeStyle

        if config.stackIndicatorEnabled {
            if var indicator = computeStackIndicator() {
                let configPosition = config.stackIndicatorPosition

                if configPosition != "auto" {
                    let overridePosition: StackIndicatorPosition
                    switch configPosition.lowercased() {
                    case "left":
                        overridePosition = .leftCenter
                    case "right":
                        overridePosition = .rightCenter
                    case "top":
                        overridePosition = .topCenter
                    case "bottom":
                        overridePosition = .bottomCenter
                    default:
                        overridePosition = indicator.position
                    }
                    indicator.position = overridePosition
                }

                indicator.lineLength = config.stackIndicatorLineLength
                indicator.lineWidth = config.stackIndicatorLineWidth
                indicator.spacing = config.stackIndicatorSpacing

                style.stackIndicator = indicator
            }
        }

        updateBorderStyle(border, style: style, isActive: true)
    }

    // MARK: - Focus Query

    /// Query the currently focused window from the OS using AX APIs.
    /// Used during startup when no focus events have been received yet.
    /// - Returns: The window ID of the currently focused window, or nil if unavailable
    private func queryCurrentFocusedWindow() -> UInt32? {
        guard let frontApp = NSWorkspace.shared.frontmostApplication else {
            return nil
        }

        let pid = frontApp.processIdentifier
        let appElement = AXUIElementCreateApplication(pid)

        var focusedWindowRef: AnyObject?
        let result = AXUIElementCopyAttributeValue(
            appElement,
            kAXFocusedWindowAttribute as CFString,
            &focusedWindowRef
        )

        guard result == .success, let ref = focusedWindowRef else {
            return nil
        }

        // Verify this is actually an AXUIElement by comparing CFTypeIDs
        guard CFGetTypeID(ref as CFTypeRef) == AXUIElementGetTypeID() else {
            JSONLogger.shared.log("err.ax.cast", data: ["pid": pid])
            return nil
        }
        let axElement = ref as! AXUIElement

        var windowID: UInt32 = 0
        let axResult = _AXUIElementGetWindow(axElement, &windowID)

        guard axResult == .success, windowID != 0 else {
            return nil
        }

        return windowID
    }
}

// MARK: - BorderRendering Conformance

// Async protocol wrappers that bridge DispatchQueue.main.async into
// structured concurrency. Each method dispatches to the existing
// synchronous implementation on main and resumes the continuation
// when the work completes.
extension SimpleBorderManager: BorderRendering {

    func setCellAssignments(
        _ assignments: [UInt32: String],
        forDisplay displayUUID: String,
        focusedWindowID: UInt32?,
        cellStackModes: [String: String],
        windowOrder: [String: [UInt32]]?,
        displayFrame: CGRect?,
        source: String,
        liveWids: [UInt32]?
    ) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            self.setCellAssignments(
                assignments,
                forDisplay: displayUUID,
                focusedWindowID: focusedWindowID,
                cellStackModes: cellStackModes,
                windowOrder: windowOrder,
                displayFrame: displayFrame,
                source: source,
                liveWids: liveWids,
                completion: { continuation.resume() }
            )
        }
    }

    func updateFocus(newFocusedWindow: UInt32, displayUUID: String) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let span = CurrentSpan.current
            DispatchQueue.main.async { [weak self, span] in
                CurrentSpan.$current.withValue(span) {
                    self?.updateFocusImpl(newFocusedWindow: newFocusedWindow, displayUUID: displayUUID)
                    continuation.resume()
                }
            }
        }
    }

    func handleWindowDestroyed(windowID: UInt32) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let span = CurrentSpan.current
            DispatchQueue.main.async { [weak self, span] in
                CurrentSpan.$current.withValue(span) {
                    self?.handleWindowDestroyedImpl(windowID: windowID)
                    continuation.resume()
                }
            }
        }
    }

    func handleWindowMoved(windowID: UInt32, newFrame: CGRect) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let span = CurrentSpan.current
            DispatchQueue.main.async { [weak self, span] in
                CurrentSpan.$current.withValue(span) {
                    self?.handleWindowMovedImpl(windowID: windowID, newFrame: newFrame)
                    continuation.resume()
                }
            }
        }
    }

    func handleDisplayDisconnected(displayUUID: String) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let span = CurrentSpan.current
            DispatchQueue.main.async { [weak self, span] in
                CurrentSpan.$current.withValue(span) {
                    self?.handleDisplayDisconnectedImpl(displayUUID: displayUUID)
                    continuation.resume()
                }
            }
        }
    }
}
