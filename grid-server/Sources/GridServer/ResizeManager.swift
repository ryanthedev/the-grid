//
// ResizeManager.swift
// GridServer
//
// Manages resize mode - coordinates MouseHandler and executes resize operations.
// Acts as a bridge between mouse events and the grid CLI resize commands.
//

import Foundation

/// Manages resize mode and coordinates resize operations
class ResizeManager {
    // MARK: - Singleton

    static let shared = ResizeManager()

    // MARK: - Properties

    private let mouseHandler: MouseHandler
    private let queue = DispatchQueue(label: "com.grid.ResizeManager", qos: .userInitiated)

    /// Visual overlay for resize mode
    private let overlay: ResizeOverlay

    /// Event broadcaster for notifying clients of resize events
    weak var eventBroadcaster: EventBroadcaster?

    /// Minimum pixels of movement before triggering a resize
    private let resizeThreshold: CGFloat = 5.0

    /// Delta accumulator for smoother resize
    private var accumulatedDeltaX: CGFloat = 0
    private var accumulatedDeltaY: CGFloat = 0

    /// Pixels per resize step (sensitivity)
    private let pixelsPerStep: CGFloat = 20.0

    // MARK: - Initialization

    private init() {
        self.mouseHandler = MouseHandler()
        self.overlay = ResizeOverlay()

        setupCallbacks()
        Task { JSONLogger.shared.log("resize.init", data: [:]) }
    }

    // MARK: - Setup

    private func setupCallbacks() {
        mouseHandler.onDragStart = { [weak self] resizeType, targetID, edge in
            self?.handleDragStart(resizeType: resizeType, targetID: targetID, edge: edge)
        }

        mouseHandler.onResize = { [weak self] resizeType, targetID, edge, delta in
            self?.handleResize(resizeType: resizeType, targetID: targetID, edge: edge, delta: delta)
        }

        mouseHandler.onDragEnd = { [weak self] in
            self?.handleDragEnd()
        }
    }

    // MARK: - Public Interface

    /// Start resize mode
    func start() -> Bool {
        Task { JSONLogger.shared.log("resize.start", data: [:]) }
        return mouseHandler.start()
    }

    /// Stop resize mode
    func stop() {
        Task { JSONLogger.shared.log("resize.stop", data: [:]) }
        mouseHandler.stop()
    }

    /// Check if resize mode is active
    var isActive: Bool {
        return mouseHandler.isActive
    }

    /// Check if currently dragging
    var isDragging: Bool {
        return mouseHandler.isDragging
    }

    /// Get current status
    func getStatus() -> [String: Any] {
        var result: [String: Any] = [
            "active": isActive,
            "dragging": isDragging
        ]

        if let state = mouseHandler.dragState {
            result["dragState"] = [
                "resizeType": state.resizeType.rawValue,
                "targetID": state.targetID,
                "edge": state.edge.rawValue,
                "startPoint": ["x": state.startPoint.x, "y": state.startPoint.y]
            ] as [String: Any]
        }

        return result
    }

    // MARK: - Event Handlers

    private func handleDragStart(resizeType: ResizeType, targetID: String, edge: ResizeEdge) {
        Task { JSONLogger.shared.log("resize.drag.start", data: [
            "type": resizeType.rawValue,
            "target": targetID,
            "edge": edge.rawValue
        ]) }

        // Reset accumulators
        accumulatedDeltaX = 0
        accumulatedDeltaY = 0

        // Show overlay with resize type
        let modeText = resizeType == .cell ? "RESIZE: CELL" : "RESIZE: WINDOW"
        overlay.show(mode: modeText)

        // Broadcast event
        eventBroadcaster?.sendEvent(type: "resize.dragStart", data: [
            "resizeType": resizeType.rawValue,
            "targetID": targetID,
            "edge": edge.rawValue
        ])
    }

