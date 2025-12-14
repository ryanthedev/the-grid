//
// MouseHandler.swift
// GridServer
//
// CGEventTap-based mouse handling for resize mode.
// Captures mouse down/drag/up events near cell/window boundaries.
//

import Foundation
import CoreGraphics
import AppKit
import Logging

/// Resize target type
enum ResizeType: String, Codable {
    case cell
    case window
}

/// Edge being resized
enum ResizeEdge: String, Codable {
    case left
    case right
    case top
    case bottom
}

/// State tracked during a drag operation
struct DragState {
    let startPoint: CGPoint
    let resizeType: ResizeType
    let targetID: String      // cell ID or window ID
    let edge: ResizeEdge
    var lastPoint: CGPoint

    init(startPoint: CGPoint, resizeType: ResizeType, targetID: String, edge: ResizeEdge) {
        self.startPoint = startPoint
        self.resizeType = resizeType
        self.targetID = targetID
        self.edge = edge
        self.lastPoint = startPoint
    }
}

/// Handles mouse events for resize mode using CGEventTap
class MouseHandler {
    // MARK: - Properties

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var isEnabled: Bool = false

    /// Current drag state (nil when not dragging)
    private(set) var dragState: DragState?

    /// Edge detector for hit testing
    private let edgeDetector: EdgeDetector

    /// Logger
    private let logger: Logger

    /// Callback for resize events
    var onResize: ((ResizeType, String, ResizeEdge, CGFloat) -> Void)?

    /// Callback for drag start
    var onDragStart: ((ResizeType, String, ResizeEdge) -> Void)?

    /// Callback for drag end
    var onDragEnd: (() -> Void)?

    // MARK: - Initialization

    init(logger: Logger) {
        self.logger = logger
        self.edgeDetector = EdgeDetector(threshold: 10.0, logger: logger)
        logger.info("MouseHandler initialized")
    }

    deinit {
        stop()
    }

    // MARK: - Public Methods

    /// Start capturing mouse events
    func start() -> Bool {
        guard eventTap == nil else {
            logger.debug("MouseHandler already started")
            return true
        }

        // Event mask: left mouse down, up, and dragged
        let eventMask: CGEventMask = (1 << CGEventType.leftMouseDown.rawValue) |
                                     (1 << CGEventType.leftMouseUp.rawValue) |
                                     (1 << CGEventType.leftMouseDragged.rawValue)

        // Create event tap
        // We use kCGHIDEventTap to get events before they're processed
        // kCGEventTapOptionDefault allows us to modify/consume events
        guard let tap = CGEvent.tapCreate(
            tap: .cghidEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: eventMask,
            callback: { (proxy, type, event, refcon) -> Unmanaged<CGEvent>? in
                guard let refcon = refcon else { return Unmanaged.passRetained(event) }
                let handler = Unmanaged<MouseHandler>.fromOpaque(refcon).takeUnretainedValue()
                return handler.handleEvent(proxy: proxy, type: type, event: event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            logger.error("Failed to create CGEventTap - check Accessibility permissions")
            return false
        }

        eventTap = tap

        // Create run loop source
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)

        guard let source = runLoopSource else {
            logger.error("Failed to create run loop source")
            CFMachPortInvalidate(tap)
            eventTap = nil
            return false
        }

        // Add to main run loop
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)

        // Enable the tap
        CGEvent.tapEnable(tap: tap, enable: true)

        isEnabled = true
        logger.notice("MouseHandler started - listening for resize events")

        return true
    }

    /// Stop capturing mouse events
    func stop() {
        guard let tap = eventTap else { return }

        // Disable the tap
        CGEvent.tapEnable(tap: tap, enable: false)

        // Remove from run loop
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
            runLoopSource = nil
        }

        // Invalidate and release
        CFMachPortInvalidate(tap)
        eventTap = nil

        isEnabled = false
        dragState = nil

        logger.notice("MouseHandler stopped")
    }

    /// Check if mouse handling is active
    var isActive: Bool {
        return isEnabled && eventTap != nil
    }

    /// Check if currently dragging
    var isDragging: Bool {
        return dragState != nil
    }

    // MARK: - Event Handling

    private func handleEvent(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            // Re-enable if disabled
            if let tap = eventTap {
                logger.warning("Event tap was disabled, re-enabling")
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            return Unmanaged.passRetained(event)

        case .leftMouseDown:
            return handleMouseDown(event: event)

        case .leftMouseUp:
            return handleMouseUp(event: event)

        case .leftMouseDragged:
            return handleMouseDragged(event: event)

        default:
            return Unmanaged.passRetained(event)
        }
    }

    private func handleMouseDown(event: CGEvent) -> Unmanaged<CGEvent>? {
        let point = event.location

        logger.debug("Mouse down at (\(point.x), \(point.y))")

        // Get current state and check for edge hit
        let state = StateManager.shared.getState()

        if let hit = edgeDetector.detectEdge(point: point, state: state) {
            // Start drag operation
            dragState = DragState(
                startPoint: point,
                resizeType: hit.resizeType,
                targetID: hit.targetID,
                edge: hit.edge
            )

            logger.info("Resize drag started", metadata: [
                "type": "\(hit.resizeType)",
                "targetID": "\(hit.targetID)",
                "edge": "\(hit.edge)",
                "point": "(\(point.x), \(point.y))"
            ])

            // Notify callback
            onDragStart?(hit.resizeType, hit.targetID, hit.edge)

            // Consume the event (don't pass to other apps)
            return nil
        }

        // No edge hit, pass event through
        return Unmanaged.passRetained(event)
    }

    private func handleMouseDragged(event: CGEvent) -> Unmanaged<CGEvent>? {
        guard var state = dragState else {
            // Not in a resize drag
            return Unmanaged.passRetained(event)
        }

        let point = event.location

        // Calculate delta from last point
        let deltaX = point.x - state.lastPoint.x
        let deltaY = point.y - state.lastPoint.y

        // Determine which delta to use based on edge direction
        let delta: CGFloat
        switch state.edge {
        case .left, .right:
            delta = deltaX
        case .top, .bottom:
            delta = deltaY
        }

        // Only trigger resize if delta is significant
        if abs(delta) > 1.0 {
            logger.debug("Resize drag", metadata: [
                "delta": "\(delta)",
                "edge": "\(state.edge)"
            ])

            // Notify callback
            onResize?(state.resizeType, state.targetID, state.edge, delta)

            // Update last point
            state.lastPoint = point
            dragState = state
        }

        // Consume the event
        return nil
    }

    private func handleMouseUp(event: CGEvent) -> Unmanaged<CGEvent>? {
        guard dragState != nil else {
            // Not in a resize drag
            return Unmanaged.passRetained(event)
        }

        let point = event.location

        logger.info("Resize drag ended", metadata: [
            "point": "(\(point.x), \(point.y))"
        ])

        // Clear drag state
        dragState = nil

        // Notify callback
        onDragEnd?()

        // Consume the event
        return nil
    }
}
