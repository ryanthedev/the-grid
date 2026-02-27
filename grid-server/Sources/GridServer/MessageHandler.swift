import Foundation
import Logging
import mss
import CoreGraphics
import AppKit

/// Handles incoming requests and routes them to appropriate handlers
class MessageHandler {
    typealias RequestHandler = (Request, @escaping (Response) -> Void) -> Void

    private var handlers: [String: RequestHandler] = [:]

    /// Simple border manager for handling simplified border system
    weak var simpleBorderManager: SimpleBorderManager?

    init(logger: Logger? = nil) {
        registerBuiltInHandlers()
    }

    /// Register a handler for a specific method
    func register(method: String, handler: @escaping RequestHandler) {
        handlers[method] = handler
        Task {
            JSONLogger.shared.log("msg.register", data: ["method": method])
        }
    }

    /// Handle a request and call completion with the response
    func handle(request: Request, completion: @escaping (Response) -> Void) {
        // Extract trace context from params
        var tid: String? = nil
        var parentSid: String? = nil
        if let traceInfo = request.params?["_trace"]?.value as? [String: String] {
            tid = traceInfo["tid"]
            parentSid = traceInfo["sid"]
        }

        // Create server span (or generate new trace if none provided)
        let span: Span
        if let tid = tid {
            span = JSONLogger.shared.startSpan("srv", tid: tid, parentSid: parentSid, data: ["method": request.method])
        } else {
            let newTid = UUID().uuidString.prefix(8).lowercased()
            span = JSONLogger.shared.startSpan("srv", tid: String(newTid), parentSid: nil, data: ["method": request.method])
        }

        // Execute handler within span context
        Task {
            await CurrentSpan.$current.withValue(span) {
                JSONLogger.shared.log("msg.handle", data: ["id": request.id, "method": request.method])

                guard let handler = handlers[request.method] else {
                    let response = Response(
                        id: request.id,
                        error: ErrorInfo(
                            code: -32601,
                            message: "Method not found: \(request.method)"
                        )
                    )

                    JSONLogger.shared.log("msg.err", data: [
                        "op": "method_not_found",
                        "method": request.method,
                        "id": request.id
                    ])

                    await span.end()
                    completion(response)
                    return
                }

                // Execute handler with span context
                handler(request) { response in
                    Task {
                        await span.end()
                    }
                    completion(response)
                }
            }
        }
    }

    /// Convert a DisplayState to a dictionary for RPC responses
    private func displayToDict(_ display: DisplayState) -> [String: Any] {
        var dict: [String: Any] = [
            "uuid": display.uuid,
            "name": display.name ?? "",
            "currentSpaceID": String(display.currentSpaceID),
            "isMain": display.isMain ?? false,
            "backingScaleFactor": display.backingScaleFactor ?? 1.0
        ]
        if let f = display.frame {
            dict["frame"] = ["x": f.origin.x, "y": f.origin.y, "width": f.width, "height": f.height]
        }
        if let f = display.visibleFrame {
            dict["visibleFrame"] = ["x": f.origin.x, "y": f.origin.y, "width": f.width, "height": f.height]
        }
        return dict
    }

