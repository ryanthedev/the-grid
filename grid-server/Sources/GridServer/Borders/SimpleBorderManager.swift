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

    /// Set cell assignments received from CLI for a specific display
    /// - Parameters:
    ///   - assignments: Window-to-cell mappings
    ///   - displayUUID: Target display
    ///   - focusedWindowID: Optional - if provided, updates focus atomically (prevents race conditions)
    ///   - cellStackModes: Optional - cellID → stackMode ("tabs", "vertical", "horizontal")
    ///   - windowOrder: Optional - cellID → [windowID] ordered array for focus cycling
    ///   - displayFrame: Optional - display frame for layout context
    func setCellAssignments(_ assignments: [UInt32: String], forDisplay displayUUID: String, focusedWindowID: UInt32? = nil, cellStackModes: [String: String] = [:], windowOrder: [String: [UInt32]]? = nil, displayFrame: CGRect? = nil) {
        let span = CurrentSpan.current
        DispatchQueue.main.async { [weak self, span] in
            CurrentSpan.$current.withValue(span) {
                self?.setCellAssignmentsImpl(assignments, forDisplay: displayUUID, focusedWindowID: focusedWindowID, cellStackModes: cellStackModes, windowOrder: windowOrder, displayFrame: displayFrame)
            }
        }
    }

    private func setCellAssignmentsImpl(_ assignments: [UInt32: String], forDisplay displayUUID: String, focusedWindowID newFocusedWindow: UInt32? = nil, cellStackModes: [String: String] = [:], windowOrder: [String: [UInt32]]? = nil, displayFrame: CGRect? = nil) {
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

            // Update state
            focusedWindowID = newFocused
            activeCellID = cellID
            currentDisplayUUID = displayUUID

            // Detect display OR cell change
            let displayChanged = displayUUID != previousDisplayUUID
            if displayChanged || cellID != previousCellID {
                rebuildBorderPool(source: displayChanged ? "atomic-displayChange" : "atomic-cellChange")
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
                // Update style with new stack indicator (index changed)
                applyActiveStyle(to: border)
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
                    activeBorder = border
                    applyActiveStyle(to: border)
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
            activeBorder = border
            applyActiveStyle(to: border)
            Task {
                JSONLogger.shared.log("bdr.promote", data: ["wid": newFocused])
            }
        } else {
            // No border for this window (edge case: window appeared and auto-focused
            // before CLI sent assignments, then assignments arrived)
            if let border = createBorder(for: newFocused) {
                activeBorder = border
                applyActiveStyle(to: border)
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

        // Determine if cell is tabbed using actual stackMode (not window count)
        let stackModes = cellStackModesPerDisplay[displayUUID] ?? [:]
        let stackMode = stackModes[cellID] ?? "tabs"
        isActiveCellTabbed = (stackMode == "tabs")

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

            if isFocused {
                activeBorder = border
                applyActiveStyle(to: border)
            } else {
                inactiveBorders[windowID] = border
                updateBorderStyle(border, style: config.inactiveStyle, isActive: false)
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

        // Update active border style (with stack indicator)
        if let border = activeBorder {
            applyActiveStyle(to: border)
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

    /// Compute stack indicator for active border
    /// Always returns indicator (for position), even for single window
    private func computeStackIndicator() -> StackIndicator? {
        guard let cellID = activeCellID,
              let displayUUID = currentDisplayUUID,
              let assignments = cellAssignmentsPerDisplay[displayUUID],
              let focused = focusedWindowID else {
            return nil
        }

        // TODO: Window ordering should match focus cycling order
        let windowsInCell = assignments.filter { $0.value == cellID }.map { $0.key }.sorted()
        let currentIndex = windowsInCell.firstIndex(of: focused) ?? 0

        // Determine which edge faces screen center
        let position = computeInwardEdge(for: focused)

        return StackIndicator(
            totalCount: windowsInCell.count,
            currentIndex: currentIndex,
            position: position
        )
    }

    /// Compute which edge of the window faces toward screen center
    private func computeInwardEdge(for windowID: UInt32) -> StackIndicatorPosition {
        // Get window frame
        var windowFrame = CGRect.zero
        guard SLSGetWindowBounds(connectionID, windowID, &windowFrame) == .success else {
            return .leftCenter  // fallback
        }

        // Get main display bounds (simplified - assumes main display)
        guard let mainDisplay = CGMainDisplayID() as CGDirectDisplayID?,
              mainDisplay != 0 else {
            return .leftCenter
        }
        let screenWidth = CGFloat(CGDisplayPixelsWide(mainDisplay))

        // Window center X
        let windowCenterX = windowFrame.midX

        // If window is on left half of screen, inward edge is right
        // If window is on right half of screen, inward edge is left
        if windowCenterX < screenWidth / 2 {
            return .rightCenter
        } else {
            return .leftCenter
        }
    }

    /// Apply active style with stack indicator attached
    private func applyActiveStyle(to border: BorderWindow) {
        var style = BorderConfigManager.shared.activeStyle
        style.stackIndicator = computeStackIndicator()
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
