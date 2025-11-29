import Foundation
import Logging
import mss

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

        // MARK: - Window Opacity Methods (MSS)

        // Set window opacity
        register(method: "window.setOpacity") { [weak self] request, completion in
            guard let self = self else { return }
            guard let params = request.params else {
                completion(Response(id: request.id, error: ErrorInfo(code: -32602, message: "Invalid params")))
                return
            }

            guard let windowId = params["windowId"]?.value as? String,
                  let windowID = UInt32(windowId),
                  let opacity = ((params["opacity"]?.value as? NSNumber))?.floatValue else {
                completion(Response(id: request.id, error: ErrorInfo(code: -32602, message: "Missing windowId or opacity")))
                return
            }

            let state = StateManager.shared.getState()
            let manipulator = WindowManipulator(connectionID: state.metadata.connectionID, logger: self.logger)

            if manipulator.mssClient.setWindowOpacity(windowID: windowID, opacity: opacity) {
                completion(Response(id: request.id, result: AnyCodable(["success": true, "windowId": windowId, "opacity": opacity])))
            } else {
                completion(Response(id: request.id, error: ErrorInfo(code: -32000, message: "Failed to set window opacity. MSS may not be available.")))
            }
        }

        // Fade window opacity
        register(method: "window.fadeOpacity") { [weak self] request, completion in
            guard let self = self else { return }
            guard let params = request.params else {
                completion(Response(id: request.id, error: ErrorInfo(code: -32602, message: "Invalid params")))
                return
            }

            guard let windowId = params["windowId"]?.value as? String,
                  let windowID = UInt32(windowId),
                  let opacity = ((params["opacity"]?.value as? NSNumber))?.floatValue,
                  let duration = ((params["duration"]?.value as? NSNumber))?.floatValue else {
                completion(Response(id: request.id, error: ErrorInfo(code: -32602, message: "Missing windowId, opacity, or duration")))
                return
            }

            let state = StateManager.shared.getState()
            let manipulator = WindowManipulator(connectionID: state.metadata.connectionID, logger: self.logger)

            if manipulator.mssClient.fadeWindowOpacity(windowID: windowID, opacity: opacity, duration: duration) {
                completion(Response(id: request.id, result: AnyCodable(["success": true, "windowId": windowId, "opacity": opacity, "duration": duration])))
            } else {
                completion(Response(id: request.id, error: ErrorInfo(code: -32000, message: "Failed to fade window opacity. MSS may not be available.")))
            }
        }

        // Get window opacity
        register(method: "window.getOpacity") { [weak self] request, completion in
            guard let self = self else { return }
            guard let params = request.params else {
                completion(Response(id: request.id, error: ErrorInfo(code: -32602, message: "Invalid params")))
                return
            }

            guard let windowId = params["windowId"]?.value as? String,
                  let windowID = UInt32(windowId) else {
                completion(Response(id: request.id, error: ErrorInfo(code: -32602, message: "Missing windowId")))
                return
            }

            let state = StateManager.shared.getState()
            let manipulator = WindowManipulator(connectionID: state.metadata.connectionID, logger: self.logger)

            if let opacity = manipulator.mssClient.getWindowOpacity(windowID) {
                completion(Response(id: request.id, result: AnyCodable(["windowId": windowId, "opacity": opacity])))
            } else {
                completion(Response(id: request.id, error: ErrorInfo(code: -32000, message: "Failed to get window opacity")))
            }
        }

        // MARK: - Window Layer Methods (MSS)

        // Set window layer
        register(method: "window.setLayer") { [weak self] request, completion in
            guard let self = self else { return }
            guard let params = request.params else {
                completion(Response(id: request.id, error: ErrorInfo(code: -32602, message: "Invalid params")))
                return
            }

            guard let windowId = params["windowId"]?.value as? String,
                  let windowID = UInt32(windowId),
                  let layerStr = params["layer"]?.value as? String else {
                completion(Response(id: request.id, error: ErrorInfo(code: -32602, message: "Missing windowId or layer")))
                return
            }

            guard let layer = WindowLayer(string: layerStr) else {
                completion(Response(id: request.id, error: ErrorInfo(code: -32602, message: "Invalid layer. Must be 'below', 'normal', or 'above'")))
                return
            }

            let state = StateManager.shared.getState()
            let manipulator = WindowManipulator(connectionID: state.metadata.connectionID, logger: self.logger)

            if manipulator.mssClient.setWindowLayer(windowID: windowID, layer: layer) {
                completion(Response(id: request.id, result: AnyCodable(["success": true, "windowId": windowId, "layer": layer.description])))
            } else {
                completion(Response(id: request.id, error: ErrorInfo(code: -32000, message: "Failed to set window layer. MSS may not be available.")))
            }
        }

        // Get window layer
        register(method: "window.getLayer") { [weak self] request, completion in
            guard let self = self else { return }
            guard let params = request.params else {
                completion(Response(id: request.id, error: ErrorInfo(code: -32602, message: "Invalid params")))
                return
            }

            guard let windowId = params["windowId"]?.value as? String,
                  let windowID = UInt32(windowId) else {
                completion(Response(id: request.id, error: ErrorInfo(code: -32602, message: "Missing windowId")))
                return
            }

            let state = StateManager.shared.getState()
            let manipulator = WindowManipulator(connectionID: state.metadata.connectionID, logger: self.logger)

            if let layer = manipulator.mssClient.getWindowLayer(windowID) {
                let layerStr = layer.description
                completion(Response(id: request.id, result: AnyCodable(["windowId": windowId, "layer": layerStr])))
            } else {
                completion(Response(id: request.id, error: ErrorInfo(code: -32000, message: "Failed to get window layer")))
            }
        }

        // MARK: - Window Sticky/Minimize Methods (MSS)

        // Set window sticky
        register(method: "window.setSticky") { [weak self] request, completion in
            guard let self = self else { return }
            guard let params = request.params else {
                completion(Response(id: request.id, error: ErrorInfo(code: -32602, message: "Invalid params")))
                return
            }

            guard let windowId = params["windowId"]?.value as? String,
                  let windowID = UInt32(windowId),
                  let sticky = (params["sticky"]?.value as? Bool) else {
                completion(Response(id: request.id, error: ErrorInfo(code: -32602, message: "Missing windowId or sticky")))
                return
            }

            let state = StateManager.shared.getState()
            let manipulator = WindowManipulator(connectionID: state.metadata.connectionID, logger: self.logger)

            if manipulator.mssClient.setWindowSticky(windowID: windowID, sticky: sticky) {
                completion(Response(id: request.id, result: AnyCodable(["success": true, "windowId": windowId, "sticky": sticky])))
            } else {
                completion(Response(id: request.id, error: ErrorInfo(code: -32000, message: "Failed to set window sticky. MSS may not be available.")))
            }
        }

        // Get window sticky status
        register(method: "window.isSticky") { [weak self] request, completion in
            guard let self = self else { return }
            guard let params = request.params else {
                completion(Response(id: request.id, error: ErrorInfo(code: -32602, message: "Invalid params")))
                return
            }

            guard let windowId = params["windowId"]?.value as? String,
                  let windowID = UInt32(windowId) else {
                completion(Response(id: request.id, error: ErrorInfo(code: -32602, message: "Missing windowId")))
                return
            }

            let state = StateManager.shared.getState()
            let manipulator = WindowManipulator(connectionID: state.metadata.connectionID, logger: self.logger)

            if let sticky = manipulator.mssClient.isWindowSticky(windowID) {
                completion(Response(id: request.id, result: AnyCodable(["windowId": windowId, "sticky": sticky])))
            } else {
                completion(Response(id: request.id, error: ErrorInfo(code: -32000, message: "Failed to get window sticky status")))
            }
        }

        // Minimize window
        register(method: "window.minimize") { [weak self] request, completion in
            guard let self = self else { return }
            guard let params = request.params else {
                completion(Response(id: request.id, error: ErrorInfo(code: -32602, message: "Invalid params")))
                return
            }

            guard let windowId = params["windowId"]?.value as? String,
                  let windowID = UInt32(windowId) else {
                completion(Response(id: request.id, error: ErrorInfo(code: -32602, message: "Missing windowId")))
                return
            }

            let state = StateManager.shared.getState()
            let manipulator = WindowManipulator(connectionID: state.metadata.connectionID, logger: self.logger)

            if manipulator.mssClient.minimizeWindow(windowID) {
                completion(Response(id: request.id, result: AnyCodable(["success": true, "windowId": windowId])))
            } else {
                completion(Response(id: request.id, error: ErrorInfo(code: -32000, message: "Failed to minimize window. MSS may not be available.")))
            }
        }

        // Unminimize window
        register(method: "window.unminimize") { [weak self] request, completion in
            guard let self = self else { return }
            guard let params = request.params else {
                completion(Response(id: request.id, error: ErrorInfo(code: -32602, message: "Invalid params")))
                return
            }

            guard let windowId = params["windowId"]?.value as? String,
                  let windowID = UInt32(windowId) else {
                completion(Response(id: request.id, error: ErrorInfo(code: -32602, message: "Missing windowId")))
                return
            }

            let state = StateManager.shared.getState()
            let manipulator = WindowManipulator(connectionID: state.metadata.connectionID, logger: self.logger)

            if manipulator.mssClient.unminimizeWindow(windowID) {
                completion(Response(id: request.id, result: AnyCodable(["success": true, "windowId": windowId])))
            } else {
                completion(Response(id: request.id, error: ErrorInfo(code: -32000, message: "Failed to unminimize window. MSS may not be available.")))
            }
        }

        // Check if window is minimized
        register(method: "window.isMinimized") { [weak self] request, completion in
            guard let self = self else { return }
            guard let params = request.params else {
                completion(Response(id: request.id, error: ErrorInfo(code: -32602, message: "Invalid params")))
                return
            }

            guard let windowId = params["windowId"]?.value as? String,
                  let windowID = UInt32(windowId) else {
                completion(Response(id: request.id, error: ErrorInfo(code: -32602, message: "Missing windowId")))
                return
            }

            let state = StateManager.shared.getState()
            let manipulator = WindowManipulator(connectionID: state.metadata.connectionID, logger: self.logger)

            if let minimized = manipulator.mssClient.isWindowMinimized(windowID) {
                completion(Response(id: request.id, result: AnyCodable(["windowId": windowId, "minimized": minimized])))
            } else {
                completion(Response(id: request.id, error: ErrorInfo(code: -32000, message: "Failed to get window minimized status")))
            }
        }

        // MARK: - Window Focus Methods

        // Focus window (raise and activate)
        register(method: "window.focus") { [weak self] request, completion in
            guard let self = self else { return }
            guard let params = request.params else {
                completion(Response(id: request.id, error: ErrorInfo(code: -32602, message: "Invalid params")))
                return
            }

            // Accept windowId as either string or int
            var windowID: UInt32?
            if let windowIdInt = params["windowId"]?.value as? Int {
                windowID = UInt32(windowIdInt)
            } else if let windowIdStr = params["windowId"]?.value as? String,
                      let parsed = UInt32(windowIdStr) {
                windowID = parsed
            }

            guard let wid = windowID else {
                completion(Response(id: request.id, error: ErrorInfo(code: -32602, message: "Missing or invalid windowId")))
                return
            }

            // Get window state to find PID
            let state = StateManager.shared.getState()
            guard let windowState = state.windows[String(wid)] else {
                completion(Response(id: request.id, error: ErrorInfo(code: -32001, message: "Window not found: \(wid)")))
                return
            }

            let manipulator = WindowManipulator(connectionID: state.metadata.connectionID, logger: self.logger)

            if manipulator.focusWindow(pid: windowState.pid, windowID: wid) {
                // Immediately update focus state (don't wait for AX notification)
                StateManager.shared.handleWindowFocused(wid)
                completion(Response(id: request.id, result: AnyCodable(["success": true, "windowId": wid])))
            } else {
                completion(Response(id: request.id, error: ErrorInfo(code: -32000, message: "Failed to focus window")))
            }
        }

        // MARK: - Space Management Methods (MSS)

        // Create space
        register(method: "space.create") { [weak self] request, completion in
            guard let self = self else { return }
            guard let params = request.params else {
                completion(Response(id: request.id, error: ErrorInfo(code: -32602, message: "Invalid params")))
                return
            }

            guard let spaceIdStr = params["displaySpaceId"]?.value as? String,
                  let displaySpaceID = UInt64(spaceIdStr) else {
                completion(Response(id: request.id, error: ErrorInfo(code: -32602, message: "Missing displaySpaceId")))
                return
            }

            let state = StateManager.shared.getState()
            let manipulator = WindowManipulator(connectionID: state.metadata.connectionID, logger: self.logger)

            if manipulator.mssClient.createSpace(on: displaySpaceID) {
                completion(Response(id: request.id, result: AnyCodable(["success": true, "displaySpaceId": spaceIdStr])))
            } else {
                completion(Response(id: request.id, error: ErrorInfo(code: -32000, message: "Failed to create space. MSS may not be available.")))
            }
        }

        // Destroy space
        register(method: "space.destroy") { [weak self] request, completion in
            guard let self = self else { return }
            guard let params = request.params else {
                completion(Response(id: request.id, error: ErrorInfo(code: -32602, message: "Invalid params")))
                return
            }

            guard let spaceIdStr = params["spaceId"]?.value as? String,
                  let spaceID = UInt64(spaceIdStr) else {
                completion(Response(id: request.id, error: ErrorInfo(code: -32602, message: "Missing spaceId")))
                return
            }

            let state = StateManager.shared.getState()
            let manipulator = WindowManipulator(connectionID: state.metadata.connectionID, logger: self.logger)

            if manipulator.mssClient.destroySpace(spaceID) {
                completion(Response(id: request.id, result: AnyCodable(["success": true, "spaceId": spaceIdStr])))
            } else {
                completion(Response(id: request.id, error: ErrorInfo(code: -32000, message: "Failed to destroy space. MSS may not be available.")))
            }
        }

        // Focus space
        register(method: "space.focus") { [weak self] request, completion in
            guard let self = self else { return }
            guard let params = request.params else {
                completion(Response(id: request.id, error: ErrorInfo(code: -32602, message: "Invalid params")))
                return
            }

            guard let spaceIdStr = params["spaceId"]?.value as? String,
                  let spaceID = UInt64(spaceIdStr) else {
                completion(Response(id: request.id, error: ErrorInfo(code: -32602, message: "Missing spaceId")))
                return
            }

            let state = StateManager.shared.getState()
            let manipulator = WindowManipulator(connectionID: state.metadata.connectionID, logger: self.logger)

            if manipulator.mssClient.focusSpace(spaceID) {
                completion(Response(id: request.id, result: AnyCodable(["success": true, "spaceId": spaceIdStr])))
            } else {
                completion(Response(id: request.id, error: ErrorInfo(code: -32000, message: "Failed to focus space. MSS may not be available.")))
            }
        }
    }
}
