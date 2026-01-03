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
class SimpleBorderManager {
    private let connectionID: Int32

    // MARK: - State from CLI (via IPC) - Per-Display Storage

    /// Cell assignments received from CLI, keyed by display UUID
    /// displayUUID → (windowID → cellID)
    private var cellAssignmentsPerDisplay: [String: [UInt32: String]] = [:]

    /// Current display UUID for focused window (used for lookups)
    private var currentDisplayUUID: String?

    // MARK: - Focus State

    /// Currently focused window ID (gets active style)
    private var focusedWindowID: UInt32?

    /// Currently active cell ID (cell containing focused window)
    private var activeCellID: String?

    /// Whether active cell has multiple windows (tabbed mode - single border, retarget on focus change)
    private var isActiveCellTabbed: Bool = false

    // MARK: - Border Management (Role-Based)

    /// Reentrancy guard - prevents concurrent border operations
    private var isUpdating: Bool = false

    /// Active border (for focused window)
    private var activeBorder: BorderWindow?

    /// Inactive borders (other windows in active cell)
    /// windowID → BorderWindow
    private var inactiveBorders: [UInt32: BorderWindow] = [:]

    /// Free pool of reusable border windows (avoids expensive SLSNewWindow calls)
    private var freePool: [BorderWindow] = []