    /// Register built-in handlers for demonstration
    private func registerBuiltInHandlers() {
        // Ping handler - simple echo to test connectivity
        register(method: "ping") { request, completion in
            let response = Response(
                id: request.id,
                result: AnyCodable([
                    "pong": true,
                    "timestamp": Date().timeIntervalSince1970,
                    "version": GridServerVersion,
                    "commit": GridServerCommit
                ])
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
                "version": GridServerVersion,
                "commit": GridServerCommit,
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

        // MARK: - Lightweight Query Methods

        // metadata.get - returns cached metadata without window enumeration
        register(method: "metadata.get") { request, completion in
            Task {
                let state = await StateManager.shared.getState()
                let meta = state.metadata

                var result: [String: Any] = [
                    "lastUpdate": meta.lastUpdate.timeIntervalSince1970,
                    "version": meta.version,
                    "connectionID": meta.connectionID
                ]
                if let fwid = meta.focusedWindowID {
                    result["focusedWindowID"] = fwid
                }
                if let uuid = meta.activeDisplayUUID {
                    result["activeDisplayUUID"] = uuid
                }
                if let sid = meta.activeSpaceID {
                    result["activeSpaceID"] = String(sid)
                }

                completion(Response(id: request.id, result: AnyCodable(result)))
            }
        }

        // display.list - returns all connected displays (no windows/apps/spaces)
        register(method: "display.list") { [self] request, completion in
            Task {
                let state = await StateManager.shared.getState()
                let displayArray = state.displays.map { self.displayToDict($0) }
                completion(Response(id: request.id, result: AnyCodable(["displays": displayArray])))
            }
        }

        // display.get - returns a single display by UUID or active shorthand
        register(method: "display.get") { [self] request, completion in
            guard let params = request.params else {
                completion(Response(id: request.id, error: ErrorInfo(code: -32602, message: "Invalid params")))
                return
            }

            Task {
                let state = await StateManager.shared.getState()

                let display: DisplayState?

                if let active = params["active"]?.value as? Bool, active {
                    // Look up by active display UUID from metadata
                    guard let activeUUID = state.metadata.activeDisplayUUID else {
                        completion(Response(id: request.id, error: ErrorInfo(code: -32000, message: "No active display")))
                        return
                    }
                    display = state.displays.first { $0.uuid == activeUUID }
                } else if let uuid = params["uuid"]?.value as? String {
                    display = state.displays.first { $0.uuid == uuid }
                } else {
                    completion(Response(id: request.id, error: ErrorInfo(code: -32602, message: "Missing uuid or active param")))
                    return
                }

                guard let found = display else {
                    completion(Response(id: request.id, error: ErrorInfo(code: -32000, message: "Display not found")))
                    return
                }

                completion(Response(id: request.id, result: AnyCodable(self.displayToDict(found))))
            }
        }

        // window.find - searches state.windows by criteria, returns immediately
        register(method: "window.find") { request, completion in
            guard let params = request.params else {
                completion(Response(id: request.id, error: ErrorInfo(code: -32602, message: "Invalid params")))
                return
            }

            let appNameFilter = params["appName"]?.value as? String
            let titleFilter = params["title"]?.value as? String

            guard appNameFilter != nil || titleFilter != nil else {
                completion(Response(id: request.id, error: ErrorInfo(code: -32602, message: "At least one of appName or title required")))
                return
            }

            Task {
                let state = await StateManager.shared.getState()

                for window in state.windows.values {
                    if let appName = appNameFilter, window.appName != appName { continue }
                    if let title = titleFilter, !(window.title?.contains(title) ?? false) { continue }
                    if window.isHidden { continue }
                    if window.frame.height < 100 { continue }

                    completion(Response(id: request.id, result: AnyCodable([
                        "found": true,
                        "windowId": String(window.id),
                        "pid": window.pid
                    ])))
                    return
                }

                completion(Response(id: request.id, result: AnyCodable(["found": false])))
            }
        }

        // Dump - returns complete window manager state
        register(method: "dump") { request, completion in
            Task {
                do {
                    // Get state from StateManager (Codable type preserves all type information)
                    var state = try await StateManager.shared.getStateDictionary()

                    // Add server version info directly to state (avoids JSONSerialization type coercion)
                    state.serverVersion = GridServerVersion
                    state.serverCommit = GridServerCommit

                    let response = Response(
                        id: request.id,
                        result: AnyCodable(state)
                    )
                    completion(response)
                } catch {
                    JSONLogger.shared.log("err.state", data: ["op": "dump", "error": "\(error)"])
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
        }

        // UpdateWindow - manipulate window position, size, space, or display
        register(method: "updateWindow") { request, completion in
            // Extract parameters synchronously
            guard let params = request.params,
                  let windowIdWrapper = params["windowId"],
                  let windowId = windowIdWrapper.value as? Int else {
                completion(Response(id: request.id, error: ErrorInfo(code: -32602, message: "Invalid params: windowId is required")))
                return
            }

            let windowID = UInt32(windowId)
            let x = (params["x"]?.value as? NSNumber)?.doubleValue
            let y = (params["y"]?.value as? NSNumber)?.doubleValue
            let width = (params["width"]?.value as? NSNumber)?.doubleValue
            let height = (params["height"]?.value as? NSNumber)?.doubleValue
            let spaceId = params["spaceId"]?.value as? String
            let displayUuid = params["displayUuid"]?.value as? String

            Task {
                // Create context from window state
                guard var context = await ManipulationContext.from(windowID: windowID) else {
                    JSONLogger.shared.log("err.window", data: [
                        "op": "updateWindow",
                        "msg": "not_found",
                        "wid": windowID,
                        "id": request.id
                    ])
                    completion(Response(id: request.id, error: ErrorInfo(code: -32001, message: "Window not found: \(windowID)")))
                    return
                }

                // Create WindowManipulator
                let state = await StateManager.shared.getState()
                let manipulator = WindowManipulator(connectionID: state.metadata.connectionID)

                var updatesApplied: [String] = []
                var errors: [String] = []
                let requestID = UUID().uuidString

                // Handle display move first (if specified)
                if let displayUuid = displayUuid {
                    let position = (x != nil && y != nil) ? CGPoint(x: x!, y: y!) : nil
                    if await manipulator.moveWindowToDisplay(
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
                    await EventRouter.shared.route(
                        .commandMoveWindowToSpace(windowID: windowID, spaceID: spaceID, requestID: requestID),
                        from: .manual(reason: "cli")
                    )
                    if manipulator.moveWindowToSpace(windowID: windowID, spaceID: spaceID) {
                        updatesApplied.append("space")
                    } else {
                        errors.append("Failed to move window to space")
                    }
                }

                // Handle frame updates (if display wasn't moved, or if only size is being updated)
                if displayUuid == nil || (width != nil || height != nil) {
                    // Update position (if specified and display wasn't moved)
                    if let x = x, let y = y, displayUuid == nil {
                        let targetPoint = CGPoint(x: x, y: y)
                        let currentSize = context.frame?.size ?? CGSize(width: 100, height: 100)
                        let targetFrame = CGRect(origin: targetPoint, size: currentSize)

                        await EventRouter.shared.route(
                            .commandMoveWindow(windowID: windowID, frame: targetFrame, requestID: requestID),
                            from: .manual(reason: "cli")
                        )

                        if await manipulator.moveWindow(context: context, to: targetPoint) {
                            context.frame = targetFrame
                            updatesApplied.append("position")
                            JSONLogger.shared.log("pos.result", data: [
                                "wid": windowID,
                                "req": ["x": x, "y": y],
                                "ok": true
                            ])
                        } else {
                            errors.append("Failed to set window position")
                        }
                    }

                    // Update size (if specified)
                    if let width = width, let height = height {
                        let targetSize = CGSize(width: width, height: height)
                        let currentOrigin = context.frame?.origin ?? CGPoint.zero
                        let targetFrame = CGRect(origin: currentOrigin, size: targetSize)

                        await EventRouter.shared.route(
                            .commandResizeWindow(windowID: windowID, frame: targetFrame, requestID: requestID),
                            from: .manual(reason: "cli")
                        )

                        if await manipulator.resizeWindow(context: context, to: targetSize) {
                            context.frame = targetFrame
                            updatesApplied.append("size")
                        } else {
                            errors.append("Failed to set window size")
                        }
                    }
                }

                // Build response
                if errors.isEmpty {
                    completion(Response(id: request.id, result: AnyCodable([
                        "success": true,
                        "windowId": windowId,
                        "updatesApplied": updatesApplied
                    ])))
                } else {
                    JSONLogger.shared.log("err.window", data: [
                        "op": "updateWindow",
                        "msg": errors.joined(separator: ", "),
                        "wid": windowID,
                        "id": request.id
                    ])
                    completion(Response(id: request.id, error: ErrorInfo(
                        code: -32003,
                        message: "Window update partially failed: \(errors.joined(separator: ", "))"
                    )))
                }
            }
        }

        // MARK: - Window Opacity Methods (MSS)

        // Set window opacity
        register(method: "window.setOpacity") { request, completion in
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

            Task {
                let state = await StateManager.shared.getState()
                let manipulator = WindowManipulator(connectionID: state.metadata.connectionID)

                if manipulator.mssClient.setWindowOpacity(windowID: windowID, opacity: opacity) {
                    completion(Response(id: request.id, result: AnyCodable(["success": true, "windowId": windowId, "opacity": opacity])))
                } else {
                    completion(Response(id: request.id, error: ErrorInfo(code: -32000, message: "Failed to set window opacity. MSS may not be available.")))
                }
            }
        }

        // Fade window opacity
        register(method: "window.fadeOpacity") { request, completion in
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

            Task {
                let state = await StateManager.shared.getState()
                let manipulator = WindowManipulator(connectionID: state.metadata.connectionID)

                if manipulator.mssClient.fadeWindowOpacity(windowID: windowID, opacity: opacity, duration: duration) {
                    completion(Response(id: request.id, result: AnyCodable(["success": true, "windowId": windowId, "opacity": opacity, "duration": duration])))
                } else {
                    completion(Response(id: request.id, error: ErrorInfo(code: -32000, message: "Failed to fade window opacity. MSS may not be available.")))
                }
            }
        }

        // Get window opacity
        register(method: "window.getOpacity") { request, completion in
            guard let params = request.params else {
                completion(Response(id: request.id, error: ErrorInfo(code: -32602, message: "Invalid params")))
                return
            }

            guard let windowId = params["windowId"]?.value as? String,
                  let windowID = UInt32(windowId) else {
                completion(Response(id: request.id, error: ErrorInfo(code: -32602, message: "Missing windowId")))
                return
            }

            Task {
                let state = await StateManager.shared.getState()
                let manipulator = WindowManipulator(connectionID: state.metadata.connectionID)

                if let opacity = manipulator.mssClient.getWindowOpacity(windowID) {
                    completion(Response(id: request.id, result: AnyCodable(["windowId": windowId, "opacity": opacity])))
                } else {
                    completion(Response(id: request.id, error: ErrorInfo(code: -32000, message: "Failed to get window opacity")))
                }
            }
        }

        // MARK: - Window Layer Methods (MSS)

        // Set window layer
        register(method: "window.setLayer") { request, completion in
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

            Task {
                let state = await StateManager.shared.getState()
                let manipulator = WindowManipulator(connectionID: state.metadata.connectionID)

                if manipulator.mssClient.setWindowLayer(windowID: windowID, layer: layer) {
                    completion(Response(id: request.id, result: AnyCodable(["success": true, "windowId": windowId, "layer": layer.description])))
                } else {
                    completion(Response(id: request.id, error: ErrorInfo(code: -32000, message: "Failed to set window layer. MSS may not be available.")))
                }
            }
        }

        // Get window layer
        register(method: "window.getLayer") { request, completion in
            guard let params = request.params else {
                completion(Response(id: request.id, error: ErrorInfo(code: -32602, message: "Invalid params")))
                return
            }

            guard let windowId = params["windowId"]?.value as? String,
                  let windowID = UInt32(windowId) else {
                completion(Response(id: request.id, error: ErrorInfo(code: -32602, message: "Missing windowId")))
                return
            }

            Task {
                let state = await StateManager.shared.getState()
                let manipulator = WindowManipulator(connectionID: state.metadata.connectionID)

                if let layer = manipulator.mssClient.getWindowLayer(windowID) {
                    let layerStr = layer.description
                    completion(Response(id: request.id, result: AnyCodable(["windowId": windowId, "layer": layerStr])))
                } else {
                    completion(Response(id: request.id, error: ErrorInfo(code: -32000, message: "Failed to get window layer")))
                }
            }
        }

        // MARK: - Window Visibility Methods (SLS)

        // Check if window is ordered in (visible)
        register(method: "window.isOrderedIn") { request, completion in
            guard let params = request.params else {
                completion(Response(id: request.id, error: ErrorInfo(code: -32602, message: "Invalid params")))
                return
            }

            guard let windowId = params["windowId"]?.value as? String,
                  let windowID = UInt32(windowId) else {
                completion(Response(id: request.id, error: ErrorInfo(code: -32602, message: "Missing windowId")))
                return
            }

            Task {
                let state = await StateManager.shared.getState()
                var value: UInt8 = 0
                let err = SLSWindowIsOrderedIn(state.metadata.connectionID, windowID, &value)
                if err == .success {
                    // Include window's space membership for space-aware toggle
                    let spaces = state.windows[windowId]?.spaces ?? []
                    let spacesStrings = spaces.map { String($0) }
                    completion(Response(id: request.id, result: AnyCodable([
                        "windowId": windowId,
                        "isOrderedIn": value != 0,
                        "spaces": spacesStrings
                    ])))
                } else {
                    completion(Response(id: request.id, error: ErrorInfo(code: -32000, message: "Failed to check window ordered-in state")))
                }
            }
        }

        // Hide window (NSRunningApplication.hide for cross-process, MSS fallback)
        register(method: "window.hide") { request, completion in
            guard let params = request.params else {
                completion(Response(id: request.id, error: ErrorInfo(code: -32602, message: "Invalid params")))
                return
            }

            guard let windowId = params["windowId"]?.value as? String,
                  let windowID = UInt32(windowId) else {
                completion(Response(id: request.id, error: ErrorInfo(code: -32602, message: "Missing windowId")))
                return
            }

            Task {
                let state = await StateManager.shared.getState()
                let cid = state.metadata.connectionID

                // Try MSS first (works when available)
                let manipulator = WindowManipulator(connectionID: cid)
                if manipulator.mssClient.orderWindowOut(windowID) {
                    completion(Response(id: request.id, result: AnyCodable(["success": true, "windowId": windowId])))
                    return
                }

                // Fallback: hide via NSRunningApplication (hides entire app process)
                if let windowState = state.windows[windowId],
                   let app = NSRunningApplication(processIdentifier: windowState.pid) {
                    app.hide()
                    completion(Response(id: request.id, result: AnyCodable(["success": true, "windowId": windowId])))
                } else {
                    completion(Response(id: request.id, error: ErrorInfo(code: -32000, message: "Failed to hide window")))
                }
            }
        }

        // Show window (NSRunningApplication.unhide + activate, MSS fallback)
        register(method: "window.show") { request, completion in
            guard let params = request.params else {
                completion(Response(id: request.id, error: ErrorInfo(code: -32602, message: "Invalid params")))
                return
            }

            guard let windowId = params["windowId"]?.value as? String,
                  let windowID = UInt32(windowId) else {
                completion(Response(id: request.id, error: ErrorInfo(code: -32602, message: "Missing windowId")))
                return
            }

            Task {
                let state = await StateManager.shared.getState()
                let cid = state.metadata.connectionID

                // Try MSS first
                let manipulator = WindowManipulator(connectionID: cid)
                let ordered = manipulator.mssClient.orderWindowToFront(windowID)
                let focused = manipulator.mssClient.focusWindow(windowID)
                if ordered || focused {
                    completion(Response(id: request.id, result: AnyCodable(["success": true, "windowId": windowId])))
                    return
                }

                // Fallback: unhide + activate via NSRunningApplication
                if let windowState = state.windows[windowId],
                   let app = NSRunningApplication(processIdentifier: windowState.pid) {
                    app.unhide()
                    app.activate(options: .activateIgnoringOtherApps)
                    completion(Response(id: request.id, result: AnyCodable(["success": true, "windowId": windowId])))
                } else {
                    completion(Response(id: request.id, error: ErrorInfo(code: -32000, message: "Failed to show window")))
                }
            }
        }

        // MARK: - Window Sticky/Minimize Methods (MSS)

        // Set window sticky
        register(method: "window.setSticky") { request, completion in
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

            Task {
                let state = await StateManager.shared.getState()
                let manipulator = WindowManipulator(connectionID: state.metadata.connectionID)

                if manipulator.mssClient.setWindowSticky(windowID: windowID, sticky: sticky) {
                    completion(Response(id: request.id, result: AnyCodable(["success": true, "windowId": windowId, "sticky": sticky])))
                } else {
                    completion(Response(id: request.id, error: ErrorInfo(code: -32000, message: "Failed to set window sticky. MSS may not be available.")))
                }
            }
        }

        // Get window sticky status
        register(method: "window.isSticky") { request, completion in
            guard let params = request.params else {
                completion(Response(id: request.id, error: ErrorInfo(code: -32602, message: "Invalid params")))
                return
            }

            guard let windowId = params["windowId"]?.value as? String,
                  let windowID = UInt32(windowId) else {
                completion(Response(id: request.id, error: ErrorInfo(code: -32602, message: "Missing windowId")))
                return
            }

            Task {
                let state = await StateManager.shared.getState()
                let manipulator = WindowManipulator(connectionID: state.metadata.connectionID)

                if let sticky = manipulator.mssClient.isWindowSticky(windowID) {
                    completion(Response(id: request.id, result: AnyCodable(["windowId": windowId, "sticky": sticky])))
                } else {
                    completion(Response(id: request.id, error: ErrorInfo(code: -32000, message: "Failed to get window sticky status")))
                }
            }
        }

        // Minimize window
        register(method: "window.minimize") { request, completion in
            guard let params = request.params else {
                completion(Response(id: request.id, error: ErrorInfo(code: -32602, message: "Invalid params")))
                return
            }

            guard let windowId = params["windowId"]?.value as? String,
                  let windowID = UInt32(windowId) else {
                completion(Response(id: request.id, error: ErrorInfo(code: -32602, message: "Missing windowId")))
                return
            }

            Task {
                // Create context from window state
                guard let context = await ManipulationContext.from(windowID: windowID) else {
                    completion(Response(id: request.id, error: ErrorInfo(code: -32001, message: "Window not found: \(windowID)")))
                    return
                }

                // Emit command event before executing
                let requestID = UUID().uuidString
                await EventRouter.shared.route(
                    .commandMinimizeWindow(windowID: windowID, requestID: requestID),
                    from: .manual(reason: "cli")
                )

                let state = await StateManager.shared.getState()
                let manipulator = WindowManipulator(connectionID: state.metadata.connectionID)

                // Context-based minimize updates state automatically on success
                if await manipulator.minimizeWindow(context: context) {
                    completion(Response(id: request.id, result: AnyCodable(["success": true, "windowId": windowId])))
                } else {
                    completion(Response(id: request.id, error: ErrorInfo(code: -32000, message: "Failed to minimize window. MSS may not be available.")))
                }
            }
        }

        // Unminimize window
        register(method: "window.unminimize") { request, completion in
            guard let params = request.params else {
                completion(Response(id: request.id, error: ErrorInfo(code: -32602, message: "Invalid params")))
                return
            }

            guard let windowId = params["windowId"]?.value as? String,
                  let windowID = UInt32(windowId) else {
                completion(Response(id: request.id, error: ErrorInfo(code: -32602, message: "Missing windowId")))
                return
            }

            Task {
                // Create context from window state
                guard let context = await ManipulationContext.from(windowID: windowID) else {
                    completion(Response(id: request.id, error: ErrorInfo(code: -32001, message: "Window not found: \(windowID)")))
                    return
                }

                let state = await StateManager.shared.getState()
                let manipulator = WindowManipulator(connectionID: state.metadata.connectionID)

                // Context-based unminimize updates state automatically on success
                if await manipulator.unminimizeWindow(context: context) {
                    completion(Response(id: request.id, result: AnyCodable(["success": true, "windowId": windowId])))
                } else {
                    completion(Response(id: request.id, error: ErrorInfo(code: -32000, message: "Failed to unminimize window. MSS may not be available.")))
                }
            }
        }

        // Check if window is minimized
        register(method: "window.isMinimized") { request, completion in
            guard let params = request.params else {
                completion(Response(id: request.id, error: ErrorInfo(code: -32602, message: "Invalid params")))
                return
            }

            guard let windowId = params["windowId"]?.value as? String,
                  let windowID = UInt32(windowId) else {
                completion(Response(id: request.id, error: ErrorInfo(code: -32602, message: "Missing windowId")))
                return
            }

            Task {
                let state = await StateManager.shared.getState()
                let manipulator = WindowManipulator(connectionID: state.metadata.connectionID)

                if let minimized = manipulator.mssClient.isWindowMinimized(windowID) {
                    completion(Response(id: request.id, result: AnyCodable(["windowId": windowId, "minimized": minimized])))
                } else {
                    completion(Response(id: request.id, error: ErrorInfo(code: -32000, message: "Failed to get window minimized status")))
                }
            }
        }

        // MARK: - Window Focus Methods

        // Focus window (raise and activate)
        register(method: "window.focus") { request, completion in
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

            Task {
                // Create context from window state
                guard let context = await ManipulationContext.from(windowID: wid) else {
                    JSONLogger.shared.log("err.window", data: [
                        "op": "window.focus",
                        "msg": "not_found",
                        "wid": wid,
                        "id": request.id
                    ])
                    completion(Response(id: request.id, error: ErrorInfo(code: -32001, message: "Window not found: \(wid)")))
                    return
                }

                // Emit command event before executing
                let requestID = UUID().uuidString
                await EventRouter.shared.route(
                    .commandFocusWindow(windowID: wid, requestID: requestID),
                    from: .manual(reason: "cli")
                )

                // Mark CLI focus intent BEFORE focus operation to prevent border sync loop
                // AX observer may fire immediately when window is focused
                await StateManager.shared.markCLIFocusIntent(wid)

                let state = await StateManager.shared.getState()
                let manipulator = WindowManipulator(connectionID: state.metadata.connectionID)

                // Context-based focus updates state automatically on success
                if await manipulator.focusWindow(context: context) {
                    completion(Response(id: request.id, result: AnyCodable(["success": true, "windowId": wid])))
                } else {
                    JSONLogger.shared.log("err.window", data: [
                        "op": "window.focus",
                        "msg": "failed",
                        "wid": wid,
                        "id": request.id
                    ])
                    completion(Response(id: request.id, error: ErrorInfo(code: -32000, message: "Failed to focus window")))
                }
            }
        }

        // MARK: - Space Management Methods (MSS)

        // Create space
        register(method: "space.create") { request, completion in
            guard let params = request.params else {
                completion(Response(id: request.id, error: ErrorInfo(code: -32602, message: "Invalid params")))
                return
            }

            guard let spaceIdStr = params["displaySpaceId"]?.value as? String,
                  let displaySpaceID = UInt64(spaceIdStr) else {
                completion(Response(id: request.id, error: ErrorInfo(code: -32602, message: "Missing displaySpaceId")))
                return
            }

            Task {
                let state = await StateManager.shared.getState()
                let manipulator = WindowManipulator(connectionID: state.metadata.connectionID)

                if manipulator.mssClient.createSpace(on: displaySpaceID) {
                    completion(Response(id: request.id, result: AnyCodable(["success": true, "displaySpaceId": spaceIdStr])))
                } else {
                    completion(Response(id: request.id, error: ErrorInfo(code: -32000, message: "Failed to create space. MSS may not be available.")))
                }
            }
        }

        // Destroy space
        register(method: "space.destroy") { request, completion in
            guard let params = request.params else {
                completion(Response(id: request.id, error: ErrorInfo(code: -32602, message: "Invalid params")))
                return
            }

            guard let spaceIdStr = params["spaceId"]?.value as? String,
                  let spaceID = UInt64(spaceIdStr) else {
                completion(Response(id: request.id, error: ErrorInfo(code: -32602, message: "Missing spaceId")))
                return
            }

            Task {
                let state = await StateManager.shared.getState()
                let manipulator = WindowManipulator(connectionID: state.metadata.connectionID)

                if manipulator.mssClient.destroySpace(spaceID) {
                    completion(Response(id: request.id, result: AnyCodable(["success": true, "spaceId": spaceIdStr])))
                } else {
                    completion(Response(id: request.id, error: ErrorInfo(code: -32000, message: "Failed to destroy space. MSS may not be available.")))
                }
            }
        }

        // Focus space
        register(method: "space.focus") { request, completion in
            guard let params = request.params else {
                completion(Response(id: request.id, error: ErrorInfo(code: -32602, message: "Invalid params")))
                return
            }

            guard let spaceIdStr = params["spaceId"]?.value as? String,
                  let spaceID = UInt64(spaceIdStr) else {
                completion(Response(id: request.id, error: ErrorInfo(code: -32602, message: "Missing spaceId")))
                return
            }

            Task {
                let state = await StateManager.shared.getState()
                let manipulator = WindowManipulator(connectionID: state.metadata.connectionID)

                if manipulator.mssClient.focusSpace(spaceID) {
                    completion(Response(id: request.id, result: AnyCodable(["success": true, "spaceId": spaceIdStr])))
                } else {
                    completion(Response(id: request.id, error: ErrorInfo(code: -32000, message: "Failed to focus space. MSS may not be available.")))
                }
            }
        }

        // MARK: - Mouse Methods

        // Warp mouse cursor to center of a window
        register(method: "mouse.warp") { request, completion in
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

            Task {
                // Get window state to find frame
                let state = await StateManager.shared.getState()
                guard let windowState = state.windows[String(wid)] else {
                    completion(Response(id: request.id, error: ErrorInfo(code: -32001, message: "Window not found: \(wid)")))
                    return
                }

                // Calculate center of window
                let frame = windowState.frame
                let center = CGPoint(x: frame.midX, y: frame.midY)

                // Warp the mouse cursor to the center
                let result = CGWarpMouseCursorPosition(center)
                if result == .success {
                    completion(Response(id: request.id, result: AnyCodable([
                        "success": true,
                        "windowId": wid,
                        "position": ["x": center.x, "y": center.y]
                    ])))
                } else {
                    JSONLogger.shared.log("err.mouse", data: ["op": "warp", "result": result.rawValue])
                    completion(Response(id: request.id, error: ErrorInfo(code: -32000, message: "Failed to warp mouse cursor")))
                }
            }
        }

        // MARK: - Border Configuration Methods

        // Configure border settings (from CLI config)
        register(method: "borders.configure") { [weak self] request, completion in
            guard self != nil else {
                completion(Response(id: request.id, error: ErrorInfo(code: -32603, message: "Internal error")))
                return
            }
            guard let params = request.params else {
                completion(Response(id: request.id, error: ErrorInfo(code: -32602, message: "Invalid params")))
                return
            }

            guard let configDict = params["config"]?.value as? [String: Any] else {
                completion(Response(id: request.id, error: ErrorInfo(code: -32602, message: "Missing config")))
                return
            }

            // Update the shared border configuration
            BorderConfigManager.shared.update(from: configDict)
completion(Response(id: request.id, result: AnyCodable(["success": true])))
        }

        // Set cell assignments
        register(method: "borders.setCellAssignments") { [weak self] request, completion in
            guard let self = self else { return }
            guard let params = request.params else {
                completion(Response(id: request.id, error: ErrorInfo(code: -32602, message: "Invalid params")))
                return
            }

            guard let assignmentsDict = params["assignments"]?.value as? [String: String] else {
                completion(Response(id: request.id, error: ErrorInfo(code: -32602, message: "Missing assignments")))
                return
            }

            // Parse displayUUID (required for per-display caching)
            guard let displayUUID = params["displayUUID"]?.value as? String else {
                completion(Response(id: request.id, error: ErrorInfo(code: -32602, message: "Missing displayUUID")))
                return
            }

            // Convert string windowIDs to UInt32
            var cellAssignments: [UInt32: String] = [:]
            for (widStr, cellID) in assignmentsDict {
                if let wid = UInt32(widStr) {
                    cellAssignments[wid] = cellID
                }
            }

            // Parse optional focusedWindowId for atomic update (prevents race conditions)
            var focusedWindowID: UInt32?
            if let focusedInt = params["focusedWindowId"]?.value as? Int {
                focusedWindowID = UInt32(focusedInt)
            } else if let focusedStr = params["focusedWindowId"]?.value as? String,
                      let parsed = UInt32(focusedStr) {
                focusedWindowID = parsed
            }

            // Parse optional cellStackModes (cellID -> stackMode)
            let cellStackModes = params["cellStackModes"]?.value as? [String: String] ?? [:]

            // Parse optional windowOrder (cellID -> [windowID])
            var windowOrder: [String: [UInt32]]?
            if let windowOrderDict = params["windowOrder"]?.value as? [String: Any] {
                var converted: [String: [UInt32]] = [:]
                for (cellID, value) in windowOrderDict {
                    if let windowIDs = value as? [Any] {
                        let uintArray = windowIDs.compactMap { item -> UInt32? in
                            if let intVal = item as? Int {
                                return UInt32(intVal)
                            } else if let strVal = item as? String, let parsed = UInt32(strVal) {
                                return parsed
                            }
                            return nil
                        }
                        if !uintArray.isEmpty {
                            converted[cellID] = uintArray
                        }
                    }
                }
                if !converted.isEmpty {
                    windowOrder = converted
                }
            }

            // Parse optional displayFrame {x, y, width, height}
            var displayFrame: CGRect?
            if let frameDict = params["displayFrame"]?.value as? [String: Any] {
                let x = (frameDict["x"] as? Double) ?? (frameDict["x"] as? Int).map(Double.init) ?? 0
                let y = (frameDict["y"] as? Double) ?? (frameDict["y"] as? Int).map(Double.init) ?? 0
                let width = (frameDict["width"] as? Double) ?? (frameDict["width"] as? Int).map(Double.init) ?? 0
                let height = (frameDict["height"] as? Double) ?? (frameDict["height"] as? Int).map(Double.init) ?? 0
                displayFrame = CGRect(x: x, y: y, width: width, height: height)
            }

            // Update SimpleBorderManager with per-display data (and optional atomic focus)
            if let simpleBorderManager = self.simpleBorderManager {
                simpleBorderManager.setCellAssignments(cellAssignments, forDisplay: displayUUID, focusedWindowID: focusedWindowID, cellStackModes: cellStackModes, windowOrder: windowOrder, displayFrame: displayFrame)
            }
            completion(Response(id: request.id, result: AnyCodable(["success": true])))
        }

        // Debug: Cycle border through colors to test style updates
        register(method: "borders.debug") { [weak self] request, completion in
            if let simpleBorderManager = self?.simpleBorderManager {
                simpleBorderManager.debugBorders()
            }
            completion(Response(id: request.id, result: AnyCodable(["success": true])))
        }

        // Update border focus (called after window.focus)
        register(method: "borders.updateFocus") { [weak self] request, completion in
            guard let self = self else {
                completion(Response(id: request.id, error: ErrorInfo(code: -32603, message: "Internal error")))
                return
            }
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

            // displayUUID is required - CLI must tell us which display
            guard let displayUUID = params["displayUUID"]?.value as? String, !displayUUID.isEmpty else {
                completion(Response(id: request.id, error: ErrorInfo(code: -32602, message: "Missing or invalid displayUUID")))
                return
            }

            Task {
                // Check for stale focus update: if the server's current focused window
                // doesn't match the requested window, this is a stale request from a
                // delayed CLI process - ignore it to prevent race conditions
                let state = await StateManager.shared.getState()
                if let currentFocused = state.metadata.focusedWindowID, currentFocused != wid {
                    JSONLogger.shared.log("bdr.stale", data: [
                        "req": wid,
                        "cur": currentFocused
                    ])
                    completion(Response(id: request.id, result: AnyCodable(["success": true, "windowId": wid, "stale": true])))
                    return
                }

                // Update border focus using the display UUID from CLI
                if let borderManager = self.simpleBorderManager {
                    borderManager.updateFocus(newFocusedWindow: wid, displayUUID: displayUUID)
                }

                completion(Response(id: request.id, result: AnyCodable(["success": true, "windowId": wid])))
            }
        }

        // Query border info for a window
        register(method: "borders.query") { [weak self] request, completion in
            guard let self = self else {
                completion(Response(id: request.id, error: ErrorInfo(code: -32603, message: "Internal error")))
                return
            }
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

            guard let borderManager = self.simpleBorderManager else {
                completion(Response(id: request.id, error: ErrorInfo(code: -32603, message: "Border manager not available")))
                return
            }

            if let info = borderManager.queryBorderInfo(forWindowID: wid) {
                completion(Response(id: request.id, result: AnyCodable(info)))
            } else {
                completion(Response(id: request.id, result: AnyCodable([
                    "windowId": wid,
                    "hasBorder": false,
                    "message": "No border found for this window"
                ])))
            }
        }

    }
}
