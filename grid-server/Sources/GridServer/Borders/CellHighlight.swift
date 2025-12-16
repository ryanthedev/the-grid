//
// CellHighlight.swift
// GridServer
//
// SkyLight overlay window for highlighting the active cell grid area
//

import Foundation
import CoreGraphics
import Logging

/// A single highlight overlay window that fills a cell grid area
class CellHighlight {
    private let logger = Logger(label: "com.grid.CellHighlight")
    private let connectionID: Int32

    /// Our overlay window ID
    private(set) var windowID: UInt32 = 0

    /// Drawing context
    private var context: CGContext?

    /// Current bounds of the highlight
    private var currentBounds: CGRect = .zero

    /// Whether the highlight is currently visible
    private(set) var isVisible: Bool = false

    /// Fill color (white with slight transparency)
    var fillColor: CGColor = SimpleBorderConfig.highlightFillColor

    /// Stroke color (blue)
    var strokeColor: CGColor = SimpleBorderConfig.highlightStrokeColor

    /// Stroke width (thin border)
    var strokeWidth: CGFloat = SimpleBorderConfig.highlightStrokeWidth

    // MARK: - Event Coalescing (20ms debounce for smooth updates)
    private var updateTimer: DispatchSourceTimer?
    private let coalesceDelay: TimeInterval = 0.02 // 20ms like JankyBorders
    private var pendingFrame: CGRect?

    init(connectionID: Int32) {
        self.connectionID = connectionID
    }

    deinit {
        destroy()
    }

    // MARK: - Lifecycle

    /// Create the overlay window
    func create() -> Bool {
        guard windowID == 0 else {
            logger.warning("Cell highlight window already created")
            return true
        }

        // Start with a small initial size (will be updated when frame is set)
        let initialSize = CGSize(width: 100, height: 100)

        // Create CFTypeRef region from CGRect (required by SLSNewWindow)
        var bounds = CGRect(origin: .zero, size: initialSize)
        var region: CFTypeRef?
        guard CGSNewRegionWithRect(&bounds, &region) == .success, let frameRegion = region else {
            logger.error("Failed to create region for cell highlight")
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
            logger.error("SLSNewWindow failed for cell highlight", metadata: [
                "error": "\(result.rawValue)"
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

        // Set window level VERY LOW (behind normal windows)
        // Normal windows are at level 0, we want to be behind them
        _ = SLSSetWindowLevel(connectionID, windowID, -10)

        // Create drawing context
        context = SLWindowContextCreate(connectionID, windowID, nil)

        if context == nil {
            logger.warning("Failed to create drawing context for cell highlight", metadata: ["windowID": "\(windowID)"])
        }

        logger.debug("Cell highlight window created", metadata: ["windowID": "\(windowID)"])

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

        logger.debug("Cell highlight window destroyed", metadata: ["windowID": "\(windowID)"])

        windowID = 0
        isVisible = false
    }

    // MARK: - Visibility

    /// Show the highlight
    func show() {
        guard windowID != 0 else { return }

        _ = SLSSetWindowAlpha(connectionID, windowID, 1.0)
        _ = SLSOrderWindow(connectionID, windowID, 1, 0)  // Order above background

        isVisible = true

        logger.debug("Cell highlight shown", metadata: ["bounds": "\(currentBounds)"])
    }

    /// Hide the highlight
    func hide() {
        guard windowID != 0 else { return }

        _ = SLSSetWindowAlpha(connectionID, windowID, 0.0)
        _ = SLSOrderWindow(connectionID, windowID, 0, 0)  // Remove from ordering

        isVisible = false

        logger.debug("Cell highlight hidden")
    }

    // MARK: - Update

    /// Update highlight position and size
    func update(frame: CGRect) {
        guard windowID != 0 else { return }
        guard frame.size.width > 0 && frame.size.height > 0 else {
            logger.warning("Ignoring invalid frame for cell highlight", metadata: ["frame": "\(frame)"])
            return
        }

        // Move the window
        var origin = frame.origin
        _ = SLSMoveWindow(connectionID, windowID, &origin)

        // Update shape if size changed
        if frame.size != currentBounds.size {
            // Create CFTypeRef region from CGRect (required by SLSSetWindowShape)
            var bounds = CGRect(origin: .zero, size: frame.size)
            var region: CFTypeRef?
            guard CGSNewRegionWithRect(&bounds, &region) == .success, let shapeRegion = region else {
                logger.warning("Failed to create region for cell highlight resize", metadata: ["frame": "\(frame)"])
                return
            }
            let shapeResult = SLSSetWindowShape(connectionID, windowID, 0, 0, shapeRegion)

            // CRITICAL: Re-apply position after shape change.
            // SLSSetWindowShape can reset the window position on multi-monitor setups,
            // so we must call SLSMoveWindow again to ensure correct location.
            var shapeOrigin = frame.origin
            _ = SLSMoveWindow(connectionID, windowID, &shapeOrigin)

            logger.debug("Cell highlight shape updated", metadata: [
                "windowID": "\(windowID)",
                "oldSize": "(\(currentBounds.size.width), \(currentBounds.size.height))",
                "newSize": "(\(frame.size.width), \(frame.size.height))",
                "result": "\(shapeResult.rawValue)"
            ])

            // Recreate context for new size
            context = SLWindowContextCreate(connectionID, windowID, nil)
            if context == nil {
                logger.warning("Failed to create context after cell highlight resize", metadata: ["windowID": "\(windowID)"])
            }
        }

        currentBounds = frame

        // Redraw with new bounds
        render()

        logger.debug("Cell highlight updated", metadata: [
            "frame": "(\(frame.origin.x), \(frame.origin.y), \(frame.size.width), \(frame.size.height))"
        ])
    }

    /// Redraw the highlight
    private func render() {
        guard windowID != 0, let context = context else { return }
        guard currentBounds.size.width > 0 && currentBounds.size.height > 0 else { return }

        // Draw into our bounds (0,0 to size)
        let drawBounds = CGRect(origin: .zero, size: currentBounds.size)

        // Clear the context first
        context.clear(drawBounds)

        // Fill with background color
        context.setFillColor(fillColor)
        context.fill(drawBounds)

        // Draw stroke border
        let strokeInset = strokeWidth / 2
        let strokeRect = drawBounds.insetBy(dx: strokeInset, dy: strokeInset)

        context.setStrokeColor(strokeColor)
        context.setLineWidth(strokeWidth)
        context.setLineCap(.round)
        context.setLineJoin(.round)

        // Draw rectangle path
        context.addRect(strokeRect)
        context.strokePath()

        // Flush to screen
        _ = SLSFlushWindowContentRegion(connectionID, windowID, nil)
    }

    // MARK: - Coalesced Updates

    /// Schedule an update with debouncing (use this during smooth animations)
    func scheduleUpdate(frame: CGRect) {
        guard frame.size.width > 0 && frame.size.height > 0 else {
            logger.warning("Ignoring invalid frame for scheduled update", metadata: ["frame": "\(frame)"])
            return
        }
        pendingFrame = frame

        updateTimer?.cancel()
        updateTimer = DispatchSource.makeTimerSource(queue: .main)
        updateTimer?.schedule(deadline: .now() + coalesceDelay)
        updateTimer?.setEventHandler { [weak self] in
            guard let self = self, let frame = self.pendingFrame else { return }
            self.update(frame: frame)
            self.pendingFrame = nil
        }
        updateTimer?.resume()
    }
}
