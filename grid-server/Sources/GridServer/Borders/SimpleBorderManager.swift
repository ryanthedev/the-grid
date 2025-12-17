//
// SimpleBorderManager.swift
// GridServer
//
// Orchestrates the simplified 2-element border system:
// 1. Cell Highlight - white background behind windows in active cell
// 2. Window Border - red border around focused window only
//

import Foundation
import CoreGraphics
import AppKit  // For NSWorkspace (focus query)

// Private AX API for getting window ID from AX element
@_silgen_name("_AXUIElementGetWindow")
private func _AXUIElementGetWindow(_ element: AXUIElement, _ windowID: UnsafeMutablePointer<UInt32>) -> AXError

/// Manages the simplified 2-element border system
///
/// **Visual behavior:**
/// - Cell highlight fills the active cell's grid area (behind windows)
/// - Window border wraps only the focused window
/// - Non-focused windows have NO borders
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

    /// Currently focused window ID
    private var focusedWindowID: UInt32?

    /// Currently focused cell ID (derived from focusedWindowID + cellAssignments)
    private var focusedCellID: String?

    // MARK: - Visual Elements (single instances, reused)

    /// Single cell highlight overlay (reused, repositioned on cell changes)
    private var cellHighlight: CellHighlight

    /// Single window border overlay (reused, repositioned on window focus changes)
    private var windowBorder: BorderWindow?

    init(connectionID: Int32) {
        self.connectionID = connectionID
        self.cellHighlight = CellHighlight(connectionID: connectionID)

        // Create the cell highlight overlay (initially hidden)
        _ = cellHighlight.create()
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

        // If we have a focused cell on this display, update highlight position
        if currentDisplayUUID == displayUUID,
           let cellID = focusedCellID,
           let frame = bounds[cellID] {
            cellHighlight.update(frame: frame)
        }
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
                    focusedCellID = cellID
                    currentDisplayUUID = foundDisplayUUID
                }
            }
        }

        // Re-evaluate focus state if focused window is on this display
        if let focusedWindow = focusedWindowID {
            // Check if focused window is in this display's assignments
            if let newCellID = assignments[focusedWindow] {
                focusedCellID = newCellID
                currentDisplayUUID = displayUUID

                // Always update border when we have a focused window
                updateCellHighlight()
                updateWindowBorder()
            }
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
        DispatchQueue.main.async { [weak self] in
            self?.updateFocusImpl(newFocusedWindow: newFocusedWindow)
        }
    }

    private func updateFocusImpl(newFocusedWindow: UInt32) {
        // Ignore focus on our own overlay windows
        if isOurOverlayWindow(newFocusedWindow) {
            return
        }

        let oldFocusedWindow = focusedWindowID
        let oldFocusedCell = focusedCellID
        let oldDisplayUUID = currentDisplayUUID

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

        focusedCellID = foundCellID
        currentDisplayUUID = foundDisplay

        // Update both visual elements
        updateCellHighlight()
        updateWindowBorder()
    }

    /// Handle window moved (update window border position)
    func handleWindowMoved(windowID: UInt32, newFrame: CGRect) {
        DispatchQueue.main.async { [weak self] in
            self?.handleWindowMovedImpl(windowID: windowID, newFrame: newFrame)
        }
    }

    private func handleWindowMovedImpl(windowID: UInt32, newFrame: CGRect) {
        guard windowID == focusedWindowID else { return }

        // Only the focused window has a border, update it
        if let border = windowBorder {
            let style = createWindowBorderStyle()
            border.scheduleUpdate(frame: newFrame, style: style)

            // Log border move event
            Task {
                await EventLog.shared.log("bdr.move", [
                    "wid": windowID,
                    "frame": [newFrame.origin.x, newFrame.origin.y, newFrame.size.width, newFrame.size.height]
                ])
            }
        }
    }

    /// Handle window minimized (hide overlays if focused window is minimized)
    func handleWindowMinimized(windowID: UInt32) {
        DispatchQueue.main.async { [weak self] in
            self?.handleWindowMinimizedImpl(windowID: windowID)
        }
    }

    private func handleWindowMinimizedImpl(windowID: UInt32) {
        guard windowID == focusedWindowID else { return }

        // Hide both overlays
        cellHighlight.hide()
        windowBorder?.hide()

        // Log border hide event
        Task {
            await EventLog.shared.log("bdr.hide", [
                "wid": windowID,
                "reason": "minimized"
            ])
        }
    }

    /// Handle window deminimized (show overlays if it regains focus)
    func handleWindowDeminimized(windowID: UInt32) {
        DispatchQueue.main.async { [weak self] in
            self?.handleWindowDeminimizedImpl(windowID: windowID)
        }
    }

    private func handleWindowDeminimizedImpl(windowID: UInt32) {
        // Focus will be updated separately via handleWindowFocused
    }

    /// Handle app hidden (hide overlays if focused window's app matches)
    func handleAppHidden(bundleID: String) {
        DispatchQueue.main.async { [weak self] in
            self?.handleAppHiddenImpl(bundleID: bundleID)
        }
    }

    private func handleAppHiddenImpl(bundleID: String) {
        guard let windowID = focusedWindowID else { return }

        // Hide both overlays
        cellHighlight.hide()
        windowBorder?.hide()

        // Log border hide event
        Task {
            await EventLog.shared.log("bdr.hide", [
                "wid": windowID,
                "reason": "app_hidden"
            ])
        }
    }

    /// Handle app unhidden (restore overlays if needed)
    func handleAppUnhidden(bundleID: String) {
        DispatchQueue.main.async { [weak self] in
            self?.handleAppUnhiddenImpl(bundleID: bundleID)
        }
    }

    private func handleAppUnhiddenImpl(bundleID: String) {
        guard focusedWindowID != nil else { return }

        // Re-evaluate focus state to restore overlays if needed
        updateCellHighlight()
        updateWindowBorder()
    }

    /// Handle space changed (reset focus state but preserve per-display caches)
    ///
    /// Per-display caches are preserved across space changes because:
    /// - Each display's assignments are independent
    /// - The new space may already have cached assignments from previous layout apply
    /// - CLI will send new assignments if needed
    ///
    /// We just clear focus-related state and destroy overlays to prevent stale visuals.
    func handleSpaceChanged() {
        DispatchQueue.main.async { [weak self] in
            self?.handleSpaceChangedImpl()
        }
    }

    private func handleSpaceChangedImpl() {
        // Clear focus state (will be re-established by next focus event)
        focusedCellID = nil
        // NOTE: Keep per-display caches - they remain valid for their respective displays

        // DESTROY both overlays (not just hide) - prevents stale window artifacts during transitions
        cellHighlight.hide()
        windowBorder?.destroy()
        windowBorder = nil
    }

    /// Handle window destroyed (clear state if focused window destroyed)
    func handleWindowDestroyed(windowID: UInt32) {
        DispatchQueue.main.async { [weak self] in
            self?.handleWindowDestroyedImpl(windowID: windowID)
        }
    }

    private func handleWindowDestroyedImpl(windowID: UInt32) {
        guard windowID == focusedWindowID else { return }

        // Clear focus state
        focusedWindowID = nil
        focusedCellID = nil

        // Hide both overlays
        cellHighlight.hide()
        windowBorder?.hide()

        // Log border hide event
        Task {
            await EventLog.shared.log("bdr.hide", [
                "wid": windowID,
                "reason": "destroyed"
            ])
        }

        // Destroy window border since target is gone
        windowBorder?.destroy()
        windowBorder = nil
    }

    // MARK: - Private Helpers

    /// Update cell highlight visibility and position
    ///
    /// DISABLED: Cell highlight is currently disabled. When enabled, it would:
    /// - Display a semi-transparent background behind windows in the focused cell
    /// - Draw a thin border around the cell's grid area
    /// - Help visually distinguish the active cell from other cells
    ///
    /// This feature is deferred for future consideration because:
    /// - The window border alone provides sufficient visual feedback for focus
    /// - Cell highlight behind windows can be visually distracting
    /// - Performance impact of additional overlay needs evaluation
    ///
    /// To enable: Remove the early return and implement cell bounds positioning logic.
    private func updateCellHighlight() {
        // DISABLED: Only showing window border for now (see function docs)
        cellHighlight.hide()
        return
    }

    /// Update window border visibility and position
    private func updateWindowBorder() {
        // Only show border if:
        // 1. There IS a focused window
        // 2. That window is in a managed cell (has cell assignment)
        // 3. That window is NOT one of our overlay windows
        guard let windowID = focusedWindowID,
              focusedCellID != nil,
              !isOurOverlayWindow(windowID) else {
            windowBorder?.hide()

            // Log border hide event if there was a focused window
            if let wid = focusedWindowID {
                Task {
                    await EventLog.shared.log("bdr.hide", [
                        "wid": wid,
                        "reason": "no_cell"
                    ])
                }
            }
            return
        }

        // Get window frame from SkyLight
        var windowFrame = CGRect.zero
        guard SLSGetWindowBounds(connectionID, windowID, &windowFrame) == .success else {
            windowBorder?.hide()

            // Log border hide event
            Task {
                await EventLog.shared.log("bdr.hide", [
                    "wid": windowID,
                    "reason": "no_bounds"
                ])
            }
            return
        }

        // Create or reuse window border
        if let existingBorder = windowBorder {
            // Reuse existing border - just retarget if needed
            if existingBorder.targetWindowID != windowID {
                existingBorder.retarget(to: windowID)
            }
        } else {
            // No border exists - create new one
            let border = BorderWindow(connectionID: connectionID, targetWindowID: windowID)
            guard border.create() else {
                Task { await EventLog.shared.log("bdr.fail", ["wid": windowID, "reason": "create_failed"]) }
                return
            }
            windowBorder = border
        }

        // Update position and show
        let style = createWindowBorderStyle()
        windowBorder?.update(targetFrame: windowFrame, style: style)
        windowBorder?.show()

        // Log border show event
        Task {
            await EventLog.shared.log("bdr.show", [
                "wid": windowID,
                "cell": focusedCellID ?? "",
                "frame": [windowFrame.origin.x, windowFrame.origin.y, windowFrame.size.width, windowFrame.size.height]
            ])
        }
    }

    /// Check if a window ID belongs to one of our overlay windows
    private func isOurOverlayWindow(_ windowID: UInt32) -> Bool {
        // Check cell highlight
        if cellHighlight.windowID == windowID {
            return true
        }
        // Check window border
        if let border = windowBorder, border.windowID == windowID {
            return true
        }
        return false
    }

    /// Create BorderStyle for the focused window border
    private func createWindowBorderStyle() -> BorderStyle {
        let config = BorderConfigManager.shared

        // Get dynamic corner radius - prefer target window's radius, fall back to config
        var cornerRadius = config.cornerRadius
        if let border = windowBorder {
            cornerRadius = border.getTargetCornerRadius(fallback: config.cornerRadius)
        }

        // Map style string to BorderStyleType
        let styleType: BorderStyleType
        switch config.style.lowercased() {
        case "square":
            styleType = .square
        case "uniform":
            styleType = .uniform
        default:
            styleType = .round
        }

        return BorderStyle(
            color: SimpleBorderConfig.windowBorderColor,
            width: SimpleBorderConfig.windowBorderWidth,
            cornerRadius: cornerRadius,
            styleType: styleType
        )
    }

    // MARK: - Cleanup

    /// Clean up all resources
    func cleanup() {
        DispatchQueue.main.async { [weak self] in
            self?.cleanupImpl()
        }
    }

    private func cleanupImpl() {
        cellHighlight.destroy()
        windowBorder?.destroy()
        windowBorder = nil
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
