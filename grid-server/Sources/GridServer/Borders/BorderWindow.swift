//
// BorderWindow.swift
// GridServer
//
// SkyLight overlay window for rendering a single border
//

import Foundation
import CoreGraphics

/// Animation type for border effects
enum AnimationType: String {
    case none
    case pulse      // Sharp pulse effect
    case breathe    // Smooth breathing effect
    case fade       // Linear fade in/out
}

/// Handles animated border effects (pulse, breathe, fade)
class BorderAnimator {
    private var timer: DispatchSourceTimer?
    private var phase: CGFloat = 0
    private let duration: CGFloat
    private let intensity: CGFloat
    private let type: AnimationType

    init(type: AnimationType, duration: CGFloat = 2.0, intensity: CGFloat = 0.3) {
        self.type = type
        self.duration = max(0.1, duration)  // Prevent division by zero
        self.intensity = min(1.0, max(0.0, intensity))
    }

    func start(onUpdate: @escaping (CGFloat) -> Void) {
        stop()  // Cancel any existing timer

        guard type != .none else { return }

        let queue = DispatchQueue(label: "com.thegrid.border.animator")
        timer = DispatchSource.makeTimerSource(queue: queue)

        // 30 FPS update rate (good balance between smoothness and performance)
        let frameRate: Double = 30.0
        timer?.schedule(deadline: .now(), repeating: 1.0 / frameRate)

        timer?.setEventHandler { [weak self] in
            guard let self = self else { return }

            self.phase += CGFloat(1.0 / frameRate) / self.duration
            if self.phase >= 1.0 {
                self.phase = 0
            }

            let value = self.calculateAnimationValue()
            DispatchQueue.main.async {
                onUpdate(value)
            }
        }

        timer?.resume()
    }

    private func calculateAnimationValue() -> CGFloat {
        let normalized = phase * 2.0 * .pi

        switch type {
        case .none:
            return 1.0
        case .pulse:
            // Sharp pulse effect
            let pulseValue = abs(sin(normalized))
            return 1.0 - (pulseValue * intensity)
        case .breathe:
            // Smooth breathing effect (slower at peaks)
            let breatheValue = (sin(normalized - .pi / 2) + 1.0) / 2.0
            return 1.0 - (breatheValue * intensity)
        case .fade:
            // Linear fade in/out
            let fadeValue = phase < 0.5 ? phase * 2.0 : (1.0 - phase) * 2.0
            return 1.0 - (fadeValue * intensity)
        }
    }

    func stop() {
        timer?.cancel()
        timer = nil
        phase = 0
    }

    deinit {
        stop()
    }
}

/// A single border overlay window that tracks a target window
class BorderWindow {
    private let connectionID: Int32

    /// Our overlay window ID
    private(set) var windowID: UInt32 = 0

    /// Target window we're drawing around (can be changed via retarget)
    private(set) var targetWindowID: UInt32

    /// Drawing context
    private var context: CGContext?

    /// Current bounds of the border
    private var currentBounds: CGRect = .zero

    /// Current style
    private var currentStyle: BorderStyle?

    /// Whether the border is currently visible
    private(set) var isVisible: Bool = false

    /// Track resize state to queue updates instead of dropping them
    private var isResizing: Bool = false

    /// Pending frame to process after resize completes (queue instead of drop)
    private var pendingFrame: CGRect?

    /// Animation controller for effects
    private var animator: BorderAnimator?

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
        // Stop animation before cleanup
        animator?.stop()
        animator = nil

