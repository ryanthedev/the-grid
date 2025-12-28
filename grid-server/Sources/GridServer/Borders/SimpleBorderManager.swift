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

    /// Cell bounds received from CLI, keyed by display UUID
    /// displayUUID → (cellID → CGRect)
    private var cellBoundsPerDisplay: [String: [String: CGRect]] = [:]

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
            DispatchQueue.main.async {
                active?.destroy()
                for border in inactive {
                    border.destroy()
                }
            }
        }
    }

    // MARK: - IPC Handlers (receive data from CLI)

    /// Set cell bounds received from CLI for a specific display
    func setCellBounds(_ bounds: [String: CGRect], forDisplay displayUUID: String) {
        let span = CurrentSpan.current
        DispatchQueue.main.async { [weak self, span] in
            CurrentSpan.$current.withValue(span) {
                self?.setCellBoundsImpl(bounds, forDisplay: displayUUID)
            }
        }
    }

    private func setCellBoundsImpl(_ bounds: [String: CGRect], forDisplay displayUUID: String) {
        cellBoundsPerDisplay[displayUUID] = bounds

        // Bounds updated, but we don't use them for positioning yet
        // (borders are sized from window frames, not cell bounds)
    }

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

        Task {
            JSONLogger.shared.log("bdr.assignments", data: [
                "display": displayUUID,
                "count": assignments.count
            ])
        }
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
            Task {
                JSONLogger.shared.log("bdr.cell_change", data: [
                    "cell": cellID,
                    "wid": newFocusedWindow
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
        // Remove cached assignments for this display
        cellAssignmentsPerDisplay.removeValue(forKey: displayUUID)
        cellBoundsPerDisplay.removeValue(forKey: displayUUID)

        // If this was the active display, clear state and borders
        if currentDisplayUUID == displayUUID {
            destroyAllBorders()
            currentDisplayUUID = nil
            activeCellID = nil
            // Keep focusedWindowID - focus will shift and trigger new state
        }

        Task {
            JSONLogger.shared.log("bdr.display_disconnect", data: ["uuid": displayUUID])
        }
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
    }

    /// Reassign borders when focus changes within the same cell (no destroy/recreate)
    private func reassignBorders(previousFocused: UInt32?) {
        guard let newFocused = focusedWindowID else { return }
        let config = BorderConfigManager.shared

        // For tabbed cells: retarget the existing active border (no demote/promote)
        if isActiveCellTabbed {
            if let border = activeBorder {
                border.retarget(to: newFocused)
                Task {
                    JSONLogger.shared.log("bdr.retarget_focus", data: [
                        "prev": previousFocused ?? 0,
                        "new": newFocused
                    ])
                }
            } else {
                // Edge case: no active border exists, create one
                // First verify window is still in active cell
                guard let cellID = activeCellID,
                      let displayUUID = currentDisplayUUID,
                      let assignments = cellAssignmentsPerDisplay[displayUUID],
                      assignments[newFocused] == cellID else {
                    Task {
                        JSONLogger.shared.log("err.bdr.invalid_tabbed", data: ["wid": newFocused])
                    }
                    return
                }
                if let border = createBorder(for: newFocused) {
                    updateBorderStyle(border, style: config.activeStyle, isActive: true)
                    activeBorder = border
                    Task {
                        JSONLogger.shared.log("warn.bdr.missing_tabbed", data: ["wid": newFocused])
                    }
                }
            }
            return
        }

        // For non-tabbed cells: demote/promote as before
        // Step 1: Demote previous active border to inactive
        if let prevWindow = previousFocused, let border = activeBorder {
            updateBorderStyle(border, style: config.inactiveStyle)
            inactiveBorders[prevWindow] = border
            activeBorder = nil
            Task {
                JSONLogger.shared.log("bdr.demote", data: ["wid": prevWindow])
            }
        }

        // Step 2: Promote border for newly focused window
        if let border = inactiveBorders.removeValue(forKey: newFocused) {
            // Border exists in inactive pool - promote it
            updateBorderStyle(border, style: config.activeStyle, isActive: true)
            activeBorder = border
            Task {
                JSONLogger.shared.log("bdr.promote", data: ["wid": newFocused])
            }
        } else {
            // No border for this window (edge case: window appeared and auto-focused
            // before CLI sent assignments, then assignments arrived)
            if let border = createBorder(for: newFocused) {
                updateBorderStyle(border, style: config.activeStyle, isActive: true)
                activeBorder = border
                Task {
                    JSONLogger.shared.log("warn.bdr.missing", data: ["wid": newFocused])
                }
            }
        }
    }

    /// Rebuild the entire border pool (called on cell change or layout apply)
    private func rebuildBorderPool(source: String = "unknown") {
        // Destroy all existing borders
        destroyAllBorders()

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

        // Create borders for windows in cell
        // For tabbed cells: only create border for focused window (retarget on focus change)
        // For non-tabbed cells: create borders for all windows (active + inactive)
        for windowID in windowsInCell {
            let isFocused = (windowID == focusedWindowID)

            // Skip inactive borders for tabbed cells
            if isActiveCellTabbed && !isFocused {
                continue
            }

            guard let border = createBorder(for: windowID) else { continue }

            let style = isFocused ? config.activeStyle : config.inactiveStyle
            updateBorderStyle(border, style: style, isActive: isFocused)

            if isFocused {
                activeBorder = border
            } else {
                inactiveBorders[windowID] = border
            }

            Task {
                JSONLogger.shared.log("bdr.create", data: [
                    "wid": windowID,
                    "role": isFocused ? "active" : "inactive"
                ])
            }
        }

        Task {
            JSONLogger.shared.log("bdr.rebuild", data: [
                "source": source,
                "cell": cellID,
                "count": windowsInCell.count,
                "focused": focusedWindowID ?? 0,
                "tabbed": isActiveCellTabbed
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
