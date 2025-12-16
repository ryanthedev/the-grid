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
    private(set) var targetWindowID: UInt32

    /// Drawing context
    private var context: CGContext?

    /// Current bounds of the border
    private var currentBounds: CGRect = .zero

    /// Current style
    private var currentStyle: BorderStyle?

    /// Whether the border is currently visible
    private(set) var isVisible: Bool = false

    /// Border padding (space between window edge and border)
    /// Uses dynamic value from config
    var padding: CGFloat {
        BorderConfigManager.shared.padding
    }

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
            logger.warning("Failed to create initial drawing context", metadata: ["windowID": "\(windowID)"])
        }

        logger.debug("Border window created", metadata: [
            "windowID": "\(windowID)",
            "targetID": "\(targetWindowID)",
            "initialSize": "(\(targetBounds.size.width), \(targetBounds.size.height))"
        ])

        return true
    }

    /// Destroy the overlay window
    func destroy() {
        guard windowID != 0 else { return }

        // Cancel any pending updates
        updateTimer?.cancel()
        updateTimer = nil

        // CRITICAL: Hide window before releasing (removes from screen)
        hide()

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
        let orderResult = SLSOrderWindow(connectionID, windowID, -1, targetWindowID)  // Below target

        isVisible = true

        logger.debug("Border shown", metadata: [
            "windowID": "\(windowID)",
            "targetID": "\(targetWindowID)",
            "currentBounds": "(\(currentBounds.origin.x), \(currentBounds.origin.y), \(currentBounds.size.width), \(currentBounds.size.height))",
            "orderResult": "\(orderResult.rawValue)"
        ])
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

        logger.debug("Border position update", metadata: [
            "targetFrame": "(\(targetFrame.origin.x), \(targetFrame.origin.y), \(targetFrame.size.width), \(targetFrame.size.height))",
            "borderBounds": "(\(borderBounds.origin.x), \(borderBounds.origin.y), \(borderBounds.size.width), \(borderBounds.size.height))",
            "expansion": "\(expansion)"
        ])

        // Move the window
        var origin = borderBounds.origin
        _ = SLSMoveWindow(connectionID, windowID, &origin)

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
                logger.warning("Failed to create region for border resize", metadata: ["bounds": "\(borderBounds)"])
                return
            }
            _ = SLSSetWindowShape(connectionID, windowID, -9999, -9999, shapeRegion)

            // Mark context as needing recreation after shape change
            context = nil
        }

        currentBounds = borderBounds

        // Re-order to stay below target
        if isVisible {
            _ = SLSOrderWindow(connectionID, windowID, -1, targetWindowID)
        }
    }

    /// Redraw the border with the given style
    func redraw(style: BorderStyle) {
        guard windowID != 0 else {
            logger.warning("Border redraw skipped - no windowID")
            return
        }
        guard currentBounds.size.width > 0 && currentBounds.size.height > 0 else {
            logger.warning("Border redraw skipped - invalid bounds", metadata: ["bounds": "\(currentBounds)"])
            return
        }

        // Create context if needed (after shape change)
        if context == nil {
            _ = SLSFlushWindowContentRegion(connectionID, windowID, nil)
            context = SLWindowContextCreate(connectionID, windowID, nil)
        }

        // JankyBorders approach: just use the context without dimension validation
        // CGContext.width/height may return 0 for window-backed contexts, but drawing still works
        guard let drawContext = context else {
            logger.warning("No context available for drawing", metadata: ["windowID": "\(windowID)"])
            return
        }

        // Draw using currentBounds (not context dimensions)
        let drawBounds = CGRect(origin: .zero, size: currentBounds.size)

        logger.debug("Border redraw", metadata: [
            "windowID": "\(windowID)",
            "drawBounds": "(\(drawBounds.width), \(drawBounds.height))",
            "borderWidth": "\(style.width)",
            "cornerRadius": "\(style.cornerRadius)"
        ])

        BorderRenderer.draw(in: drawContext, bounds: drawBounds, style: style)

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

    // MARK: - Retargeting

    /// Retarget this border window to a different target window
    /// This allows reusing the same border overlay instead of destroying/recreating
    func retarget(to newTargetID: UInt32) {
        let oldTargetID = targetWindowID
        targetWindowID = newTargetID

        // Force context recreation for new target
        context = nil

        logger.info("Border retargeted", metadata: [
            "windowID": "\(windowID)",
            "oldTarget": "\(oldTargetID)",
            "newTarget": "\(newTargetID)"
        ])
    }
}
