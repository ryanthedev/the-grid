//
// BorderWindow.swift
// GridServer
//
// SkyLight overlay window for rendering a single border
//

import Foundation
import CoreGraphics
import Logging

/// A single border overlay window that tracks a target window
class BorderWindow {
    private let logger = Logger(label: "com.grid.BorderWindow")
    private let connectionID: Int32

    /// Our overlay window ID
    private(set) var windowID: UInt32 = 0

    /// Target window we're drawing around
    let targetWindowID: UInt32

    /// Drawing context
    private var context: CGContext?

    /// Current bounds of the border
    private var currentBounds: CGRect = .zero

    /// Current style
    private var currentStyle: BorderStyle?

    /// Whether the border is currently visible
    private(set) var isVisible: Bool = false

    /// Border padding (space between window edge and border)
    var padding: CGFloat = 2.0

    // MARK: - Event Coalescing (20ms debounce for smooth window drags)
    private var updateTimer: DispatchSourceTimer?
    private let coalesceDelay: TimeInterval = 0.02 // 20ms like JankyBorders
    private var pendingFrame: CGRect?
    private var pendingStyle: BorderStyle?

    init(connectionID: Int32, targetWindowID: UInt32) {
        self.connectionID = connectionID
        self.targetWindowID = targetWindowID
    }

    deinit {
        destroy()
    }

    // MARK: - Lifecycle

    /// Create the overlay window
    func create() -> Bool {
        guard windowID == 0 else {
            logger.warning("Border window already created", metadata: ["targetID": "\(targetWindowID)"])
            return true
        }

        // Get target window bounds to size our overlay
        var targetBounds = CGRect.zero
        guard SLSGetWindowBounds(connectionID, targetWindowID, &targetBounds) == .success else {
            logger.error("Failed to get target window bounds", metadata: ["targetID": "\(targetWindowID)"])
            return false
        }

        // Create CFTypeRef region from CGRect (required by SLSNewWindow)
        // Note: Swift manages CF types with ARC, no manual release needed
        var bounds = CGRect(origin: .zero, size: targetBounds.size)
        var region: CFTypeRef?
        guard CGSNewRegionWithRect(&bounds, &region) == .success, let frameRegion = region else {
            logger.error("Failed to create region", metadata: ["targetID": "\(targetWindowID)"])
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
            logger.error("SLSNewWindow failed", metadata: [
                "error": "\(result.rawValue)",
                "targetID": "\(targetWindowID)"
            ])
            return false
        }

        self.windowID = newWindowID

        // Set window tags: floating, no shadow
        var tags: UInt64 = WindowTags.floating | WindowTags.noShadow
        _ = SLSSetWindowTags(connectionID, windowID, &tags, 64)

        // Make window transparent
        _ = SLSSetWindowOpacity(connectionID, windowID, false)
        _ = SLSSetWindowAlpha(connectionID, windowID, 0.0)

        // Set window level below normal windows
        _ = SLSSetWindowLevel(connectionID, windowID, -1)

        // Create drawing context
        context = SLWindowContextCreate(connectionID, windowID, nil)

        if context == nil {
            logger.warning("Failed to create drawing context", metadata: ["windowID": "\(windowID)"])
        }

        logger.debug("Border window created", metadata: [
            "windowID": "\(windowID)",
            "targetID": "\(targetWindowID)"
        ])

        return true
    }

    /// Destroy the overlay window
    func destroy() {
        guard windowID != 0 else { return }

        // Cancel any pending updates
        updateTimer?.cancel()
        updateTimer = nil

        context = nil
        _ = SLSReleaseWindow(connectionID, windowID)

        logger.debug("Border window destroyed", metadata: ["windowID": "\(windowID)"])

        windowID = 0
        isVisible = false
    }

    // MARK: - Visibility

    /// Show the border
    func show() {
        guard windowID != 0 else { return }

        _ = SLSSetWindowAlpha(connectionID, windowID, 1.0)
        _ = SLSOrderWindow(connectionID, windowID, -1, targetWindowID)  // Below target

        isVisible = true
    }

    /// Hide the border
    func hide() {
        guard windowID != 0 else { return }

        _ = SLSSetWindowAlpha(connectionID, windowID, 0.0)
        _ = SLSOrderWindow(connectionID, windowID, 0, 0)  // Remove from ordering

        isVisible = false
    }

    // MARK: - Update

    /// Update border position and size to match target window
    func updatePosition(targetFrame: CGRect, borderWidth: CGFloat) {
        guard windowID != 0 else { return }

        // Calculate border bounds (larger than target by width + padding on each side)
        let expansion = borderWidth + padding
        let borderBounds = targetFrame.insetBy(dx: -expansion, dy: -expansion)

        // Move the window
        var origin = borderBounds.origin
        _ = SLSMoveWindow(connectionID, windowID, &origin)

        // Update shape if size changed
        if borderBounds.size != currentBounds.size {
            var region = CGRect(origin: .zero, size: borderBounds.size)
            _ = SLSSetWindowShape(connectionID, windowID, 0, 0, &region)

            // Recreate context for new size
            context = SLWindowContextCreate(connectionID, windowID, nil)
        }

        currentBounds = borderBounds

        // Re-order to stay below target
        if isVisible {
            _ = SLSOrderWindow(connectionID, windowID, -1, targetWindowID)
        }
    }

    /// Redraw the border with the given style
    func redraw(style: BorderStyle) {
        guard windowID != 0, let context = context else { return }
        guard currentBounds.size.width > 0 && currentBounds.size.height > 0 else { return }

        // Draw into our bounds (0,0 to size)
        let drawBounds = CGRect(origin: .zero, size: currentBounds.size)

        BorderRenderer.draw(in: context, bounds: drawBounds, style: style)

        // Flush to screen
        _ = SLSFlushWindowContentRegion(connectionID, windowID, nil)

        currentStyle = style
    }

    /// Update position and redraw in one call
    func update(targetFrame: CGRect, style: BorderStyle) {
        updatePosition(targetFrame: targetFrame, borderWidth: style.width)
        redraw(style: style)
    }

    // MARK: - Coalesced Updates

    /// Schedule an update with debouncing (use this during window drags)
    func scheduleUpdate(frame: CGRect, style: BorderStyle) {
        pendingFrame = frame
        pendingStyle = style

        updateTimer?.cancel()
        updateTimer = DispatchSource.makeTimerSource(queue: .main)
        updateTimer?.schedule(deadline: .now() + coalesceDelay)
        updateTimer?.setEventHandler { [weak self] in
            guard let self = self,
                  let frame = self.pendingFrame,
                  let style = self.pendingStyle else { return }
            self.update(targetFrame: frame, style: style)
            self.pendingFrame = nil
            self.pendingStyle = nil
        }
        updateTimer?.resume()
    }

    /// Get dynamic corner radius from target window
    func getTargetCornerRadius(fallback: CGFloat) -> CGFloat {
        var radii = [CGFloat](repeating: 0, count: 4)
        if SLSWindowIteratorGetCornerRadii(targetWindowID, &radii) == .success {
            return radii[0]  // Top-left corner radius
        }
        return fallback
    }
}
