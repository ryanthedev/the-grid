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

    /// Track current style type per window to detect changes (windowID → "active"/"inactive")
    /// Used to trigger border recreation when style changes
    private var windowStyleTypes: [UInt32: String] = [:]

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
        // Clear callback immediately (safe from any thread)
        BorderConfigManager.shared.onConfigChanged = nil

        if Thread.isMainThread {
            cleanupImpl()
        } else {
            // Capture borders before async dispatch - don't block with sync
            let bordersToDestroy = Array(windowBorders.values)
            DispatchQueue.main.async {
                for border in bordersToDestroy {
                    border.destroy()
                }
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
        // Get previous assignments for THIS display before updating
        let previousAssignments = cellAssignmentsPerDisplay[displayUUID] ?? [:]
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

        // Diff against PREVIOUS assignments for THIS display only
        // (not all borders globally - that would destroy other displays' borders)
        // 1. Destroy borders for windows no longer in THIS display's assignments
        let previousWindowIDs = Set(previousAssignments.keys)
        let newWindowIDs = Set(assignments.keys)
        let removedWindowIDs = previousWindowIDs.subtracting(newWindowIDs)

        for windowID in removedWindowIDs {
            if let border = windowBorders.removeValue(forKey: windowID) {
                border.destroy()
                windowStyleTypes.removeValue(forKey: windowID)
                Task {
                    await EventLog.shared.log("bdr.removed", [
                        "wid": windowID,
                        "reason": "no_longer_assigned"
                    ])
                }
            }
        }

        // 2. Create borders for new windows (in THIS display's assignments but not before)
        let addedWindowIDs = newWindowIDs.subtracting(previousWindowIDs)
        for windowID in addedWindowIDs {
            let border = BorderWindow(connectionID: connectionID, targetWindowID: windowID)
            if border.create() {
                // Verify window still exists before storing (could have been destroyed during create)
                var bounds = CGRect.zero
                guard SLSGetWindowBounds(connectionID, windowID, &bounds) == .success else {
                    border.destroy()
                    Task { await EventLog.shared.log("bdr.fail", ["wid": windowID, "reason": "window_gone_after_create"]) }
                    continue
                }

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

        // 3. DON'T call updateAllBorders() here - let focus events drive border updates
        // This avoids race conditions when CLI sends setCellAssignments before window.focus
        // The focus event will trigger updateAllBorders() with correct state
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

        // Update focus state
        focusedWindowID = newFocusedWindow

        // Get the window's display UUID
        let windowDisplayUUID = SLSCopyManagedDisplayForWindow(connectionID, newFocusedWindow) as String?

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

        // Update borders immediately - no debounce needed
        // The pending state mechanism handles rapid focus changes
        updateAllBorders()
    }

    /// Update visibility and style for all borders
    private func updateAllBorders() {
        guard let activeCell = activeCellID,
              let focusedWindow = focusedWindowID else {
            // No active cell - hide all borders
            // Copy before iterating to prevent mutation during iteration
            let borders = Array(windowBorders.values)
            for border in borders {
                border.hide(reason: "no_active_cell")
            }
            return
        }

        // Get current display's assignments
        guard let displayUUID = currentDisplayUUID,
              let assignments = cellAssignmentsPerDisplay[displayUUID] else {
            // No assignments - hide all borders
            let borders = Array(windowBorders.values)
            for border in borders {
                border.hide(reason: "no_assignments")
            }
            return
        }

        let config = BorderConfigManager.shared

        // Snapshot dictionary to prevent mutation during iteration
        let bordersCopy = windowBorders

        // Update each border based on its cell and focus state
        for (windowID, border) in bordersCopy {
            // Get window's cell assignment
            guard let windowCellID = assignments[windowID] else {
                // Window not in assignments - use updateStyle(nil) to properly hide
                // (ensures compositor alpha workaround is resolved, not just isVisible flag)
                border.updateStyle(style: nil, styleType: "not_assigned")
                continue
            }

            // Only show borders for windows in the active cell
            guard windowCellID == activeCell else {
                // Use updateStyle(nil) instead of hide() to properly handle alpha state
                border.updateStyle(style: nil, styleType: "cell_inactive")
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

            // Capture before Task to avoid data race (windowStyleTypes accessed on background thread)
            let prevStyleType = windowStyleTypes[windowID] ?? "none"
            let hasActiveStyle = config.activeStyle != nil
            let hasInactiveStyle = config.inactiveStyle != nil

            // ULTRADEBUG: Log style determination
            Task {
                await EventLog.shared.log("dbg.style", [
                    "wid": windowID,
                    "isFocused": isFocused,
                    "styleType": styleType,
                    "prevStyleType": prevStyleType,
                    "hasActiveStyle": hasActiveStyle,
                    "hasInactiveStyle": hasInactiveStyle
                ])
            }

            // Check if style type changed - if so, recreate the border window
            // SkyLight windows cache their content, so we must destroy and recreate
            let previousStyleType = windowStyleTypes[windowID]
            var currentBorder = border

            if let prev = previousStyleType, prev != styleType {
                // Style changed - destroy old border and create new one
                currentBorder.destroy()
                windowBorders.removeValue(forKey: windowID)

                let newBorder = BorderWindow(connectionID: connectionID, targetWindowID: windowID)
                if newBorder.create() {
                    // Verify target window still exists (could have been destroyed during create)
                    var bounds = CGRect.zero
                    guard SLSGetWindowBounds(connectionID, windowID, &bounds) == .success else {
                        newBorder.destroy()
                        windowStyleTypes.removeValue(forKey: windowID)
                        Task {
                            await EventLog.shared.log("err.bdr.recreate", ["wid": windowID, "reason": "target_gone"])
                        }
                        continue
                    }

                    windowBorders[windowID] = newBorder
                    currentBorder = newBorder
                    Task {
                        await EventLog.shared.log("bdr.recreate", [
                            "wid": windowID,
                            "from": prev,
                            "to": styleType
                        ])
                    }
                } else {
                    // Recreation failed - clean up state so we can try again on next focus change
                    windowStyleTypes.removeValue(forKey: windowID)
                    Task {
                        await EventLog.shared.log("err.bdr.recreate", [
                            "wid": windowID,
                            "warning": "window_has_no_border"
                        ])
                    }
                    continue
                }
            }

            // Update tracked style type
            windowStyleTypes[windowID] = styleType

            // Get window frame from SkyLight
            var windowFrame = CGRect.zero
            guard SLSGetWindowBounds(connectionID, windowID, &windowFrame) == .success else {
                currentBorder.hide(reason: "no_bounds")
                Task {
                    await EventLog.shared.log("bdr.hide", [
                        "wid": windowID,
                        "reason": "no_bounds"
                    ])
                }
                continue
            }

            // Update border position
            currentBorder.update(targetFrame: windowFrame)

            // Update border style (nil hides the border)
            currentBorder.updateStyle(style: style, styleType: styleType)

            // ULTRADEBUG: Log actual style values being applied
            Task {
                await EventLog.shared.log("dbg.updateStyle", [
                    "wid": windowID,
                    "styleType": styleType,
                    "styleNil": style == nil,
                    "opacity": style?.opacity ?? -1,
                    "cornerRadius": style?.cornerRadius ?? -1,
                    "width": style?.width ?? -1,
                    "shadowRadius": style?.shadowRadius ?? -1,
                    "shadowOpacity": style?.shadowOpacity ?? -1
                ])
            }

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
        // Note: Update position even if hidden - allows recovery when visibility is restored
        guard let border = windowBorders[windowID] else {
            return
        }

        // Update position (works for both visible and hidden borders)
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
        // Clear ALL focus state - space context is completely different
        activeCellID = nil
        focusedWindowID = nil
        currentDisplayUUID = nil
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
            windowStyleTypes.removeValue(forKey: windowID)

            Task {
                await EventLog.shared.log("bdr.removed", [
                    "wid": windowID,
                    "reason": "destroyed"
                ])
            }
        }

        // Clean up from all display caches to prevent unbounded growth
        for displayUUID in cellAssignmentsPerDisplay.keys {
            cellAssignmentsPerDisplay[displayUUID]?.removeValue(forKey: windowID)
        }

        // If this was the focused window, clear focus state
        if windowID == focusedWindowID {
            focusedWindowID = nil
            activeCellID = nil
        }
    }

    /// Handle display disconnected (clean up display-specific state)
    func handleDisplayDisconnected(displayUUID: String) {
        DispatchQueue.main.async { [weak self] in
            self?.handleDisplayDisconnectedImpl(displayUUID: displayUUID)
        }
    }

    private func handleDisplayDisconnectedImpl(displayUUID: String) {
        // Remove all borders for windows that were on this display
        if let assignments = cellAssignmentsPerDisplay.removeValue(forKey: displayUUID) {
            for windowID in assignments.keys {
                if let border = windowBorders.removeValue(forKey: windowID) {
                    border.destroy()
                    windowStyleTypes.removeValue(forKey: windowID)
                }

                // Clear focus if this was the focused window
                if windowID == focusedWindowID {
                    focusedWindowID = nil
                }
            }
            Task {
                await EventLog.shared.log("bdr.display_disconnect", [
                    "uuid": displayUUID,
                    "windows_cleaned": assignments.count
                ])
            }
        }
        cellBoundsPerDisplay.removeValue(forKey: displayUUID)

        // Clear current display if it was the disconnected one
        if currentDisplayUUID == displayUUID {
            currentDisplayUUID = nil
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
        guard let border = windowBorders[windowID] else {
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
        DispatchQueue.main.async { [weak self] in
            self?.cleanupImpl()
        }
    }

    private func cleanupImpl() {
        // Clear config callback to prevent retain issues
        BorderConfigManager.shared.onConfigChanged = nil

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

        guard result == .success, let ref = focusedWindowRef else {
            return nil
        }

        // SAFETY: AXUIElementCopyAttributeValue returns AXUIElement for kAXFocusedWindowAttribute
        // Force cast is safe after success check; AXUIElement is a CF type so as? always succeeds
        let axElement = ref as! AXUIElement

        var windowID: UInt32 = 0
        let axResult = _AXUIElementGetWindow(axElement, &windowID)

        guard axResult == .success, windowID != 0 else {
            return nil
        }

        return windowID
    }
}
