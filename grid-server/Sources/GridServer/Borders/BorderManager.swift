//
// BorderManager.swift
// GridServer
//
// Orchestrates border lifecycle and focus updates
//

import Foundation
import CoreGraphics
import Logging

/// Manages all window borders and focus state
///
/// **Thread Safety**: All methods must be called on the main queue.
/// The borders dictionary and focus state are not protected by locks
/// and assume single-threaded access.
class BorderManager {
    private let logger = Logger(label: "com.grid.BorderManager")
    private let connectionID: Int32

    /// Active borders by target window ID
    private var borders: [UInt32: BorderWindow] = [:]

    /// Configuration
    var config: BorderConfig

    /// Current focus state
    private var focusedWindowID: UInt32?
    internal var focusedCellID: String?

    /// Cell assignments from CLI (windowID → cellID)
    private var cellAssignments: [UInt32: String] = [:]

    /// Callback to get bundle ID for a window
    var getBundleIDForWindow: ((UInt32) -> String?)?

    init(connectionID: Int32, config: BorderConfig = BorderConfig()) {
        self.connectionID = connectionID
        self.config = config
    }

    // MARK: - Cell Assignment Management (from CLI via IPC)

    /// Set cell assignments received from CLI
    func setCellAssignments(_ assignments: [UInt32: String]) {
        cellAssignments = assignments
        logger.debug("Cell assignments updated", metadata: ["count": "\(assignments.count)"])
    }

    /// Set per-cell style override
    func setCellOverride(cellID: String, config: [String: Any]) {
        var override = CellBorderStyle()
        if let colorHex = config["activeCellColor"] as? String {
            override.activeCellColor = BorderConfig.parseColor(colorHex)
        }
        if let colorHex = config["inactiveColor"] as? String {
            override.inactiveColor = BorderConfig.parseColor(colorHex)
        }
        if let styleStr = config["style"] as? String, let style = BorderStyleType(rawValue: styleStr) {
            override.style = style
        }
        self.config.cellOverrides[cellID] = override
    }

    /// Get cell assignment for a window
    func getCellAssignment(for windowID: UInt32) -> String? {
        return cellAssignments[windowID]
    }

    /// Get all windows in a cell
    func getWindowsInCell(_ cellID: String) -> [UInt32] {
        return cellAssignments.filter { $0.value == cellID }.map { $0.key }
    }

    /// Refresh all borders (after config or cell assignment change)
    func refreshAllBorders() {
        let windowIDs = Array(borders.keys)  // Snapshot to prevent mutation during iteration
        for windowID in windowIDs {
            updateBorder(for: windowID)
        }
    }

    // MARK: - Border Lifecycle

    /// Create a border for a window
    func createBorder(for windowID: UInt32) {
        guard config.enabled else { return }
        guard borders[windowID] == nil else { return }

        // Check blacklist/whitelist
        if let bundleID = getBundleIDForWindow?(windowID) {
            if !config.shouldShowBorder(bundleID: bundleID) {
                logger.debug("Skipping border for blacklisted app", metadata: [
                    "windowID": "\(windowID)",
                    "bundleID": "\(bundleID)"
                ])
                return
            }
        } else if getBundleIDForWindow == nil {
            logger.warning("Bundle ID callback not set, filtering bypassed", metadata: [
                "windowID": "\(windowID)"
            ])
        }

        let border = BorderWindow(connectionID: connectionID, targetWindowID: windowID)

        guard border.create() else {
            logger.error("Failed to create border", metadata: ["windowID": "\(windowID)"])
            return
        }

        borders[windowID] = border

        // Initial draw
        updateBorder(for: windowID)
        border.show()

        logger.debug("Border created", metadata: ["windowID": "\(windowID)"])
    }

    /// Destroy a border for a window
    func destroyBorder(for windowID: UInt32) {
        guard let border = borders.removeValue(forKey: windowID) else { return }

        border.destroy()

        logger.debug("Border destroyed", metadata: ["windowID": "\(windowID)"])
    }

    /// Destroy all borders
    func destroyAllBorders() {
        for (windowID, border) in borders {
            border.destroy()
            logger.debug("Border destroyed", metadata: ["windowID": "\(windowID)"])
        }
        borders.removeAll()
    }

    // MARK: - Updates

