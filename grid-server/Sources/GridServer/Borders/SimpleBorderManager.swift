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

    // MARK: - Border Management

    /// Per-window border overlays (windowID → BorderWindow)
    /// Each window in cellAssignments gets its own BorderWindow
    private var windowBorders: [UInt32: BorderWindow] = [:]

    init(connectionID: Int32) {
        self.connectionID = connectionID

        // Register for config changes to refresh border styles
        BorderConfigManager.shared.onConfigChanged = { [weak self] in
            DispatchQueue.main.async {
                self?.updateAllBorders()
            }
        }
    }

    deinit {
        // Call implementation directly - deinit already has exclusive access
        // Must be synchronous to ensure cleanup before deallocation
        if Thread.isMainThread {
            cleanupImpl()
        } else {
            DispatchQueue.main.sync {
                self.cleanupImpl()
            }
        }
    }

    // MARK: - IPC Handlers (receive data from CLI)

    /// Set cell bounds received from CLI for a specific display
    func setCellBounds(_ bounds: [String: CGRect], forDisplay displayUUID: String) {
        DispatchQueue.main.async { [weak self] in
            self?.setCellBoundsImpl(bounds, forDisplay: displayUUID)
        }
    }

    private func setCellBoundsImpl(_ bounds: [String: CGRect], forDisplay displayUUID: String) {
        cellBoundsPerDisplay[displayUUID] = bounds

        // Bounds updated, but we don't use them for positioning yet
        // (borders are sized from window frames, not cell bounds)
    }

    /// Set cell assignments received from CLI for a specific display
    func setCellAssignments(_ assignments: [UInt32: String], forDisplay displayUUID: String) {
        DispatchQueue.main.async { [weak self] in
            self?.setCellAssignmentsImpl(assignments, forDisplay: displayUUID)
        }
    }

    private func setCellAssignmentsImpl(_ assignments: [UInt32: String], forDisplay displayUUID: String) {
        cellAssignmentsPerDisplay[displayUUID] = assignments

        // If we don't have a focused window yet (startup case), query the OS
        if focusedWindowID == nil {
            if let queriedWindowID = queryCurrentFocusedWindow() {
                // Check if this window is in ANY display's assignments
                let (foundDisplayUUID, cellID) = findAssignment(for: queriedWindowID)
                if let cellID = cellID {
                    focusedWindowID = queriedWindowID
                    activeCellID = cellID
                    currentDisplayUUID = foundDisplayUUID
                }
            }
        }

        // Re-evaluate focus state if focused window is on this display
        if let focusedWindow = focusedWindowID {
            // Check if focused window is in this display's assignments
            if let newCellID = assignments[focusedWindow] {
                activeCellID = newCellID
                currentDisplayUUID = displayUUID
            }
        }

        // Diff existing borders against new assignments
        // 1. Destroy borders for windows no longer in assignments
        let currentWindowIDs = Set(windowBorders.keys)
        let newWindowIDs = Set(assignments.keys)
        let removedWindowIDs = currentWindowIDs.subtracting(newWindowIDs)

        for windowID in removedWindowIDs {
            if let border = windowBorders.removeValue(forKey: windowID) {
                border.destroy()
                Task {
                    await EventLog.shared.log("bdr.removed", [
                        "wid": windowID,
                        "reason": "no_longer_assigned"
                    ])
                }
            }
        }

        // 2. Create borders for new windows
        let addedWindowIDs = newWindowIDs.subtracting(currentWindowIDs)
        for windowID in addedWindowIDs {
            let border = BorderWindow(connectionID: connectionID, targetWindowID: windowID)
            if border.create() {
                windowBorders[windowID] = border
                Task {
                    await EventLog.shared.log("bdr.created", [
                        "wid": windowID,
                        "cell": assignments[windowID] ?? ""
                    ])
                }
            } else {
                Task {
                    await EventLog.shared.log("bdr.fail", [
                        "wid": windowID,
                        "reason": "create_failed"
                    ])
                }
            }
        }

        // 3. Update all border visibility and styles based on active cell
        updateAllBorders()
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
        DispatchQueue.main.async { [weak self] in
            self?.updateFocusImpl(newFocusedWindow: newFocusedWindow)
        }
    }

    private func updateFocusImpl(newFocusedWindow: UInt32) {
        // Ignore focus on our own overlay windows
        if isOurOverlayWindow(newFocusedWindow) {
            return
        }

        // Get the window's display UUID
        let windowDisplayUUID = SLSCopyManagedDisplayForWindow(connectionID, newFocusedWindow) as String?

        // Update focus state
        focusedWindowID = newFocusedWindow

        // Look up cell assignment from the window's display cache
        var foundCellID: String? = nil
        var foundDisplay: String? = windowDisplayUUID

        if let displayUUID = windowDisplayUUID,
           let assignments = cellAssignmentsPerDisplay[displayUUID] {
            foundCellID = assignments[newFocusedWindow]
            foundDisplay = displayUUID
        }

        // Fallback: search all displays if not found in primary
        if foundCellID == nil {
            let (fallbackDisplay, fallbackCellID) = findAssignment(for: newFocusedWindow)
            if fallbackCellID != nil {
                foundCellID = fallbackCellID
                foundDisplay = fallbackDisplay
            }
        }

        activeCellID = foundCellID
        currentDisplayUUID = foundDisplay

        // Update all borders based on new focus state
        updateAllBorders()
    }

    /// Update visibility and style for all borders
    private func updateAllBorders() {
        guard let activeCell = activeCellID,
              let focusedWindow = focusedWindowID else {
            // No active cell - hide all borders
            for (_, border) in windowBorders {
                border.hide(reason: "no_active_cell")
            }
            return
        }

        // Get current display's assignments
        guard let displayUUID = currentDisplayUUID,
              let assignments = cellAssignmentsPerDisplay[displayUUID] else {
            // No assignments - hide all borders
            for (_, border) in windowBorders {
                border.hide(reason: "no_assignments")
            }
            return
        }

        let config = BorderConfigManager.shared

        // Update each border based on its cell and focus state
        for (windowID, border) in windowBorders {
            // Get window's cell assignment
            guard let windowCellID = assignments[windowID] else {
                // Window not in assignments - should have been cleaned up
                border.hide(reason: "not_assigned")
                continue
            }

            // Only show borders for windows in the active cell
            guard windowCellID == activeCell else {
                border.hide(reason: "cell_inactive")
                continue
            }

            // Window is in active cell - determine style
            let isFocused = (windowID == focusedWindow)
            let style: BorderStyle?
            let styleType: String

            if isFocused {
                // Focused window gets active style
                style = config.activeStyle
                styleType = "active"
            } else {
                // Other windows in cell get inactive style (or nil if disabled)
                style = config.inactiveStyle
                styleType = "inactive"
            }

            // Get window frame from SkyLight
            var windowFrame = CGRect.zero
            guard SLSGetWindowBounds(connectionID, windowID, &windowFrame) == .success else {
                border.hide(reason: "no_bounds")
                Task {
                    await EventLog.shared.log("bdr.hide", [
                        "wid": windowID,
                        "reason": "no_bounds"
                    ])
                }
                continue
            }

            // Update border position
            border.update(targetFrame: windowFrame)

            // Update border style (nil hides the border)
            border.updateStyle(style: style, styleType: styleType)

            // Log if visible
            if style != nil {
                Task {
                    await EventLog.shared.log("bdr.show", [
                        "wid": windowID,
                        "style": styleType,
                        "cell": windowCellID,
                        "frame": [windowFrame.origin.x, windowFrame.origin.y, windowFrame.size.width, windowFrame.size.height]
                    ])
                }
            }
        }
    }

    /// Handle window moved (update window border position)
    func handleWindowMoved(windowID: UInt32, newFrame: CGRect) {
        DispatchQueue.main.async { [weak self] in
            self?.handleWindowMovedImpl(windowID: windowID, newFrame: newFrame)
        }
    }

    private func handleWindowMovedImpl(windowID: UInt32, newFrame: CGRect) {
        // Find the border for this window
        guard let border = windowBorders[windowID], border.isVisible else {
            return
        }

        // Update position
        border.update(targetFrame: newFrame)

        // Log border move event
        Task {
            await EventLog.shared.log("bdr.move", [
                "wid": windowID,
                "frame": [newFrame.origin.x, newFrame.origin.y, newFrame.size.width, newFrame.size.height]
            ])
        }
    }

    /// Handle window minimized (hide border if minimized)
    func handleWindowMinimized(windowID: UInt32) {
        DispatchQueue.main.async { [weak self] in
            self?.handleWindowMinimizedImpl(windowID: windowID)
        }
    }

    private func handleWindowMinimizedImpl(windowID: UInt32) {
        guard let border = windowBorders[windowID] else { return }

        border.hide(reason: "minimized")

        // Log border hide event
        Task {
            await EventLog.shared.log("bdr.hide", [
                "wid": windowID,
                "reason": "minimized"
            ])
        }
    }

    /// Handle window deminimized (show border if it should be visible)
    func handleWindowDeminimized(windowID: UInt32) {
        DispatchQueue.main.async { [weak self] in
            self?.handleWindowDeminimizedImpl(windowID: windowID)
        }
    }

    private func handleWindowDeminimizedImpl(windowID: UInt32) {
        // Re-evaluate borders to restore visibility if needed
        updateAllBorders()
    }

    /// Handle app hidden (hide borders for windows in this app)
    func handleAppHidden(bundleID: String) {
        DispatchQueue.main.async { [weak self] in
            self?.handleAppHiddenImpl(bundleID: bundleID)
        }
    }

    private func handleAppHiddenImpl(bundleID: String) {
        // Hide all borders (we don't track bundleID per window, so hide all)
        // Re-evaluation will happen on next focus event
        for (_, border) in windowBorders {
            border.hide(reason: "app_hidden")
        }

        // Log border hide event
        Task {
            await EventLog.shared.log("bdr.hide_all", [
                "reason": "app_hidden",
                "bundleID": bundleID
            ])
        }
    }

    /// Handle app unhidden (restore borders if needed)
    func handleAppUnhidden(bundleID: String) {
        DispatchQueue.main.async { [weak self] in
            self?.handleAppUnhiddenImpl(bundleID: bundleID)
        }
    }

    private func handleAppUnhiddenImpl(bundleID: String) {
        // Re-evaluate focus state to restore borders if needed
        updateAllBorders()
    }

    /// Handle space changed (reset focus state but preserve per-display caches)
    ///
    /// Per-display caches are preserved across space changes because:
    /// - Each display's assignments are independent
    /// - The new space may already have cached assignments from previous layout apply
    /// - CLI will send new assignments if needed
    ///
    /// We just clear focus-related state and hide all borders to prevent stale visuals.
    func handleSpaceChanged() {
        DispatchQueue.main.async { [weak self] in
            self?.handleSpaceChangedImpl()
        }
    }

    private func handleSpaceChangedImpl() {
        // Clear focus state (will be re-established by next focus event)
        activeCellID = nil
        // NOTE: Keep per-display caches - they remain valid for their respective displays

        // Hide all borders (don't destroy - assignments are still valid)
        for (_, border) in windowBorders {
            border.hide(reason: "space_changed")
        }
    }

    /// Handle window destroyed (remove border for destroyed window)
    func handleWindowDestroyed(windowID: UInt32) {
        DispatchQueue.main.async { [weak self] in
            self?.handleWindowDestroyedImpl(windowID: windowID)
        }
    }

    private func handleWindowDestroyedImpl(windowID: UInt32) {
        // Remove and destroy border for this window
        if let border = windowBorders.removeValue(forKey: windowID) {
            border.destroy()

            // Log border hide event
            Task {
                await EventLog.shared.log("bdr.hide", [
                    "wid": windowID,
                    "reason": "destroyed"
                ])
            }
        }

        // If this was the focused window, clear focus state
        if windowID == focusedWindowID {
            focusedWindowID = nil
            activeCellID = nil
        }
    }

    // MARK: - Private Helpers

    /// Check if a window ID belongs to one of our overlay windows
    private func isOurOverlayWindow(_ windowID: UInt32) -> Bool {
        // Check all borders in windowBorders
        for (_, border) in windowBorders {
            if border.windowID == windowID {
                return true
            }
        }
        return false
    }

    // MARK: - Cleanup

    /// Clean up all resources
    func cleanup() {
        DispatchQueue.main.async { [weak self] in
            self?.cleanupImpl()
        }
    }

    private func cleanupImpl() {
        // Destroy all borders
        for (_, border) in windowBorders {
            border.destroy()
        }
        windowBorders.removeAll()
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

        guard result == .success else {
            return nil
        }

        var windowID: UInt32 = 0
        let axResult = _AXUIElementGetWindow(focusedWindowRef as! AXUIElement, &windowID)

        guard axResult == .success, windowID != 0 else {
            return nil
        }

        return windowID
    }
}