    private func handleResize(resizeType: ResizeType, targetID: String, edge: ResizeEdge, delta: CGFloat) {
        // Accumulate delta
        switch edge {
        case .left, .right:
            accumulatedDeltaX += delta
        case .top, .bottom:
            accumulatedDeltaY += delta
        }

        // Check if we've accumulated enough for a resize step
        let currentDelta = (edge == .left || edge == .right) ? accumulatedDeltaX : accumulatedDeltaY

        if abs(currentDelta) >= pixelsPerStep {
            // Calculate number of steps
            let steps = Int(currentDelta / pixelsPerStep)
            let stepDelta = Double(steps) * 0.02  // 2% per step

            // Reset accumulator (keep remainder)
            if edge == .left || edge == .right {
                accumulatedDeltaX = currentDelta.truncatingRemainder(dividingBy: pixelsPerStep)
            } else {
                accumulatedDeltaY = currentDelta.truncatingRemainder(dividingBy: pixelsPerStep)
            }

            // Execute resize
            executeResize(resizeType: resizeType, edge: edge, delta: stepDelta)
        }
    }

    private func handleDragEnd() {
        Task { JSONLogger.shared.log("resize.drag.end", data: [:]) }

        // Reset accumulators
        accumulatedDeltaX = 0
        accumulatedDeltaY = 0

        // Hide overlay
        overlay.hide()

        // Broadcast event
        eventBroadcaster?.sendEvent(type: "resize.dragEnd", data: nil)
    }

    // MARK: - Resize Execution

    private func executeResize(resizeType: ResizeType, edge: ResizeEdge, delta: Double) {
        // Map edge to direction for CLI
        let direction: String
        switch edge {
        case .left: direction = delta > 0 ? "right" : "left"
        case .right: direction = delta > 0 ? "right" : "left"
        case .top: direction = delta > 0 ? "down" : "up"
        case .bottom: direction = delta > 0 ? "down" : "up"
        }

        let absDelta = abs(delta)

        Task { JSONLogger.shared.log("resize.exec", data: [
            "type": resizeType.rawValue,
            "direction": direction,
            "delta": absDelta
        ]) }

        // Execute the grid CLI command
        queue.async { [weak self] in
            self?.runGridResize(type: resizeType, direction: direction, delta: absDelta)
        }

        // Broadcast event
        eventBroadcaster?.sendEvent(type: "resize.step", data: [
            "resizeType": resizeType.rawValue,
            "direction": direction,
            "delta": absDelta
        ])
    }

    /// Run the grid CLI resize command
    private func runGridResize(type: ResizeType, direction: String, delta: Double) {
        // Build command based on resize type
        let resizeType = type == .cell ? "cell" : "split"
        let deltaStr = String(format: "%.2f", delta)

        // Path to grid CLI (assumes it's in PATH or we can find it)
        // Try common locations
        let gridPaths = [
            "/usr/local/bin/grid",
            "\(FileManager.default.homeDirectoryForCurrentUser.path)/.local/bin/grid",
            "\(FileManager.default.homeDirectoryForCurrentUser.path)/repos/theGrid/bin/grid"
        ]

        var gridPath: String?
        for path in gridPaths {
            if FileManager.default.fileExists(atPath: path) {
                gridPath = path
                break
            }
        }

        guard let path = gridPath else {
            Task { JSONLogger.shared.log("warn.resize.cli_not_found", data: [:]) }
            return
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = ["resize", resizeType, direction, deltaStr]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        do {
            try process.run()
            process.waitUntilExit()

            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            if let output = String(data: data, encoding: .utf8), !output.isEmpty {
}

            if process.terminationStatus != 0 {
                Task { JSONLogger.shared.log("warn.resize.exec_failed", data: ["status": process.terminationStatus]) }
            }
        } catch {
            Task { JSONLogger.shared.log("err.resize.exec", data: ["error": error.localizedDescription]) }
        }
    }
}
