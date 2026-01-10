//
// PickerWindow.swift
// GridServer
//
// SkyLight overlay window for the picker UI
//

import Foundation
import CoreGraphics
import AppKit

/// A floating overlay window for the picker UI, centered on the mouse cursor
class PickerWindow {
    private let connectionID: Int32

    /// Our overlay window ID
    private(set) var windowID: UInt32 = 0

    /// Drawing context
    private var context: CGContext?

    /// Current bounds of the window
    private(set) var currentBounds: CGRect = .zero

    /// Whether the window is currently visible
    private(set) var isVisible: Bool = false

    init(connectionID: Int32) {
        self.connectionID = connectionID
    }

    deinit {
        let wid = windowID
        destroy()
        JSONLogger.shared.log("pkr.wnd.destroy", data: ["wid": wid])
    }

    // MARK: - Lifecycle

    /// Create the overlay window with the given size, centered on mouse cursor
    /// - Parameter size: The size of the picker window
    /// - Returns: true if window was created successfully
    func create(size: CGSize) -> Bool {
        guard windowID == 0 else {
            JSONLogger.shared.log("warn.pkr.exists", data: ["wid": windowID])
            return true
        }

        // Get current mouse position (in screen coordinates)
        let mouseLocation = NSEvent.mouseLocation

        // Convert from AppKit coordinates (origin at bottom-left) to CoreGraphics (origin at top-left)
        // Get the screen containing the mouse
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(mouseLocation, $0.frame, false) })
                ?? NSScreen.main else {
            JSONLogger.shared.log("pkr.fail", data: ["reason": "no_screen"])
            return false
        }

        // Calculate centered position
        // AppKit: origin at bottom-left of primary display
        // CoreGraphics: origin at top-left of primary display
        let primaryHeight = NSScreen.screens.first?.frame.height ?? screen.frame.height
        let cgMouseY = primaryHeight - mouseLocation.y

        let origin = CGPoint(
            x: mouseLocation.x - size.width / 2,
            y: cgMouseY - size.height / 2
        )

        // Create CFTypeRef region from CGRect (required by SLSNewWindow)
        var bounds = CGRect(origin: .zero, size: size)
        var region: CFTypeRef?
        guard CGSNewRegionWithRect(&bounds, &region) == .success, let frameRegion = region else {
            JSONLogger.shared.log("pkr.fail", data: ["reason": "region_failed"])
            return false
        }

        // Create the window
        var newWindowID: UInt32 = 0
        let result = SLSNewWindow(
            connectionID,
            2,  // kCGBackingStoreBuffered
            origin.x,
            origin.y,
            frameRegion,
            &newWindowID
        )

        guard result == .success, newWindowID != 0 else {
            JSONLogger.shared.log("pkr.fail", data: ["error": result.rawValue, "reason": "window_create_failed"])
            return false
        }

        self.windowID = newWindowID
        self.currentBounds = CGRect(origin: origin, size: size)

        // Set window tags: floating, no shadow, sticky (visible on all spaces)
        var tags: UInt64 = WindowTags.floating | WindowTags.noShadow | WindowTags.sticky
        _ = SLSSetWindowTags(connectionID, windowID, &tags, 64)

        // Make window transparent
        _ = SLSSetWindowOpacity(connectionID, windowID, false)
        _ = SLSSetWindowAlpha(connectionID, windowID, 0.0)

        // Set window level above normal windows (floating panel level)
        // CGWindowLevelForKey(.floatingWindowLevelKey) = 5
        _ = SLSSetWindowLevel(connectionID, windowID, 5)

        // Create drawing context
        context = SLWindowContextCreate(connectionID, windowID, nil)

        if context == nil {
            JSONLogger.shared.log("pkr.fail", data: ["wid": windowID, "reason": "no_context"])
            _ = SLSReleaseWindow(connectionID, windowID)
            self.windowID = 0
            return false
        }

        JSONLogger.shared.log("pkr.wnd.create", data: [
            "wid": windowID,
            "origin": [origin.x, origin.y],
            "size": [size.width, size.height]
        ])

        return true
    }

    /// Destroy the overlay window
    func destroy() {
        guard windowID != 0 else { return }

        hide()
        context = nil
        _ = SLSReleaseWindow(connectionID, windowID)
        windowID = 0
        isVisible = false
    }

    // MARK: - Visibility

    /// Show the window
    func show() {
        guard windowID != 0 else { return }

        _ = SLSSetWindowAlpha(connectionID, windowID, 1.0)
        // Order above everything (0 = kCGWindowAbove)
        _ = SLSOrderWindow(connectionID, windowID, 1, 0)

        isVisible = true
        JSONLogger.shared.log("pkr.wnd.show", data: ["wid": windowID])
    }

    /// Hide the window
    func hide() {
        guard windowID != 0 else { return }
        guard isVisible else { return }

        _ = SLSSetWindowAlpha(connectionID, windowID, 0.0)
        _ = SLSOrderWindow(connectionID, windowID, 0, 0)  // Remove from ordering

        isVisible = false
        JSONLogger.shared.log("pkr.wnd.hide", data: ["wid": windowID])
    }

    // MARK: - Drawing

    /// Get the drawing context for rendering
    /// - Returns: The CGContext if available, nil otherwise
    func getContext() -> CGContext? {
        guard windowID != 0 else { return nil }

        // CRITICAL: Flush before creating context (clears backing store)
        // Then create fresh context for drawing
        _ = SLSFlushWindowContentRegion(connectionID, windowID, nil)
        context = SLWindowContextCreate(connectionID, windowID, nil)

        return context
    }

    /// Flush the window content to screen after drawing
    func flush() {
        guard windowID != 0 else { return }
        _ = SLSFlushWindowContentRegion(connectionID, windowID, nil)
    }

    /// Get the drawable bounds (origin at 0,0 with current size)
    func getDrawableBounds() -> CGRect {
        return CGRect(origin: .zero, size: currentBounds.size)
    }

    // MARK: - Resize

    /// Resize the window to a new size
    /// - Parameter newSize: The new size for the window
    /// - Returns: true if resize was successful
    func resize(to newSize: CGSize) -> Bool {
        guard windowID != 0 else { return false }
        guard newSize != currentBounds.size else { return true }

        let wasVisible = isVisible

        // Hide window during resize to prevent compositor race
        if wasVisible {
            _ = SLSSetWindowAlpha(connectionID, windowID, 0.0)
        }

        // Create new region for the size
        var bounds = CGRect(origin: .zero, size: newSize)
        var region: CFTypeRef?
        guard CGSNewRegionWithRect(&bounds, &region) == .success, let shapeRegion = region else {
            if wasVisible {
                _ = SLSSetWindowAlpha(connectionID, windowID, 1.0)
            }
            return false
        }

        _ = SLSSetWindowShape(connectionID, windowID, 0, 0, shapeRegion)

        // Re-apply position after shape change
        var origin = currentBounds.origin
        _ = SLSMoveWindow(connectionID, windowID, &origin)

        // Update bounds and recreate context
        currentBounds = CGRect(origin: currentBounds.origin, size: newSize)
        context = nil

        // Restore visibility
        if wasVisible {
            _ = SLSFlushWindowContentRegion(connectionID, windowID, nil)
            context = SLWindowContextCreate(connectionID, windowID, nil)
            _ = SLSSetWindowAlpha(connectionID, windowID, 1.0)
        }

        return true
    }
}
