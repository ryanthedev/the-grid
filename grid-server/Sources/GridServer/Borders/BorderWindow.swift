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

    // MARK: - Context Retry (handles Window Server timing race)
    private var contextRetryCount = 0
    private let maxContextRetries = 3
    private var pendingRedrawStyle: BorderStyle?

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

        if let ctx = context {
            logger.info("Initial context created", metadata: [
                "windowID": "\(windowID)",
                "contextWidth": "\(ctx.width)",
                "contextHeight": "\(ctx.height)",
                "expectedSize": "(\(targetBounds.size.width), \(targetBounds.size.height))"
            ])
        } else {
            logger.warning("Failed to create drawing context", metadata: ["windowID": "\(windowID)"])
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

        // Clear retry state
        contextRetryCount = 0
        pendingRedrawStyle = nil

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
            // Create CFTypeRef region from CGRect (required by SLSSetWindowShape)
            var bounds = CGRect(origin: .zero, size: borderBounds.size)
            var region: CFTypeRef?
            guard CGSNewRegionWithRect(&bounds, &region) == .success, let shapeRegion = region else {
                logger.warning("Failed to create region for border resize", metadata: ["bounds": "\(borderBounds)"])
                return
            }
            let shapeResult = SLSSetWindowShape(connectionID, windowID, -9999, -9999, shapeRegion)
            logger.debug("Border shape updated", metadata: [
                "windowID": "\(windowID)",
                "oldSize": "(\(currentBounds.size.width), \(currentBounds.size.height))",
                "newSize": "(\(borderBounds.size.width), \(borderBounds.size.height))",
                "result": "\(shapeResult.rawValue)"
            ])

            // Mark context as needing recreation - DON'T create here (race with Window Server)
            // Context will be recreated lazily in redraw() with retry support
            context = nil
            contextRetryCount = 0
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

        // Store style for potential retries
        pendingRedrawStyle = style

        // Attempt to get or create context
        if context == nil {
            context = SLWindowContextCreate(connectionID, windowID, nil)
        }

        // Validate context dimensions
        guard let drawContext = context, drawContext.width > 0 && drawContext.height > 0 else {
            // Context invalid - Window Server may not have processed shape change yet
            logger.debug("Context has zero dimensions, scheduling retry", metadata: [
                "windowID": "\(windowID)",
                "expectedBounds": "(\(currentBounds.size.width), \(currentBounds.size.height))",
                "retryCount": "\(contextRetryCount)"
            ])
            scheduleContextRetry()
            return
        }

        // Valid context - reset retry state and proceed with drawing
        contextRetryCount = 0
        pendingRedrawStyle = nil

        // Draw into our bounds (0,0 to size)
        let drawBounds = CGRect(origin: .zero, size: currentBounds.size)

        logger.debug("Border redraw", metadata: [
            "windowID": "\(windowID)",
            "drawBounds": "(\(drawBounds.width), \(drawBounds.height))",
            "contextSize": "(\(drawContext.width), \(drawContext.height))",
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

    /// Schedule a retry for context creation after Window Server processes shape change
    private func scheduleContextRetry() {
        guard contextRetryCount < maxContextRetries else {
            logger.error("Context creation failed after \(maxContextRetries) retries", metadata: [
                "windowID": "\(windowID)",
                "expectedBounds": "(\(currentBounds.size.width), \(currentBounds.size.height))"
            ])
            contextRetryCount = 0
            pendingRedrawStyle = nil
            return
        }

        contextRetryCount += 1
        // Exponential backoff: 8ms, 16ms, 32ms
        let delay = 0.008 * Double(1 << (contextRetryCount - 1))

        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self = self, let style = self.pendingRedrawStyle else { return }
            // Clear context to force recreation attempt
            self.context = nil
            self.redraw(style: style)
        }
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

        // Cancel any pending retry state from old target
        contextRetryCount = 0
        pendingRedrawStyle = nil
        context = nil  // Force context recreation for new target

        logger.info("Border retargeted", metadata: [
            "windowID": "\(windowID)",
            "oldTarget": "\(oldTargetID)",
            "newTarget": "\(newTargetID)"
        ])
    }
}
