import Foundation
import Logging

/// Handles incoming requests and routes them to appropriate handlers
class MessageHandler {
    typealias RequestHandler = (Request, @escaping (Response) -> Void) -> Void

    private var handlers: [String: RequestHandler] = [:]
    private let logger: Logger

    init(logger: Logger) {
        self.logger = logger
        registerBuiltInHandlers()
    }

    /// Register a handler for a specific method
    func register(method: String, handler: @escaping RequestHandler) {
        handlers[method] = handler
        logger.debug("Registered handler", metadata: ["method": "\(method)"])
    }

    /// Handle a request and call completion with the response
    func handle(request: Request, completion: @escaping (Response) -> Void) {
        logger.info("Handling request", metadata: ["id": "\(request.id)", "method": "\(request.method)"])

        guard let handler = handlers[request.method] else {
            let response = Response(
                id: request.id,
                error: ErrorInfo(
                    code: -32601,
                    message: "Method not found: \(request.method)"
                )
            )
            completion(response)
            return
        }

        // Execute handler
        handler(request) { response in
            completion(response)
        }
    }

    /// Register built-in handlers for demonstration
    private func registerBuiltInHandlers() {
        // Ping handler - simple echo to test connectivity
        register(method: "ping") { request, completion in
            let response = Response(
                id: request.id,
                result: AnyCodable(["pong": true, "timestamp": Date().timeIntervalSince1970])
            )
            completion(response)
        }

        // Echo handler - returns the params back
        register(method: "echo") { request, completion in
            let response = Response(
                id: request.id,
                result: AnyCodable(request.params ?? [:])
            )
            completion(response)
        }

        // Get spaces - placeholder for future macOS Spaces API integration
        register(method: "getSpaces") { [weak self] request, completion in
            self?.logger.info("getSpaces called (placeholder)")

            let mockSpaces = [
                ["id": 1, "name": "Space 1", "index": 0],
                ["id": 2, "name": "Space 2", "index": 1],
                ["id": 3, "name": "Space 3", "index": 2]
            ]

            let response = Response(
                id: request.id,
                result: AnyCodable(["spaces": mockSpaces])
            )
            completion(response)
        }

        // Get windows - placeholder for future macOS Windows API integration
        register(method: "getWindows") { [weak self] request, completion in
            self?.logger.info("getWindows called (placeholder)")

            let mockWindows = [
                ["id": 101, "title": "Terminal", "app": "Terminal", "space": 1],
                ["id": 102, "title": "Safari", "app": "Safari", "space": 1],
                ["id": 103, "title": "VSCode", "app": "Code", "space": 2]
            ]

            let response = Response(
                id: request.id,
                result: AnyCodable(["windows": mockWindows])
            )
            completion(response)
        }

        // Subscribe - placeholder for event subscriptions
        register(method: "subscribe") { [weak self] request, completion in
            self?.logger.info("Subscribe called", metadata: ["params": "\(request.params ?? [:])"])

            let response = Response(
                id: request.id,
                result: AnyCodable(["subscribed": true])
            )
            completion(response)
        }

        // Get server info
        register(method: "getServerInfo") { request, completion in
            let info: [String: Any] = [
                "name": "GridServer",
                "version": "0.1.0",
                "platform": "macOS",
                "capabilities": [
                    "spaces": true,
                    "windows": true,
                    "events": true,
                    "stateTracking": true
                ]
            ]

            let response = Response(
                id: request.id,
                result: AnyCodable(info)
            )
            completion(response)
        }

        // Dump - returns complete window manager state
        register(method: "dump") { [weak self] request, completion in
            self?.logger.info("dump called - returning complete state")

            do {
                // Get state from StateManager (Codable type preserves all type information)
                let state = try StateManager.shared.getStateDictionary()

                let response = Response(
                    id: request.id,
                    result: AnyCodable(state)
                )
                completion(response)
            } catch {
                self?.logger.error("Failed to get state: \(error)")
                let response = Response(
                    id: request.id,
                    error: ErrorInfo(
                        code: -32603,
                        message: "Internal error: \(error.localizedDescription)"
                    )
                )
                completion(response)
            }
        }

        // UpdateWindow - manipulate window position, size, space, or display
        register(method: "updateWindow") { [weak self] request, completion in
            guard let self = self else {
                completion(Response(id: request.id, error: ErrorInfo(code: -32603, message: "Handler not available")))
                return
            }

            self.logger.info("updateWindow called", metadata: ["params": "\(request.params ?? [:])"])

            // Extract parameters
            guard let params = request.params,
                  let windowIdWrapper = params["windowId"],
                  let windowId = windowIdWrapper.value as? Int else {
                let response = Response(
                    id: request.id,
                    error: ErrorInfo(code: -32602, message: "Invalid params: windowId is required")
                )
                completion(response)
                return
            }

            let windowID = UInt32(windowId)

            // Optional parameters
            let x = (params["x"]?.value as? NSNumber)?.doubleValue
            let y = (params["y"]?.value as? NSNumber)?.doubleValue
            let width = (params["width"]?.value as? NSNumber)?.doubleValue
            let height = (params["height"]?.value as? NSNumber)?.doubleValue
            let spaceId = params["spaceId"]?.value as? String
            let displayUuid = params["displayUuid"]?.value as? String

            // Get window state
            let state = StateManager.shared.getState()
            guard let windowState = state.windows[String(windowID)] else {
                let response = Response(
                    id: request.id,
                    error: ErrorInfo(code: -32001, message: "Window not found: \(windowID)")
                )
                completion(response)
                return
            }

            // Create WindowManipulator
            let manipulator = WindowManipulator(
                connectionID: state.metadata.connectionID,
                logger: self.logger
            )

            var updatesApplied: [String] = []
            var errors: [String] = []

            // Handle display move first (if specified)
            if let displayUuid = displayUuid {
                let position = (x != nil && y != nil) ? CGPoint(x: x!, y: y!) : nil
                if manipulator.moveWindowToDisplay(
                    windowID: windowID,
                    displayUUID: displayUuid,
                    position: position,
                    stateManager: StateManager.shared
                ) {
                    updatesApplied.append("display")
                    if position != nil {
                        updatesApplied.append("position")
                    }
                } else {
                    errors.append("Failed to move window to display")
                }
            }
            // Handle space move (if no display specified)
            else if let spaceIdStr = spaceId, let spaceID = UInt64(spaceIdStr) {
                if manipulator.moveWindowToSpace(windowID: windowID, spaceID: spaceID) {
                    updatesApplied.append("space")
                } else {
                    errors.append("Failed to move window to space")
                }
            }

            // Handle frame updates (if display wasn't moved, or if only size is being updated)
            if displayUuid == nil || (width != nil || height != nil) {
                // Get AX element
                guard let element = manipulator.getAXElement(pid: windowState.pid, windowID: windowID) else {
                    let response = Response(
                        id: request.id,
                        error: ErrorInfo(code: -32002, message: "Failed to get AX element for window")
                    )
                    completion(response)
                    return
                }

                // Update position (if specified and display wasn't moved)
                if let x = x, let y = y, displayUuid == nil {
                    if manipulator.setWindowPosition(element: element, point: CGPoint(x: x, y: y)) {
                        updatesApplied.append("position")
                    } else {
                        errors.append("Failed to set window position")
                    }
                }

                // Update size (if specified)
                if let width = width, let height = height {
                    if manipulator.setWindowSize(element: element, size: CGSize(width: width, height: height)) {
                        updatesApplied.append("size")
                    } else {
                        errors.append("Failed to set window size")
                    }
                }
            }

            // Build response
            if errors.isEmpty {
                let response = Response(
                    id: request.id,
                    result: AnyCodable([
                        "success": true,
                        "windowId": windowId,
                        "updatesApplied": updatesApplied
                    ])
                )
                completion(response)
            } else {
                let response = Response(
                    id: request.id,
                    error: ErrorInfo(
                        code: -32003,
                        message: "Window update partially failed: \(errors.joined(separator: ", "))"
                    )
                )
                completion(response)
            }
        }
    }
}
