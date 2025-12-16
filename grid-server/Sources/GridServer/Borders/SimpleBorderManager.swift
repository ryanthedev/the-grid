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
import Logging
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
    private let logger = Logger(label: "com.grid.SimpleBorderManager")
    private let connectionID: Int32

    // MARK: - State from CLI (via IPC)

    /// Cell bounds received from CLI (cellID → CGRect)
    private var cellBounds: [String: CGRect] = [:]

    /// Cell assignments received from CLI (windowID → cellID)
    private var cellAssignments: [UInt32: String] = [:]

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

    /// Set cell bounds received from CLI
    func setCellBounds(_ bounds: [String: CGRect]) {
        DispatchQueue.main.async { [weak self] in
            self?.setCellBoundsImpl(bounds)
        }
    }

    private func setCellBoundsImpl(_ bounds: [String: CGRect]) {
        cellBounds = bounds

        logger.info("Cell bounds updated", metadata: [
            "count": "\(bounds.count)",
            "cells": "\(bounds.keys.sorted().joined(separator: ", "))"
        ])

        // If we have a focused cell, update highlight position
        if let cellID = focusedCellID, let frame = cellBounds[cellID] {
            cellHighlight.update(frame: frame)
        }
    }

    /// Set cell assignments received from CLI
    func setCellAssignments(_ assignments: [UInt32: String]) {
        DispatchQueue.main.async { [weak self] in
            self?.setCellAssignmentsImpl(assignments)
        }
    }

    private func setCellAssignmentsImpl(_ assignments: [UInt32: String]) {
        cellAssignments = assignments

        logger.debug("Cell assignments updated", metadata: ["count": "\(assignments.count)"])

        // If we don't have a focused window yet (startup case), query the OS
        if focusedWindowID == nil {
            if let queriedWindowID = queryCurrentFocusedWindow(),
               cellAssignments[queriedWindowID] != nil {
                logger.info("Initializing focus from OS query", metadata: [
                    "windowID": "\(queriedWindowID)"
                ])
                focusedWindowID = queriedWindowID
                focusedCellID = cellAssignments[queriedWindowID]
            }
        }

        // Re-evaluate focus state (focused window's cell may have changed)
        if let focusedWindow = focusedWindowID {
            let oldCellID = focusedCellID
            let newCellID = cellAssignments[focusedWindow]
            focusedCellID = newCellID

            // Always update border when we have a focused window
            // This handles the case where assignments arrive after focus change
            updateCellHighlight()
            updateWindowBorder()

            if newCellID != oldCellID {
                logger.debug("Focused window cell changed", metadata: [
                    "windowID": "\(focusedWindow)",
                    "oldCell": "\(oldCellID ?? "nil")",
                    "newCell": "\(newCellID ?? "nil")"
                ])
            }
        }
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
            logger.debug("Ignoring focus on our overlay window", metadata: ["windowID": "\(newFocusedWindow)"])
            return
        }

        let oldFocusedWindow = focusedWindowID
        let oldFocusedCell = focusedCellID

        // Update focus state
        focusedWindowID = newFocusedWindow
        focusedCellID = cellAssignments[newFocusedWindow]

        logger.info("Focus changed", metadata: [
            "oldWindow": "\(oldFocusedWindow?.description ?? "nil")",
            "newWindow": "\(newFocusedWindow)",
            "oldCell": "\(oldFocusedCell ?? "nil")",
            "newCell": "\(focusedCellID ?? "nil")"
        ])

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

        logger.debug("Focused window minimized", metadata: ["windowID": "\(windowID)"])

        // Hide both overlays
        cellHighlight.hide()
        windowBorder?.hide()
    }

    /// Handle window deminimized (show overlays if it regains focus)
    func handleWindowDeminimized(windowID: UInt32) {
        DispatchQueue.main.async { [weak self] in
            self?.handleWindowDeminimizedImpl(windowID: windowID)
        }
    }

    private func handleWindowDeminimizedImpl(windowID: UInt32) {
        // Focus will be updated separately via handleWindowFocused
        // This is just for logging
        logger.debug("Window deminimized", metadata: ["windowID": "\(windowID)"])
    }

    /// Handle app hidden (hide overlays if focused window's app matches)
    func handleAppHidden(bundleID: String) {
        DispatchQueue.main.async { [weak self] in
            self?.handleAppHiddenImpl(bundleID: bundleID)
        }
    }

    private func handleAppHiddenImpl(bundleID: String) {
        guard let windowID = focusedWindowID else { return }

        // Check if focused window belongs to the hidden app
        // We don't have direct access to bundleID mapping here, but BorderEvents
        // will only call this if relevant. Hide overlays defensively.
        logger.debug("App hidden event", metadata: [
            "bundleID": "\(bundleID)",
            "focusedWindow": "\(windowID)"
        ])

        // Hide both overlays
        cellHighlight.hide()
        windowBorder?.hide()
    }

    /// Handle app unhidden (restore overlays if needed)
    func handleAppUnhidden(bundleID: String) {
        DispatchQueue.main.async { [weak self] in
            self?.handleAppUnhiddenImpl(bundleID: bundleID)
        }
    }

    private func handleAppUnhiddenImpl(bundleID: String) {
        guard let windowID = focusedWindowID else { return }

        logger.debug("App unhidden event", metadata: [
            "bundleID": "\(bundleID)",
            "focusedWindow": "\(windowID)"
        ])

        // Re-evaluate focus state to restore overlays if needed
        updateCellHighlight()
        updateWindowBorder()
    }

    /// Handle space changed (clear space-specific state and destroy overlays)
    ///
    /// Cell assignments and bounds are space-specific - they're only valid for the space
    /// where the layout was applied. When changing to a different space:
    /// 1. Clear all space-specific state (cellBounds, cellAssignments, focusedCellID)
    /// 2. DESTROY overlays (not just hide) to prevent stale window artifacts
    /// 3. Keep focusedWindowID - the OS will send focus events if needed
    func handleSpaceChanged() {
        DispatchQueue.main.async { [weak self] in
            self?.handleSpaceChangedImpl()
        }
    }

    private func handleSpaceChangedImpl() {
        logger.info("Space changed - clearing space-specific border state", metadata: [
            "previousCellBoundsCount": "\(cellBounds.count)",
            "previousCellAssignmentsCount": "\(cellAssignments.count)",
            "previousFocusedCellID": "\(focusedCellID ?? "nil")",
            "focusedWindowID": "\(focusedWindowID?.description ?? "nil")"
        ])

        // Clear space-specific state (assignments are only valid for one space)
        cellBounds = [:]
        cellAssignments = [:]
        focusedCellID = nil

        // DESTROY both overlays (not just hide) - prevents stale window artifacts during transitions
        cellHighlight.hide()
        windowBorder?.destroy()
        windowBorder = nil

        logger.debug("Space change: overlays destroyed, waiting for CLI to send new assignments")
    }

    /// Handle window destroyed (clear state if focused window destroyed)
    func handleWindowDestroyed(windowID: UInt32) {
        DispatchQueue.main.async { [weak self] in
            self?.handleWindowDestroyedImpl(windowID: windowID)
        }
    }

    private func handleWindowDestroyedImpl(windowID: UInt32) {
        guard windowID == focusedWindowID else { return }

        logger.debug("Focused window destroyed", metadata: ["windowID": "\(windowID)"])

        // Clear focus state
        focusedWindowID = nil
        focusedCellID = nil

        // Hide both overlays
        cellHighlight.hide()
        windowBorder?.hide()

        // Destroy window border since target is gone
        windowBorder?.destroy()
        windowBorder = nil
    }

    // MARK: - Private Helpers

    /// Update cell highlight visibility and position
    private func updateCellHighlight() {
        // DISABLED: Only showing window border for now
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
            logger.debug("Border hidden - no valid cell assignment", metadata: [
                "focusedWindowID": "\(focusedWindowID?.description ?? "nil")",
                "focusedCellID": "\(focusedCellID ?? "nil")"
            ])
            windowBorder?.hide()
            return
        }

        // Get window frame from SkyLight
        var windowFrame = CGRect.zero
        guard SLSGetWindowBounds(connectionID, windowID, &windowFrame) == .success else {
            logger.warning("Failed to get window bounds", metadata: ["windowID": "\(windowID)"])
            windowBorder?.hide()
            return
        }

        // Get display for diagnostic logging
        let targetDisplay = SLSCopyManagedDisplayForWindow(connectionID, windowID) as String? ?? "unknown"

        logger.debug("Border positioning", metadata: [
            "windowID": "\(windowID)",
            "cellID": "\(focusedCellID ?? "nil")",
            "windowFrame": "(\(windowFrame.origin.x), \(windowFrame.origin.y), \(windowFrame.size.width), \(windowFrame.size.height))",
            "targetDisplay": "\(targetDisplay)",
            "cellBoundsCount": "\(cellBounds.count)",
            "cellAssignmentsCount": "\(cellAssignments.count)"
        ])

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
                logger.error("Failed to create window border", metadata: ["windowID": "\(windowID)"])
                return
            }
            windowBorder = border
        }

        // Update position and show
        let style = createWindowBorderStyle()
        windowBorder?.update(targetFrame: windowFrame, style: style)
        windowBorder?.show()
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

        logger.debug("SimpleBorderManager cleaned up")
    }

    // MARK: - Focus Query

    /// Query the currently focused window from the OS using AX APIs.
    /// Used during startup when no focus events have been received yet.
    /// - Returns: The window ID of the currently focused window, or nil if unavailable
    private func queryCurrentFocusedWindow() -> UInt32? {
        guard let frontApp = NSWorkspace.shared.frontmostApplication else {
            logger.debug("No frontmost application found during focus query")
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
            logger.debug("No focused window for frontmost app", metadata: [
                "app": "\(frontApp.localizedName ?? "unknown")",
                "axResult": "\(result.rawValue)"
            ])
            return nil
        }

        var windowID: UInt32 = 0
        let axResult = _AXUIElementGetWindow(focusedWindowRef as! AXUIElement, &windowID)

        guard axResult == .success, windowID != 0 else {
            logger.debug("Failed to get window ID from AX element", metadata: [
                "axResult": "\(axResult.rawValue)"
            ])
            return nil
        }

        return windowID
    }
}
