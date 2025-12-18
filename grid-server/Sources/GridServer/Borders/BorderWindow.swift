//
// BorderWindow.swift
// GridServer
//
// SkyLight overlay window for rendering a single border
//

import Foundation
import CoreGraphics

/// A single border overlay window that tracks a target window
class BorderWindow {
    private let connectionID: Int32

    /// Our overlay window ID
    private(set) var windowID: UInt32 = 0

    /// Target window we're drawing around (set once at init, never changes)
    let targetWindowID: UInt32

    /// Drawing context
    private var context: CGContext?

    /// Current bounds of the border
    private var currentBounds: CGRect = .zero

    /// Current style
    private var currentStyle: BorderStyle?

    /// Whether the border is currently visible
    private(set) var isVisible: Bool = false

    /// Get current style info for debugging/querying
    var styleInfo: (color: [CGFloat], width: CGFloat, isVisible: Bool)? {
        guard let style = currentStyle else { return nil }
        let components = style.color.components ?? []
        return (color: components, width: style.width, isVisible: isVisible)
    }

    /// Border padding (space between window edge and border)
    /// Uses dynamic value from config
    var padding: CGFloat {
        BorderConfigManager.shared.padding
    }


    init(connectionID: Int32, targetWindowID: UInt32) {
        self.connectionID = connectionID
        self.targetWindowID = targetWindowID
    }

    deinit {
        // Capture values BEFORE any operations to avoid capturing self during deallocation
        let wid = windowID
        let targetID = targetWindowID
        destroy()
        // Use captured values (not self.properties) to avoid Swift runtime abort
        Task { await EventLog.shared.log("bdr.destroy", ["wid": wid, "targetID": targetID]) }
    }

    // MARK: - Lifecycle

    /// Create the overlay window
    func create() -> Bool {
        guard windowID == 0 else {
            Task { await EventLog.shared.log("warn.bdr.exists", ["targetID": targetWindowID]) }
            return true
        }

        // Get target window bounds to size our overlay
        var targetBounds = CGRect.zero
        guard SLSGetWindowBounds(connectionID, targetWindowID, &targetBounds) == .success else {
            Task { await EventLog.shared.log("bdr.fail", ["targetID": targetWindowID, "reason": "no_bounds"]) }
            return false
        }

        // Create CFTypeRef region from CGRect (required by SLSNewWindow)
        var bounds = CGRect(origin: .zero, size: targetBounds.size)
        var region: CFTypeRef?
        guard CGSNewRegionWithRect(&bounds, &region) == .success, let frameRegion = region else {
            Task { await EventLog.shared.log("bdr.fail", ["targetID": targetWindowID, "reason": "region_failed"]) }
            return false
        }

        // Create the window
        // Backing store = 2 (buffered), initial position offscreen
        var newWindowID: UInt32 = 0
        let result = SLSNewWindow(
            connectionID,
            2,  // kCGBackingStoreBuffered
            -9999,
            -9999,
            frameRegion,
            &newWindowID
        )

        guard result == .success, newWindowID != 0 else {
            Task { await EventLog.shared.log("bdr.fail", ["targetID": targetWindowID, "error": result.rawValue, "reason": "window_create_failed"]) }
            return false
        }

        self.windowID = newWindowID

        // Set window tags: floating, no shadow
        var tags: UInt64 = WindowTags.floating | WindowTags.noShadow
        let tagsResult = SLSSetWindowTags(connectionID, windowID, &tags, 64)

        // Make window transparent
        let opacityResult = SLSSetWindowOpacity(connectionID, windowID, false)
        let alphaResult = SLSSetWindowAlpha(connectionID, windowID, 0.0)

        // Set window level below normal windows
        let levelResult = SLSSetWindowLevel(connectionID, windowID, -1)

        // Log if any setup step failed
        if tagsResult != .success || opacityResult != .success ||
           alphaResult != .success || levelResult != .success {
            Task {
                await EventLog.shared.log("warn.bdr.setup", [
                    "wid": windowID,
                    "tags": tagsResult.rawValue,
                    "opacity": opacityResult.rawValue,
                    "alpha": alphaResult.rawValue,
                    "level": levelResult.rawValue
                ])
            }
        }

        // Create drawing context
        context = SLWindowContextCreate(connectionID, windowID, nil)

        if context == nil {
            Task { await EventLog.shared.log("bdr.fail", ["wid": windowID, "reason": "no_context"]) }
            // Clean up the window we just created
            _ = SLSReleaseWindow(connectionID, windowID)
            self.windowID = 0
            return false
        }

        // Move border to same space as target window
        moveToTargetSpace()

        Task { await EventLog.shared.log("bdr.create", ["wid": windowID, "targetID": targetWindowID]) }
        return true
    }