    /// Update border position for a window
    func updatePosition(for windowID: UInt32, frame: CGRect) {
        guard let border = borders[windowID] else { return }

        let style = resolveStyle(for: windowID)
        border.update(targetFrame: frame, style: style)
    }

    /// Update border color for a window (e.g., focus changed)
    func updateBorder(for windowID: UInt32) {
        guard let border = borders[windowID] else { return }

        // Get current frame from SkyLight
        var frame = CGRect.zero
        guard SLSGetWindowBounds(connectionID, windowID, &frame) == .success else {
            logger.warning("Failed to get window bounds", metadata: ["windowID": "\(windowID)"])
            return
        }

        let style = resolveStyle(for: windowID)
        border.update(targetFrame: frame, style: style)
    }

    // MARK: - Focus Management

    /// Handle focus change (with transaction batching for performance)
    func updateFocus(newFocusedWindow: UInt32) {
        let oldFocusedWindow = focusedWindowID
        let oldFocusedCell = focusedCellID

        focusedWindowID = newFocusedWindow
        focusedCellID = cellAssignments[newFocusedWindow]

        logger.debug("Focus changed", metadata: [
            "oldWindow": "\(oldFocusedWindow?.description ?? "nil")",
            "newWindow": "\(newFocusedWindow)",
            "oldCell": "\(oldFocusedCell ?? "nil")",
            "newCell": "\(focusedCellID ?? "nil")"
        ])

        // Compute affected windows
        var affectedWindows: Set<UInt32> = []

        // Old focused window
        if let old = oldFocusedWindow {
            affectedWindows.insert(old)
        }

        // Old cell windows (if cell changed)
        if oldFocusedCell != focusedCellID, let oldCell = oldFocusedCell {
            let cellWindows = getWindowsInCell(oldCell)
            affectedWindows.formUnion(cellWindows)
        }

        // New cell windows
        if let newCell = focusedCellID {
            let cellWindows = getWindowsInCell(newCell)
            affectedWindows.formUnion(cellWindows)
        }

        // New focused window
        affectedWindows.insert(newFocusedWindow)

        // Use transaction for atomic batch update (performance optimization)
        if let transaction = SLSTransactionCreate(connectionID) {
            for windowID in affectedWindows {
                if let border = borders[windowID] {
                    SLSTransactionOrderWindow(transaction, border.windowID, -1, windowID)
                }
            }
            let result = SLSTransactionCommit(transaction, 1)
            if result != .success {
                logger.warning("Transaction commit failed", metadata: ["error": "\(result.rawValue)"])
            }
        } else {
            logger.warning("Failed to create transaction for focus update")
        }

        // Repaint affected borders
        for windowID in affectedWindows {
            updateBorder(for: windowID)
        }
    }

    // MARK: - Visibility

    /// Show border for a window
    func showBorder(for windowID: UInt32) {
        borders[windowID]?.show()
    }

    /// Hide border for a window
    func hideBorder(for windowID: UInt32) {
        borders[windowID]?.hide()
    }

    /// Show all borders
    func showAllBorders() {
        for border in borders.values {
            border.show()
        }
    }

    /// Hide all borders
    func hideAllBorders() {
        for border in borders.values {
            border.hide()
        }
    }

    // MARK: - Private Helpers

    /// Get focus tier for a window
    internal func getFocusTier(for windowID: UInt32) -> FocusTier {
        if windowID == focusedWindowID {
            return .activeWindow
        }

        let cellID = cellAssignments[windowID]
        if cellID != nil && cellID == focusedCellID {
            return .activeCell
        }

        return .inactive
    }

    /// Resolve the complete style for a window
    private func resolveStyle(for windowID: UInt32) -> BorderStyle {
        let tier = getFocusTier(for: windowID)
        let cellID = cellAssignments[windowID]
        let color = config.resolveColor(tier: tier, cellID: cellID)

        // Get dynamic corner radius from target window
        var cornerRadius = config.cornerRadius
        if let border = borders[windowID] {
            cornerRadius = border.getTargetCornerRadius(fallback: config.cornerRadius)
        }

        // Check for per-cell style override
        var styleType = config.style
        if let cellID = cellID, let override = config.cellOverrides[cellID]?.style {
            styleType = override
        }

        return BorderStyle(
            color: color,
            width: config.width,
            cornerRadius: cornerRadius,
            styleType: styleType
        )
    }
}
