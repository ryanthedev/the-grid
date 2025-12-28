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

    /// Cached state for synchronous access in CGEvent callbacks
    ///
    /// CGEvent tap callbacks are synchronous and cannot use async/await.
    /// This cache provides window state for edge hit detection. Call refreshState()
    /// before enabling the event tap to populate.
    ///
    /// Limitation: This cache becomes stale as windows are created/moved/destroyed.
    /// Edge detection may use outdated coordinates until the cache is refreshed.
    /// For resize mode (which is typically short-lived), this staleness is acceptable.
    private var cachedState: WindowManagerState?

    /// Callback for resize events
    var onResize: ((ResizeType, String, ResizeEdge, CGFloat) -> Void)?

    /// Callback for drag start
    var onDragStart: ((ResizeType, String, ResizeEdge) -> Void)?

    /// Callback for drag end
    var onDragEnd: (() -> Void)?

    // MARK: - Initialization

    init() {
        self.edgeDetector = EdgeDetector(threshold: 10.0)
        JSONLogger.shared.log("mouse.init", data: [:])
    }

    /// Refresh cached state from StateManager (call before enabling event tap)
    func refreshState() async {
        cachedState = await StateManager.shared.getState()
    }

    deinit {
        stop()
    }

    // MARK: - Public Methods

    /// Start capturing mouse events
    func start() -> Bool {
        guard eventTap == nil else {
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
            JSONLogger.shared.log("err.mouse.tap_failed", data: [:])
            return false
        }

        eventTap = tap

        // Create run loop source
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)

        guard let source = runLoopSource else {
            JSONLogger.shared.log("err.mouse.runloop_failed", data: [:])
            CFMachPortInvalidate(tap)
            eventTap = nil
            return false
        }

        // Add to main run loop
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)

        // Enable the tap
        CGEvent.tapEnable(tap: tap, enable: true)

        isEnabled = true
        JSONLogger.shared.log("mouse.start", data: [:])

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

        JSONLogger.shared.log("mouse.stop", data: [:])
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
                JSONLogger.shared.log("warn.mouse.tap_disabled", data: [:])
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

        JSONLogger.shared.log("mouse.down", data: ["x": point.x, "y": point.y])

        // Use cached state for edge hit detection (can't use async in event callback)
        guard let state = cachedState else {
            return Unmanaged.passRetained(event)
        }

        if let hit = edgeDetector.detectEdge(point: point, state: state) {
            // Start drag operation
            dragState = DragState(
                startPoint: point,
                resizeType: hit.resizeType,
                targetID: hit.targetID,
                edge: hit.edge
            )

            JSONLogger.shared.log("resize.drag.start", data: [
                "type": hit.resizeType.rawValue,
                "target": hit.targetID,
                "edge": hit.edge.rawValue,
                "x": point.x,
                "y": point.y
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
            JSONLogger.shared.log("mouse.drag", data: [
                "delta": delta,
                "edge": state.edge.rawValue
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

        JSONLogger.shared.log("resize.drag.end", data: [
            "x": point.x,
            "y": point.y
        ])

        // Clear drag state
        dragState = nil

        // Notify callback
        onDragEnd?()

        // Consume the event
        return nil
    }
}