    /// Destroy the overlay window
    func destroy() {
        guard windowID != 0 else { return }

        // CRITICAL: Hide window before releasing (removes from screen)
        hide()

        context = nil
        _ = SLSReleaseWindow(connectionID, windowID)

        windowID = 0
        isVisible = false
    }

    // MARK: - Visibility

    /// Show the border
    func show() {
        guard windowID != 0 else { return }

        // Get spaces for diagnostic check
        let borderSpace = queryWindowSpace(windowID) ?? 0
        let targetSpace = queryWindowSpace(targetWindowID) ?? 0

        // If spaces don't match, move border to target's space before showing
        if borderSpace != targetSpace && targetSpace != 0 {
            moveToTargetSpace()
        }

        let alphaResult = SLSSetWindowAlpha(connectionID, windowID, 1.0)
        let orderResult = SLSOrderWindow(connectionID, windowID, -1, targetWindowID)  // Below target

        isVisible = true

        Task {
            await EventLog.shared.log("dbg.bdr.show", [
                "wid": windowID,
                "targetID": targetWindowID,
                "borderSpace": borderSpace,
                "targetSpace": targetSpace,
                "alphaResult": alphaResult.rawValue,
                "orderResult": orderResult.rawValue
            ])
        }
    }

    /// Hide the border
    /// - Parameter reason: Optional reason for hiding (for logging)
    func hide(reason: String = "unspecified") {
        guard windowID != 0 else { return }
        guard isVisible else { return }

        _ = SLSSetWindowAlpha(connectionID, windowID, 0.0)
        _ = SLSOrderWindow(connectionID, windowID, 0, 0)  // Remove from ordering

        isVisible = false

        Task { await EventLog.shared.log("bdr.hide", ["wid": windowID, "targetID": targetWindowID, "reason": reason]) }
    }

    // MARK: - Update

    /// Update border position and size to match target window
    func update(targetFrame: CGRect) {
        guard windowID != 0 else { return }

        // Calculate border bounds (larger than target by width + padding on each side)
        // Use current style's width if available, otherwise use active style's width as default
        let borderWidth = currentStyle?.width ?? BorderConfigManager.shared.activeStyle.width
        let expansion = borderWidth + padding
        let borderBounds = targetFrame.insetBy(dx: -expansion, dy: -expansion)

        // Move the window
        var origin = borderBounds.origin
        _ = SLSMoveWindow(connectionID, windowID, &origin)

        Task { await EventLog.shared.log("bdr.move", ["wid": windowID, "targetID": targetWindowID, "frame": [borderBounds.origin.x, borderBounds.origin.y, borderBounds.size.width, borderBounds.size.height]]) }

        // Update shape if size changed
        if borderBounds.size != currentBounds.size {
            // CRITICAL: Hide window before shape change to prevent compositor race condition.
            // Without this, the Window Server may composite the resized window (with empty
            // backing store) before we can redraw, causing a "white box" flash.
            // NOTE: We don't update isVisible here - caller's show() restores both alpha
            // and state consistency. This is a temporary compositor workaround.
            if isVisible {
                _ = SLSSetWindowAlpha(connectionID, windowID, 0.0)
            }

            // Create CFTypeRef region from CGRect (required by SLSSetWindowShape)
            var bounds = CGRect(origin: .zero, size: borderBounds.size)
            var region: CFTypeRef?
            guard CGSNewRegionWithRect(&bounds, &region) == .success, let shapeRegion = region else {
                // Restore visibility if we were visible before hiding for resize
                if isVisible {
                    _ = SLSSetWindowAlpha(connectionID, windowID, 1.0)
                }
                Task { await EventLog.shared.log("bdr.fail", ["wid": windowID, "reason": "resize_region_failed", "bounds": [borderBounds.origin.x, borderBounds.origin.y, borderBounds.size.width, borderBounds.size.height]]) }
                return
            }
            _ = SLSSetWindowShape(connectionID, windowID, 0, 0, shapeRegion)

            // CRITICAL: Re-apply position after shape change.
            // SLSSetWindowShape can reset the window position, so we must call
            // SLSMoveWindow again to ensure the border is at the correct location.
            var shapeOrigin = borderBounds.origin
            _ = SLSMoveWindow(connectionID, windowID, &shapeOrigin)

            // Mark context as needing recreation after shape change
            context = nil
        }

        currentBounds = borderBounds

        // Re-order to stay below target
        if isVisible {
            _ = SLSOrderWindow(connectionID, windowID, -1, targetWindowID)
        }
    }