    /// Cap for lazy cleanup. 10 is sufficient because:
    /// - Typical cell has 1-4 windows
    /// - Users rarely have more than 10 windows visible across all cells
    /// - Each BorderWindow is ~1KB (overlay window handle + style state)
    private let maxFreePoolSize = 10

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
                for border in pooled {
                    border.destroy()
                }
            }
        }
    }

    // MARK: - IPC Handlers (receive data from CLI)

    /// Set cell assignments received from CLI for a specific display
    func setCellAssignments(_ assignments: [UInt32: String], forDisplay displayUUID: String) {
        let span = CurrentSpan.current
        DispatchQueue.main.async { [weak self, span] in
            CurrentSpan.$current.withValue(span) {
                self?.setCellAssignmentsImpl(assignments, forDisplay: displayUUID)
            }
        }
    }

    private func setCellAssignmentsImpl(_ assignments: [UInt32: String], forDisplay displayUUID: String) {
        // Reentrancy guard
        guard !isUpdating else { return }
        isUpdating = true
        defer { isUpdating = false }

        let oldAssignments = cellAssignmentsPerDisplay[displayUUID]
        cellAssignmentsPerDisplay[displayUUID] = assignments

        // If this affects the current display, rebuild pool
        if displayUUID == currentDisplayUUID {
            // Re-derive active cell from focused window
            let oldCellID = activeCellID
            if let focused = focusedWindowID, let cellID = assignments[focused] {
                activeCellID = cellID
                // Update tabbed flag based on new assignments
                let windowsInCell = assignments.filter { $0.value == cellID }.map { $0.key }
                isActiveCellTabbed = windowsInCell.count > 1
            }

            // Only rebuild if assignments actually changed
            let assignmentsChanged = oldAssignments != assignments
            let cellChanged = oldCellID != activeCellID

            if assignmentsChanged || cellChanged {
                rebuildBorderPool(source: "setCellAssignments")
            }
        } else if currentDisplayUUID == nil {
            // Edge case: new window appeared and focused before any assignments
            // Now assignments arrived - check if focused window is now assigned
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

        // Collect unique cells for context
        let cells = Array(Set(assignments.values)).sorted()

        JSONLogger.shared.log("bdr.assignments", data: [
            "display": displayUUID,
            "cells": cells,
            "count": assignments.count,
            "assignments": assignmentsStr,
            "prev": prevStr as Any
        ])
    }

    /// Find which display has an assignment for a window
    private func findAssignment(for windowID: UInt32) -> (displayUUID: String?, cellID: String?) {
        for (displayUUID, assignments) in cellAssignmentsPerDisplay {
            if let cellID = assignments[windowID] {
                return (displayUUID, cellID)
            }
        }
        return (nil, nil)
    }

    // MARK: - Focus Management

    /// Update focus when a different window becomes active
    /// This is the main entry point for focus changes from BorderEvents
    func updateFocus(newFocusedWindow: UInt32) {
        let span = CurrentSpan.current
        DispatchQueue.main.async { [weak self, span] in
            CurrentSpan.$current.withValue(span) {
                self?.updateFocusImpl(newFocusedWindow: newFocusedWindow)
            }
        }
    }

    private func updateFocusImpl(newFocusedWindow: UInt32) {
        // Reentrancy guard
        guard !isUpdating else { return }
        isUpdating = true
        defer { isUpdating = false }

        // Ignore focus on our own overlay windows
        if isOurOverlayWindow(newFocusedWindow) { return }

        // Find assignment for the new focused window
        let (newDisplayUUID, newCellID) = findAssignment(for: newFocusedWindow)

        guard let cellID = newCellID, let displayUUID = newDisplayUUID else {
            // Window not assigned to any cell - IGNORE this focus event
            // Don't destroy borders just because an untracked window got focus
            // (e.g., transient focus during app switch, or window from another space)
            return
        }

        let previousCellID = activeCellID
        let previousFocusedWindow = focusedWindowID

        // Update state
        focusedWindowID = newFocusedWindow
        activeCellID = cellID
        currentDisplayUUID = displayUUID

        if cellID != previousCellID {
            // DIFFERENT CELL: rebuild entire pool
            rebuildBorderPool(source: "updateFocus-cellChange")
            JSONLogger.shared.log("bdr.cell_change", data: [
                "cell": cellID,
                "wid": newFocusedWindow
            ])
        } else if newFocusedWindow != previousFocusedWindow {
            // SAME CELL, DIFFERENT WINDOW: reassign roles
            reassignBorders(previousFocused: previousFocusedWindow)
            JSONLogger.shared.log("bdr.focus_change", data: [
                "cell": cellID,
                "wid": newFocusedWindow
            ])
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
        // Remove from inactive pool - release to free pool for reuse
        if let border = inactiveBorders.removeValue(forKey: windowID) {
            releaseBorder(border)
            JSONLogger.shared.log("bdr.release", data: [
                "wid": windowID,
                "role": "inactive",
                "reason": "window_destroyed"
            ])
        }

        // If it was the active border, release it to pool
        // Focus will shift and trigger handleFocusChanged
        if focusedWindowID == windowID, let border = activeBorder {
            releaseBorder(border)
            activeBorder = nil
            focusedWindowID = nil
            JSONLogger.shared.log("bdr.release", data: [
                "wid": windowID,
                "role": "active",
                "reason": "window_destroyed"
            ])
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
        // Remove cached assignments for this display
        cellAssignmentsPerDisplay.removeValue(forKey: displayUUID)

        // If this was the active display, clear state and borders
        if currentDisplayUUID == displayUUID {
            destroyAllBorders()
            currentDisplayUUID = nil
            activeCellID = nil
            // Keep focusedWindowID - focus will shift and trigger new state
        }

        JSONLogger.shared.log("bdr.display_disconnect", data: ["uuid": displayUUID])
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

        // Destroy all borders
        destroyAllBorders()
    }

    // MARK: - Border Pool Management

    /// Destroy all borders (active and inactive)
    private func destroyAllBorders() {
        if let border = activeBorder {
            border.destroy()
            activeBorder = nil
        }

        for (_, border) in inactiveBorders {
            border.destroy()
        }
        inactiveBorders.removeAll()

        // Destroy free pool
        for border in freePool {
            border.destroy()
        }
        freePool.removeAll()
    }

    /// Reassign borders when focus changes within the same cell (no destroy/recreate)
    private func reassignBorders(previousFocused: UInt32?) {
        guard let newFocused = focusedWindowID else { return }
        let config = BorderConfigManager.shared

        // For tabbed cells: retarget the existing active border (no demote/promote)
        if isActiveCellTabbed {
            if let border = activeBorder {
                if border.retarget(to: newFocused) {
                    JSONLogger.shared.log("bdr.retarget_focus", data: [
                        "prev": previousFocused ?? 0,
                        "new": newFocused
                    ])
                    return
                }
                // Retarget failed - border is invalid, destroy and fall through to create new
                border.destroy()
                activeBorder = nil
            }

            // No active border or retarget failed - create new one
            guard let cellID = activeCellID,
                  let displayUUID = currentDisplayUUID,
                  let assignments = cellAssignmentsPerDisplay[displayUUID],
                  assignments[newFocused] == cellID else {
                JSONLogger.shared.log("err.bdr.invalid_tabbed", data: ["wid": newFocused])
                return
            }
            if let (border, _) = acquireBorder(for: newFocused) {
                updateBorderStyle(border, style: config.activeStyle, isActive: true)
                activeBorder = border
                JSONLogger.shared.log("bdr.create_tabbed", data: ["wid": newFocused])
            }
            return
        }

        // For non-tabbed cells: demote/promote as before
        // Step 1: Demote previous active border to inactive
        if let prevWindow = previousFocused, let border = activeBorder {
            updateBorderStyle(border, style: config.inactiveStyle)
            inactiveBorders[prevWindow] = border
            activeBorder = nil
            JSONLogger.shared.log("bdr.demote", data: ["wid": prevWindow])
        }

        // Step 2: Promote border for newly focused window
        if let border = inactiveBorders.removeValue(forKey: newFocused) {
            // Border exists in inactive pool - promote it
            updateBorderStyle(border, style: config.activeStyle, isActive: true)
            activeBorder = border
            JSONLogger.shared.log("bdr.promote", data: ["wid": newFocused])
        } else {
            // No border for this window (edge case: window appeared and auto-focused
            // before CLI sent assignments, then assignments arrived)
            if let (border, _) = acquireBorder(for: newFocused) {
                updateBorderStyle(border, style: config.activeStyle, isActive: true)
                activeBorder = border
                JSONLogger.shared.log("warn.bdr.missing", data: ["wid": newFocused])
            }
        }

        validatePoolInvariants()
    }

    /// Rebuild the entire border pool (called on cell change or layout apply)
    private func rebuildBorderPool(source: String = "unknown") {
        // Release existing borders TO POOL (not destroy)
        if let border = activeBorder {
            releaseBorder(border)
            activeBorder = nil
        }
        for (_, border) in inactiveBorders {
            releaseBorder(border)
        }
        inactiveBorders.removeAll()

        // Get windows in active cell
        guard let cellID = activeCellID,
              let displayUUID = currentDisplayUUID,
              let assignments = cellAssignmentsPerDisplay[displayUUID] else {
            return
        }

        let windowsInCell = assignments.filter { $0.value == cellID }.map { $0.key }
        let config = BorderConfigManager.shared

        // Track if cell is tabbed (multiple windows stacked)
        isActiveCellTabbed = windowsInCell.count > 1

        var acquiredFromPool = 0
        var newlyCreated = 0

        // Acquire borders for windows in cell (from pool first)
        // For tabbed cells: only acquire border for focused window (retarget on focus change)
        // For non-tabbed cells: acquire borders for all windows (active + inactive)
        for windowID in windowsInCell {
            let isFocused = (windowID == focusedWindowID)

            // Skip inactive borders for tabbed cells
            if isActiveCellTabbed && !isFocused {
                continue
            }

            guard let (border, fromPool) = acquireBorder(for: windowID) else { continue }

            if fromPool {
                acquiredFromPool += 1
            } else {
                newlyCreated += 1
            }

            let style = isFocused ? config.activeStyle : config.inactiveStyle
            updateBorderStyle(border, style: style, isActive: isFocused)

            if isFocused {
                activeBorder = border
            } else {
                inactiveBorders[windowID] = border
            }
        }

        JSONLogger.shared.log("bdr.rebuild", data: [
            "source": source,
            "cell": cellID,
            "count": windowsInCell.count,
            "fromPool": acquiredFromPool,
            "created": newlyCreated,
            "poolSize": freePool.count
        ])

        validatePoolInvariants()
    }

    /// Acquire a border for a window (from pool or create new)
    /// Returns a tuple: (border, fromPool) for metrics tracking
    private func acquireBorder(for windowID: UInt32) -> (border: BorderWindow, fromPool: Bool)? {
        // 1. Try to get from free pool (avoids SLSNewWindow)
        if let border = freePool.popLast() {
            guard border.retarget(to: windowID) else {
                // Retarget failed - border is now invalid, destroy and retry
                // Note: retarget() failure leaves border in undefined state
                border.destroy()
                // Recursion bounded by maxFreePoolSize (max 10 calls)
                return acquireBorder(for: windowID)
            }
            return (border, fromPool: true)
        }

        // 2. Pool empty - create new (expensive)
        guard let border = createBorder(for: windowID) else {
            return nil
        }
        return (border, fromPool: false)
    }

    /// Release a border to the free pool (or destroy if pool is full)
    private func releaseBorder(_ border: BorderWindow) {
        border.hide(reason: "released_to_pool")

        // Add to pool if under cap
        if freePool.count < maxFreePoolSize {
            freePool.append(border)
        } else {
            // Pool full - destroy excess
            border.destroy()
        }
    }

    /// Debug assertion to catch pool invariant violations
    private func validatePoolInvariants() {
        #if DEBUG
        let activeSet = activeBorder.map { [$0] } ?? []
        let inactiveSet = Array(inactiveBorders.values)
        let all = activeSet + inactiveSet + freePool
        assert(Set(all.map { ObjectIdentifier($0) }).count == all.count,
               "Border appears in multiple collections")
        #endif
    }

    /// Create a border for a window
    private func createBorder(for windowID: UInt32) -> BorderWindow? {
        let border = BorderWindow(connectionID: connectionID, targetWindowID: windowID)
        guard border.create() else {
            JSONLogger.shared.log("err.bdr.create", data: ["wid": windowID])
            return nil
        }

        // Get initial position
        var frame = CGRect.zero
        guard SLSGetWindowBounds(connectionID, windowID, &frame) == .success else {
            border.destroy()
            JSONLogger.shared.log("err.bdr.bounds", data: ["wid": windowID])
            return nil
        }

        border.update(targetFrame: frame)
        return border
    }

    /// Handle config change - update styles only (no rebuild)
    private func handleConfigChangedImpl() {
        guard !isUpdating else { return }
        isUpdating = true
        defer { isUpdating = false }

        let config = BorderConfigManager.shared

        // Update active border style
        if let border = activeBorder {
            updateBorderStyle(border, style: config.activeStyle, isActive: true)
        }

        // Update inactive border styles
        for (_, border) in inactiveBorders {
            updateBorderStyle(border, style: config.inactiveStyle, isActive: false)
        }

        JSONLogger.shared.log("bdr.config_change", data: [:])
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
