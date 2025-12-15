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
        cleanup()
    }

    // MARK: - IPC Handlers (receive data from CLI)

    /// Set cell bounds received from CLI
    func setCellBounds(_ bounds: [String: CGRect]) {
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
        cellAssignments = assignments

        logger.debug("Cell assignments updated", metadata: ["count": "\(assignments.count)"])

        // Re-evaluate focus state (focused window's cell may have changed)
        if let focusedWindow = focusedWindowID {
            let newCellID = cellAssignments[focusedWindow]
            if newCellID != focusedCellID {
                focusedCellID = newCellID
                updateCellHighlight()
            }
        }
    }

    // MARK: - Focus Management

    /// Update focus when a different window becomes active
    /// This is the main entry point for focus changes from BorderEvents
    func updateFocus(newFocusedWindow: UInt32) {
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
        guard windowID == focusedWindowID else { return }

        // Only the focused window has a border, update it
        if let border = windowBorder {
            let style = createWindowBorderStyle()
            border.scheduleUpdate(frame: newFrame, style: style)
        }
    }

    /// Handle window minimized (hide overlays if focused window is minimized)
    func handleWindowMinimized(windowID: UInt32) {
        guard windowID == focusedWindowID else { return }

        logger.debug("Focused window minimized", metadata: ["windowID": "\(windowID)"])

        // Hide both overlays
        cellHighlight.hide()
        windowBorder?.hide()
    }

    /// Handle window deminimized (show overlays if it regains focus)
    func handleWindowDeminimized(windowID: UInt32) {
        // Focus will be updated separately via handleWindowFocused
        // This is just for logging
        logger.debug("Window deminimized", metadata: ["windowID": "\(windowID)"])
    }

    /// Handle app hidden (hide overlays if focused window's app matches)
    func handleAppHidden(bundleID: String) {
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
        guard let windowID = focusedWindowID else { return }

        logger.debug("App unhidden event", metadata: [
            "bundleID": "\(bundleID)",
            "focusedWindow": "\(windowID)"
        ])

        // Re-evaluate focus state to restore overlays if needed
        updateCellHighlight()
        updateWindowBorder()
    }

    /// Handle space changed (re-evaluate focus and update overlays)
    func handleSpaceChanged() {
        logger.debug("Space changed event")

        // Re-evaluate focus state for the new space
        // Windows not on current space should have their overlays hidden
        guard let windowID = focusedWindowID else {
            // No focused window, ensure overlays are hidden
            cellHighlight.hide()
            windowBorder?.hide()
            return
        }

        // Verify focused window is still valid on current space
        var windowFrame = CGRect.zero
        let result = SLSGetWindowBounds(connectionID, windowID, &windowFrame)

        if result == .success {
            // Window exists on current space, update overlays
            updateCellHighlight()
            updateWindowBorder()
        } else {
            // Window not accessible (likely on different space), hide overlays
            cellHighlight.hide()
            windowBorder?.hide()
        }
    }

    /// Handle window destroyed (clear state if focused window destroyed)
    func handleWindowDestroyed(windowID: UInt32) {
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
        guard let cellID = focusedCellID,
              let frame = cellBounds[cellID] else {
            // No focused cell or no bounds for it → hide highlight
            cellHighlight.hide()
            return
        }

        // Show highlight at cell bounds
        cellHighlight.update(frame: frame)
        cellHighlight.show()
    }

    /// Update window border visibility and position
    private func updateWindowBorder() {
        guard let windowID = focusedWindowID else {
            // No focused window → hide border
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

        // Create or reuse window border
        if windowBorder == nil || windowBorder?.targetWindowID != windowID {
            // Destroy old border if target changed
            windowBorder?.destroy()

            // Create new border for new target
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

    /// Create BorderStyle for the focused window border
    private func createWindowBorderStyle() -> BorderStyle {
        // Get dynamic corner radius from target window if available
        var cornerRadius: CGFloat = 8.0
        if let border = windowBorder {
            cornerRadius = border.getTargetCornerRadius(fallback: 8.0)
        }

        return BorderStyle(
            color: SimpleBorderConfig.windowBorderColor,
            width: SimpleBorderConfig.windowBorderWidth,
            cornerRadius: cornerRadius,
            styleType: .round
        )
    }

    // MARK: - Cleanup

    /// Clean up all resources
    func cleanup() {
        cellHighlight.destroy()
        windowBorder?.destroy()
        windowBorder = nil

        logger.debug("SimpleBorderManager cleaned up")
    }
}