    /// Update the border's style and visibility
    /// - Parameters:
    ///   - style: The new style (nil to hide the border)
    ///   - styleType: "active" or "inactive" for logging purposes
    func updateStyle(style: BorderStyle?, styleType: String = "unknown") {
        guard windowID != 0 else { return }

        // Style is being removed - hide the border
        guard let newStyle = style else {
            hide(reason: "style_removed")
            currentStyle = nil
            return
        }

        // Style changed - redraw and show
        guard currentBounds.size.width > 0 && currentBounds.size.height > 0 else {
            Task { await EventLog.shared.log("warn.bdr.bad_bounds", ["bounds": [currentBounds.origin.x, currentBounds.origin.y, currentBounds.size.width, currentBounds.size.height]]) }
            return
        }

        // Create context if needed (after shape change)
        let contextWasNil = (context == nil)
        if context == nil {
            _ = SLSFlushWindowContentRegion(connectionID, windowID, nil)
            context = SLWindowContextCreate(connectionID, windowID, nil)
        }

        // JankyBorders approach: just use the context without dimension validation
        // CGContext.width/height may return 0 for window-backed contexts, but drawing still works
        guard let drawContext = context else {
            Task { await EventLog.shared.log("warn.bdr.no_ctx", ["wid": windowID]) }
            return
        }

        // Draw using currentBounds (not context dimensions)
        let drawBounds = CGRect(origin: .zero, size: currentBounds.size)

        BorderRenderer.draw(in: drawContext, bounds: drawBounds, style: newStyle)

        // Flush to screen
        let flushResult = SLSFlushWindowContentRegion(connectionID, windowID, nil)

        currentStyle = newStyle

        Task {
            await EventLog.shared.log("dbg.bdr.draw", [
                "wid": windowID,
                "targetID": targetWindowID,
                "styleType": styleType,
                "bounds": [currentBounds.origin.x, currentBounds.origin.y, currentBounds.size.width, currentBounds.size.height],
                "contextCreated": contextWasNil,
                "flushResult": flushResult.rawValue
            ])
        }

        // Always ensure border is shown after drawing
        // (alpha may have been set to 0 during size change in update())
        show()
    }

    /// Get dynamic corner radius from target window
    func getTargetCornerRadius(fallback: CGFloat) -> CGFloat {
        var radii = [CGFloat](repeating: 0, count: 4)
        if SLSWindowIteratorGetCornerRadii(targetWindowID, &radii) == .success {
            return radii[0]  // Top-left corner radius
        }
        return fallback
    }

    /// Move the border window to the same space as the target window
    private func moveToTargetSpace() {
        guard windowID != 0 else { return }

        // Always query API directly - avoids deadlock when called from StateManager's queue
        // (StateManager.getState() uses queue.sync which deadlocks if we're already on that queue)
        guard let targetSpace = queryWindowSpace(targetWindowID) else {
            return
        }

        let borderArray = createWindowIDArray([windowID])
        SLSMoveWindowsToManagedSpace(connectionID, borderArray, targetSpace)
    }

    /// Query window's space directly from SkyLight API
    private func queryWindowSpace(_ windowID: UInt32) -> UInt64? {
        let windowArray = createWindowIDArray([windowID])
        guard let spaces = SLSCopySpacesForWindows(connectionID, 0x7, windowArray),
              CFArrayGetCount(spaces) > 0,
              let spacePtr = CFArrayGetValueAtIndex(spaces, 0) else {
            return nil
        }
        let spaceNumber = Unmanaged<CFNumber>.fromOpaque(spacePtr).takeUnretainedValue()
        var spaceID: UInt64 = 0
        CFNumberGetValue(spaceNumber, .sInt64Type, &spaceID)
        return spaceID
    }
}