        // Capture values BEFORE any operations to avoid capturing self during deallocation
        let wid = windowID
        let targetID = targetWindowID
        destroy()
        // Use captured values (not self.properties) to avoid Swift runtime abort
        JSONLogger.shared.log("bdr.destroy", data: ["wid": wid, "targetID": targetID])
    }

    // MARK: - Lifecycle

    /// Create the overlay window
    func create() -> Bool {
        guard windowID == 0 else {
            JSONLogger.shared.log("warn.bdr.exists", data: ["targetID": targetWindowID])
            return true
        }

        // Get target window bounds to size our overlay
        var targetBounds = CGRect.zero
        guard SLSGetWindowBounds(connectionID, targetWindowID, &targetBounds) == .success else {
            JSONLogger.shared.log("bdr.fail", data: ["targetID": targetWindowID, "reason": "no_bounds"])
            return false
        }

        // Create CFTypeRef region from CGRect (required by SLSNewWindow)
        var bounds = CGRect(origin: .zero, size: targetBounds.size)
        var region: CFTypeRef?
        guard CGSNewRegionWithRect(&bounds, &region) == .success, let frameRegion = region else {
            JSONLogger.shared.log("bdr.fail", data: ["targetID": targetWindowID, "reason": "region_failed"])
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
            JSONLogger.shared.log("bdr.fail", data: ["targetID": targetWindowID, "error": result.rawValue, "reason": "window_create_failed"])
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
                JSONLogger.shared.log("warn.bdr.setup", data: [
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
            JSONLogger.shared.log("bdr.fail", data: ["wid": windowID, "reason": "no_context"])
            // Clean up the window we just created
            _ = SLSReleaseWindow(connectionID, windowID)
            self.windowID = 0
            return false
        }

        // Move border to same space as target window
        moveToTargetSpace()

        JSONLogger.shared.log("bdr.create", data: ["wid": windowID, "targetID": targetWindowID])
        return true
    }

    /// Destroy the overlay window
    func destroy() {
        guard windowID != 0 else { return }

        // Stop any animation
        animator?.stop()
        animator = nil

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

        _ = SLSSetWindowAlpha(connectionID, windowID, 1.0)
        _ = SLSOrderWindow(connectionID, windowID, -1, targetWindowID)  // Below target

        isVisible = true
    }

    /// Hide the border
    /// - Parameter reason: Optional reason for hiding (for logging)
    func hide(reason: String = "unspecified") {
        guard windowID != 0 else { return }
        guard isVisible else { return }

        _ = SLSSetWindowAlpha(connectionID, windowID, 0.0)
        _ = SLSOrderWindow(connectionID, windowID, 0, 0)  // Remove from ordering

        isVisible = false

        JSONLogger.shared.log("bdr.hide", data: ["wid": windowID, "targetID": targetWindowID, "reason": reason])
    }

    // MARK: - Update

    /// Update border position and size to match target window
    /// - Parameters:
    ///   - targetFrame: The target window's frame
    ///   - style: Optional style to use for expansion calculation. If nil, uses currentStyle or activeStyle fallback.
    func update(targetFrame: CGRect, style: BorderStyle? = nil) {
        guard windowID != 0 else { return }

        // If we're in the middle of a resize, queue this frame instead of processing it.
        // This prevents dropping updates while ensuring we don't interleave resize operations.
        if isResizing {
            pendingFrame = targetFrame
            return
        }

        performUpdate(targetFrame, explicitStyle: style)
    }

    /// Internal update implementation - processes a single frame update
    /// - Parameters:
    ///   - targetFrame: The target window's frame
    ///   - explicitStyle: Optional style passed from caller; takes priority over currentStyle
    private func performUpdate(_ targetFrame: CGRect, explicitStyle: BorderStyle? = nil) {
        // Calculate border bounds (larger than target by width + padding + effects on each side)
        // Priority: explicit style from caller > currentStyle > activeStyle fallback
        let style = explicitStyle ?? currentStyle ?? BorderConfigManager.shared.activeStyle
        let borderWidth = style.width

        // Calculate glow expansion: blur radius determines how far glow extends from stroke edge
        var glowExpansion: CGFloat = 0
        if let glowRadius = style.glowRadius, glowRadius > 0 {
            let spread = style.glowSpread ?? 1.0
            glowExpansion = glowRadius * spread
        }

        // Calculate shadow expansion: radius + offset
        var shadowExpansion: CGFloat = 0
        if let shadowRadius = style.shadowRadius, shadowRadius > 0 {
            let offset = style.shadowOffset ?? CGSize(width: 2, height: 4)
            shadowExpansion = shadowRadius + max(abs(offset.width), abs(offset.height))
        }

        // Border stroke is centered on its path, extending width/2 on each side
        // To keep the entire stroke OUTSIDE the window, we need to expand by the full width
        // (not half) so the inner edge of the stroke aligns with the window edge
        let effectsExpansion = max(glowExpansion, shadowExpansion)
        let expansion = borderWidth + effectsExpansion
        let borderBounds = targetFrame.insetBy(dx: -expansion, dy: -expansion)

        // Move the window
        var origin = borderBounds.origin
        _ = SLSMoveWindow(connectionID, windowID, &origin)

        JSONLogger.shared.log("bdr.move", data: ["wid": windowID, "targetID": targetWindowID, "frame": [borderBounds.origin.x, borderBounds.origin.y, borderBounds.size.width, borderBounds.size.height]])

        // Update shape if size changed
        let needsResize = borderBounds.size != currentBounds.size
        let wasVisible = isVisible

        if needsResize {
            // Mark resize in progress - any update() calls during resize will be queued
            isResizing = true

            // CRITICAL: Hide window before shape change to prevent compositor race condition.
            // Without this, the Window Server may composite the resized window (with empty
            // backing store) before we can redraw, causing a "white box" flash.
            if wasVisible {
                _ = SLSSetWindowAlpha(connectionID, windowID, 0.0)
            }

            // Create CFTypeRef region from CGRect (required by SLSSetWindowShape)
            var bounds = CGRect(origin: .zero, size: borderBounds.size)
            var region: CFTypeRef?
            guard CGSNewRegionWithRect(&bounds, &region) == .success, let shapeRegion = region else {
                // Restore visibility if we were visible before hiding for resize
                if wasVisible {
                    _ = SLSSetWindowAlpha(connectionID, windowID, 1.0)
                }
                isResizing = false
                processPendingFrame()
                JSONLogger.shared.log("bdr.fail", data: ["wid": windowID, "reason": "resize_region_failed", "bounds": [borderBounds.origin.x, borderBounds.origin.y, borderBounds.size.width, borderBounds.size.height]])
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

            // Update bounds before redraw so we use the new size
            currentBounds = borderBounds

            // If we were visible and have a style, redraw immediately to restore visibility.
            // This handles the case where update() is called without a subsequent updateStyle().
            if wasVisible, let style = currentStyle,
               currentBounds.size.width > 0 && currentBounds.size.height > 0 {
                // Recreate context after shape change
                _ = SLSFlushWindowContentRegion(connectionID, windowID, nil)
                context = SLWindowContextCreate(connectionID, windowID, nil)

                if let drawContext = context {
                    let drawBounds = CGRect(origin: .zero, size: currentBounds.size)
                    BorderRenderer.draw(in: drawContext, bounds: drawBounds, style: style)
                    _ = SLSFlushWindowContentRegion(connectionID, windowID, nil)

                    // Restore visibility
                    show()
                }
                // Note: If context creation fails, border stays hidden until next update
            }

            // Resize complete - process any queued frame
            isResizing = false
            processPendingFrame()
        } else {
            // No resize - just update bounds for position change
            currentBounds = borderBounds
        }

        // Re-order to stay below target
        if isVisible {
            _ = SLSOrderWindow(connectionID, windowID, -1, targetWindowID)
        }
    }

    /// Process any frame that was queued during resize
    private func processPendingFrame() {
        guard let frame = pendingFrame else { return }
        pendingFrame = nil
        performUpdate(frame)
    }

    /// Re-target this border to track a different window
    /// Used for tabbed cells where we keep one border and switch targets on focus change
    func retarget(to newTargetID: UInt32) {
        // Capture windowID upfront to avoid race with concurrent destroy()
        let currentWindowID = windowID
        guard currentWindowID != 0 else { return }
        guard newTargetID != targetWindowID else { return }

        let oldTarget = targetWindowID
        targetWindowID = newTargetID

        // Get new target's frame and update position
        var frame = CGRect.zero
        guard SLSGetWindowBounds(connectionID, newTargetID, &frame) == .success else {
            Task {
                JSONLogger.shared.log("err.bdr.retarget", data: [
                    "wid": currentWindowID,
                    "oldTarget": oldTarget,
                    "newTarget": newTargetID,
                    "reason": "no_bounds"
                ])
            }
            return
        }

        // Update position to new target
        update(targetFrame: frame)

        // Move to new target's space if needed
        moveToTargetSpace()

        // Re-order below new target
        if isVisible {
            _ = SLSOrderWindow(connectionID, currentWindowID, -1, newTargetID)
        }

        Task {
            JSONLogger.shared.log("bdr.retarget", data: [
                "wid": currentWindowID,
                "oldTarget": oldTarget,
                "newTarget": newTargetID
            ])
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
            JSONLogger.shared.log("warn.bdr.bad_bounds", data: ["bounds": [currentBounds.origin.x, currentBounds.origin.y, currentBounds.size.width, currentBounds.size.height]])
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
            JSONLogger.shared.log("warn.bdr.no_ctx", data: ["wid": windowID])
            return
        }

        // Draw using currentBounds (not context dimensions)
        let drawBounds = CGRect(origin: .zero, size: currentBounds.size)

        BorderRenderer.draw(in: drawContext, bounds: drawBounds, style: newStyle)

        // Flush to screen
        _ = SLSFlushWindowContentRegion(connectionID, windowID, nil)

        currentStyle = newStyle

        // Always ensure border is shown after drawing
        // (alpha may have been set to 0 during size change in update())
        show()

        // Note: Native window shadows (SLSSetWindowShadowParameters) don't work well
        // for overlay windows - shadows are now drawn manually in BorderRenderer
    }

    /// Get dynamic corner radius from target window
    func getTargetCornerRadius(fallback: CGFloat) -> CGFloat {
        var radii = [CGFloat](repeating: 0, count: 4)
        if SLSWindowIteratorGetCornerRadii(targetWindowID, &radii) == .success {
            return radii[0]  // Top-left corner radius
        }
        return fallback
    }

    /// Configure animation for the border
    /// - Parameters:
    ///   - type: Animation type (none, pulse, breathe, fade)
    ///   - duration: Full animation cycle duration in seconds
    ///   - intensity: Animation intensity (0.0-1.0)
    func configureAnimation(type: String?, duration: CGFloat?, intensity: CGFloat?) {
        // Stop existing animation
        animator?.stop()
        animator = nil

        guard let typeStr = type,
              let animType = AnimationType(rawValue: typeStr),
              animType != .none else {
            // Reset alpha to full if no animation
            if windowID != 0 {
                _ = SLSSetWindowAlpha(connectionID, windowID, 1.0)
            }
            return
        }

        let animDuration = duration ?? 2.0
        let animIntensity = intensity ?? 0.3

        animator = BorderAnimator(type: animType, duration: animDuration, intensity: animIntensity)

        animator?.start { [weak self] value in
            guard let self = self, self.windowID != 0, self.isVisible else { return }
            _ = SLSSetWindowAlpha(self.connectionID, self.windowID, Float(value))
        }

        Task {
            JSONLogger.shared.log("bdr.anim", data: [
                "wid": windowID,
                "type": typeStr,
                "duration": animDuration,
                "intensity": animIntensity
            ])
        }
    }

    /// Stop any running animation
    func stopAnimation() {
        animator?.stop()
        animator = nil
        // Reset alpha to full
        if windowID != 0 {
            _ = SLSSetWindowAlpha(connectionID, windowID, isVisible ? 1.0 : 0.0)
        }
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
