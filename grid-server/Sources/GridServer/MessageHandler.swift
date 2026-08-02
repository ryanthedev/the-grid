import Foundation
import Logging
import CoreGraphics
import AppKit

// Private API for getting window ID from AXUIElement
@_silgen_name("_AXUIElementGetWindow")
private func _AXUIElementGetWindow(_ element: AXUIElement, _ windowID: UnsafeMutablePointer<UInt32>) -> AXError

/// Handles incoming requests and routes them to appropriate handlers
class MessageHandler {
    typealias RequestHandler = (Request, @escaping (Response) -> Void) -> Void

    // #49: handlers is read on the cooperative pool (handle's Task) and written
    // on the main thread (registerGridHandlers). An unsynchronized Dictionary
    // accessed concurrently is undefined behavior in Swift. Guard every access
    // with this serial queue. `ready` flips true once full registration
    // completes, so a grid.* request arriving in the startup window gets a
    // retryable error instead of a spurious -32601.
    private let handlersQueue = DispatchQueue(label: "com.thegrid.msg.handlers")
    private var handlers: [String: RequestHandler] = [:]
    private var ready = false

    /// Simple border manager for handling simplified border system
    weak var simpleBorderManager: SimpleBorderManager?

    init(logger: Logger? = nil) {
        registerBuiltInHandlers()
    }

    /// Register a handler for a specific method
    func register(method: String, handler: @escaping RequestHandler) {
        handlersQueue.sync {
            handlers[method] = handler
        }
        Task {
            JSONLogger.shared.log("msg.register", data: ["method": method])
        }
    }

    /// Mark registration complete. Called after registerGridHandlers wires every
    /// grid.* method, so the startup 404 window is closed (#49).
    func finalizeRegistration() {
        handlersQueue.sync {
            ready = true
        }
        Task {
            JSONLogger.shared.log("msg.ready", data: ["methods": self.handlerCount()])
        }
    }

    /// Snapshot of the registered method count (test/log helper).
    func handlerCount() -> Int {
        return handlersQueue.sync { handlers.count }
    }

    /// Whether full registration has completed.
    func isReady() -> Bool {
        return handlersQueue.sync { ready }
    }

    /// Thread-safe lookup. Returns (handler, ready) atomically so the caller can
    /// distinguish "unknown method" from "not registered yet".
    private func lookup(_ method: String) -> (handler: RequestHandler?, ready: Bool) {
        return handlersQueue.sync { (handlers[method], ready) }
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

                let (maybeHandler, ready) = self.lookup(request.method)
                guard let handler = maybeHandler else {
                    // #49: a grid.* method that is unknown ONLY because full
                    // registration has not finished yet is a transient startup
                    // condition, not a permanent "method not found". Surface a
                    // retryable error so a client retry loop succeeds once ready.
                    let stillStarting = !ready && request.method.hasPrefix("grid.")
                    let response = Response(
                        id: request.id,
                        error: ErrorInfo(
                            code: stillStarting ? -32000 : -32601,
                            message: stillStarting
                                ? "Server initializing, retry"
                                : "Method not found: \(request.method)"
                        )
                    )

                    JSONLogger.shared.log("msg.err", data: [
                        "op": stillStarting ? "not_ready" : "method_not_found",
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

        // window.find - searches state.windows by criteria, returns immediately.
        // Accepts: pid (Int), appName (String), title (String). pid branch is mutually
        // exclusive — walks ancestor chain to find the window that owns the process.
        register(method: "window.find") { request, completion in
            guard let params = request.params else {
                completion(Response(id: request.id, error: ErrorInfo(code: -32602, message: "Invalid params")))
                return
            }

            let appNameFilter = params["appName"]?.value as? String
            let titleFilter = params["title"]?.value as? String
            let pidFilter = params["pid"]?.value as? Int

            guard appNameFilter != nil || titleFilter != nil || pidFilter != nil else {
                completion(Response(id: request.id, error: ErrorInfo(code: -32602, message: "At least one of appName, title, or pid required")))
                return
            }

            Task {
                let state = await StateManager.shared.getState()

                // pid branch: walk ancestor chain, return first window whose PID is an ancestor
                if let pidFilter {
                    let tree = await ProcessTree.build()
                    let ancestors = tree.getAncestors(of: pid_t(pidFilter), maxDepth: 8)
                    // Include the PID itself — handles case where process directly owns a window
                    let ancestorSet = Set([pid_t(pidFilter)] + ancestors)

                    for window in state.windows.values {
                        if window.isHidden { continue }
                        if window.frame.height < 100 { continue }
                        // Skip phantoms (Chrome helper AX elements report nil role)
                        if window.role != "AXWindow" { continue }
                        if ancestorSet.contains(window.pid) {
                            completion(Response(id: request.id, result: AnyCodable([
                                "found": true,
                                "windowId": String(window.id),
                                "pid": window.pid
                            ])))
                            return
                        }
                    }

                    completion(Response(id: request.id, result: AnyCodable(["found": false])))
                    return
                }

                // appName/title branch: filter by name and/or title substring
                for window in state.windows.values {
                    if let appName = appNameFilter, window.appName != appName { continue }
                    if let title = titleFilter, !(window.title?.contains(title) ?? false) { continue }
                    if window.isHidden { continue }
                    if window.frame.height < 100 { continue }
                    // Skip phantoms (Chrome helper AX elements report nil role)
                    if window.role != "AXWindow" { continue }

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

        // Hide window (hides the owning app process via NSRunningApplication)
        register(method: "window.hide") { request, completion in
            guard let params = request.params else {
                completion(Response(id: request.id, error: ErrorInfo(code: -32602, message: "Invalid params")))
                return
            }

            guard let windowId = params["windowId"]?.value as? String,
                  UInt32(windowId) != nil else {
                completion(Response(id: request.id, error: ErrorInfo(code: -32602, message: "Missing windowId")))
                return
            }

            Task {
                let state = await StateManager.shared.getState()

                // Hide via NSRunningApplication (hides entire app process).
                // The MSS orderWindowOut attempt that used to run first is gone;
                // it required SIP off and never completed a handshake, so this
                // path already handled every call.
                if let windowState = state.windows[windowId],
                   let app = NSRunningApplication(processIdentifier: windowState.pid) {
                    app.hide()
                    completion(Response(id: request.id, result: AnyCodable(["success": true, "windowId": windowId])))
                } else {
                    completion(Response(id: request.id, error: ErrorInfo(code: -32000, message: "Failed to hide window")))
                }
            }
        }

        // Show window (unhide + activate the owning app via NSRunningApplication)
        register(method: "window.show") { request, completion in
            guard let params = request.params else {
                completion(Response(id: request.id, error: ErrorInfo(code: -32602, message: "Invalid params")))
                return
            }

            guard let windowId = params["windowId"]?.value as? String,
                  UInt32(windowId) != nil else {
                completion(Response(id: request.id, error: ErrorInfo(code: -32602, message: "Missing windowId")))
                return
            }

            Task {
                let state = await StateManager.shared.getState()

                // Unhide + activate via NSRunningApplication. The MSS
                // order-to-front/focus attempt that used to run first is gone;
                // it required SIP off and never completed a handshake, so this
                // path already handled every call.
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

        // MARK: - Window Minimize Methods (Accessibility)

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
                    completion(Response(id: request.id, error: ErrorInfo(code: -32000, message: "Failed to minimize window")))
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
                    completion(Response(id: request.id, error: ErrorInfo(code: -32000, message: "Failed to unminimize window")))
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

                guard let pid = state.windows[windowId]?.pid else {
                    completion(Response(id: request.id, error: ErrorInfo(code: -32000, message: "Unknown window")))
                    return
                }

                if let minimized = manipulator.isWindowMinimized(pid: pid, windowID: windowID) {
                    completion(Response(id: request.id, result: AnyCodable(["windowId": windowId, "minimized": minimized])))
                } else {
                    completion(Response(id: request.id, error: ErrorInfo(code: -32000, message: "Failed to get window minimized status")))
                }
            }
        }

        // Close window via AX close button
        register(method: "window.close") { request, completion in
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
                guard let context = await ManipulationContext.from(windowID: windowID) else {
                    completion(Response(id: request.id, error: ErrorInfo(code: -32001, message: "Window not found: \(windowID)")))
                    return
                }

                let requestID = UUID().uuidString
                await EventRouter.shared.route(
                    .commandCloseWindow(windowID: windowID, requestID: requestID),
                    from: .manual(reason: "cli")
                )

                // Get AXUIElement for the window and press close button
                let appElement = AXUIElementCreateApplication(context.pid)
                var windowsRef: CFTypeRef?
                guard AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowsRef) == .success,
                      let axWindows = windowsRef as? [AXUIElement] else {
                    completion(Response(id: request.id, error: ErrorInfo(code: -32000, message: "Failed to get windows")))
                    return
                }

                // Find the matching window by CGWindowID
                for axWindow in axWindows {
                    var cgID: UInt32 = 0
                    if _AXUIElementGetWindow(axWindow, &cgID) == .success, cgID == windowID {
                        var closeButtonRef: CFTypeRef?
                        if AXUIElementCopyAttributeValue(axWindow, kAXCloseButtonAttribute as CFString, &closeButtonRef) == .success,
                           let closeButton = closeButtonRef {
                            let result = AXUIElementPerformAction(closeButton as! AXUIElement, kAXPressAction as CFString)
                            if result == .success {
                                completion(Response(id: request.id, result: AnyCodable(["success": true, "windowId": windowId])))
                            } else {
                                completion(Response(id: request.id, error: ErrorInfo(code: -32000, message: "Failed to press close button")))
                            }
                        } else {
                            completion(Response(id: request.id, error: ErrorInfo(code: -32000, message: "Window has no close button")))
                        }
                        return
                    }
                }

                completion(Response(id: request.id, error: ErrorInfo(code: -32001, message: "AX window not found: \(windowID)")))
            }
        }

        // MARK: - Window Focus Methods

        // Raise window to front without changing keyboard focus
        register(method: "window.raise") { request, completion in
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
                guard let pid = state.windows[windowId]?.pid else {
                    completion(Response(id: request.id, error: ErrorInfo(code: -32000, message: "Unknown window")))
                    return
                }

                if manipulator.raiseWindow(pid: pid, windowID: windowID) {
                    completion(Response(id: request.id, result: AnyCodable(["success": true, "windowId": windowId])))
                } else {
                    completion(Response(id: request.id, error: ErrorInfo(code: -32000, message: "Failed to raise window")))
                }
            }
        }

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
                simpleBorderManager.setCellAssignments(cellAssignments, forDisplay: displayUUID, focusedWindowID: focusedWindowID, cellStackModes: cellStackModes, windowOrder: windowOrder, displayFrame: displayFrame, source: "rpc")
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
                    await borderManager.updateFocus(newFocusedWindow: wid, displayUUID: displayUUID)
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

            // queryBorderInfo is now async (finding #55 fix: no more DispatchQueue.main.sync).
            // Await it inside a Task so the completion-based handler is not blocked.
            Task {
                if let info = await borderManager.queryBorderInfo(forWindowID: wid) {
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

        // MARK: - Picker

        // pick.show - trigger the picker UI and wait for user selection
        register(method: "pick.show") { request, completion in
            Task { @MainActor in
                let result = await PickerManager.shared.showForRPC()

                let response: Response
                switch result {
                case .selected(let item):
                    var selected: [String: Any] = [
                        "id": item.id,
                        "title": item.title
                    ]
                    if let subtitle = item.subtitle {
                        selected["subtitle"] = subtitle
                    }
                    if let metadata = item.metadata {
                        selected["metadata"] = metadata
                    }
                    response = Response(
                        id: request.id,
                        result: AnyCodable([
                            "cancelled": false,
                            "selected": selected
                        ])
                    )
                case .cancelled:
                    response = Response(
                        id: request.id,
                        result: AnyCodable([
                            "cancelled": true
                        ])
                    )
                }
                completion(response)
            }
        }

    }

    // MARK: - Grid RPC Handlers

    func registerGridHandlers(
        router: GridCommandRouter,
        executor: CommandExecutor,
        gridState: GridState,
        gridConfig: GridConfig,
        stateManager: StateManager
    ) {
        // Helper: dispatch a command string through the serial CommandExecutor and respond.
        // All command ingress funnels through executor.submit so one command body runs
        // end-to-end at a time (Phase 1 serialization seam) instead of a Task-per-request.
        func dispatchAndRespond(
            _ request: Request,
            commandString: String,
            completion: @escaping (Response) -> Void
        ) {
            Task {
                jlog("grid.rpc.dispatch", data: ["method": request.method, "cmd": commandString])
                let result = await executor.submit(commandString)
                if result.success {
                    completion(Response(
                        id: request.id,
                        result: AnyCodable(["ok": true, "message": result.message])
                    ))
                } else {
                    completion(Response(
                        id: request.id,
                        error: ErrorInfo(code: -32000, message: result.message)
                    ))
                }
            }
        }

        // Helper: build command string from RPC params
        func buildCommand(domain: String, action: String = "", params: [String: AnyCodable]?) -> String {
            var parts = ["@\(domain)"]
            if !action.isEmpty {
                parts.append(action)
            }

            guard let params = params else {
                return parts.joined(separator: " ")
            }

            // Positional args
            if let direction = params["direction"]?.value as? String {
                parts.append(direction)
            }
            if let layout = params["layout"]?.value as? String {
                parts.append(layout)
            }
            if let cell = params["cell"]?.value as? String {
                parts.append(cell)
            }
            if let mode = params["mode"]?.value as? String {
                parts.append(mode)
            }

            // Amount (for resize)
            if let amount = params["amount"]?.value as? Double {
                parts.append(String(amount))
            } else if let amount = params["amount"]?.value as? Int {
                parts.append(String(amount))
            }

            // Boolean flags
            let boolFlags = ["wrap", "extend", "mouse", "cell", "all"]
            for flag in boolFlags {
                if let val = params[flag]?.value as? Bool, val {
                    parts.append("--\(flag)")
                }
            }

            // Value flags
            let valueFlags = ["strategy", "space", "display", "direction"]
            for flag in valueFlags {
                // Skip "direction" if already used as positional
                if flag == "direction" { continue }
                if let val = params[flag]?.value as? String {
                    parts.append("--\(flag)")
                    parts.append(val)
                }
            }

            // #22: forward @notify payload params as value flags so handleNotify
            // (and the GridNotify app via userInfo) receive title/body/etc. These
            // were silently dropped before, collapsing push/dismiss to a toggle.
            if domain == "notify" {
                let purge = (params["purge"]?.value as? Bool) ?? false
                parts.append(contentsOf: NotifyActionPolicy.payloadFlags(
                    lookup: { params[$0]?.value as? String },
                    purge: purge
                ))
            }

            // Strategy and space as value flags (notify never uses these).
            if domain != "notify" {
                if let strategy = params["strategy"]?.value as? String {
                    parts.append("--strategy")
                    parts.append(strategy)
                }
                if let space = params["space"]?.value as? String {
                    parts.append("--space")
                    parts.append(space)
                }
                if let display = params["display"]?.value as? String {
                    parts.append("--display")
                    parts.append(display)
                }
            }

            return parts.joined(separator: " ")
        }

        // ============================================================
        // ACTION RPCs -- delegate to router.dispatch()
        // ============================================================

        // grid.focus -- { direction: "left"|"right"|"up"|"down", wrap?: bool, extend?: bool, mouse?: bool }
        register(method: "grid.focus") { request, completion in
            guard let direction = request.params?["direction"]?.value as? String, !direction.isEmpty else {
                completion(Response(id: request.id, error: ErrorInfo(code: -32602, message: "missing required param: direction")))
                return
            }
            let cmd = buildCommand(domain: "focus", action: direction, params: request.params)
            dispatchAndRespond(request, commandString: cmd, completion: completion)
        }

        // grid.focus.cycle -- { forward?: bool }
        register(method: "grid.focus.cycle") { request, completion in
            let forward = request.params?["forward"]?.value as? Bool ?? true
            let action = forward ? "next" : "prev"
            let cmd = buildCommand(domain: "focus", action: action, params: nil)
            dispatchAndRespond(request, commandString: cmd, completion: completion)
        }

        // grid.focus.cell -- { cell: string, space?: string }
        register(method: "grid.focus.cell") { request, completion in
            guard let cellID = request.params?["cell"]?.value as? String, !cellID.isEmpty else {
                completion(Response(id: request.id, error: ErrorInfo(code: -32602, message: "missing required param: cell")))
                return
            }
            var cmd = "@focus cell \(cellID)"
            if let space = request.params?["space"]?.value as? String, !space.isEmpty {
                cmd += " --space \(space)"
            }
            dispatchAndRespond(request, commandString: cmd, completion: completion)
        }

        // grid.layout.apply -- { layout: string, strategy?: string }
        register(method: "grid.layout.apply") { request, completion in
            guard let layoutID = request.params?["layout"]?.value as? String, !layoutID.isEmpty else {
                completion(Response(id: request.id, error: ErrorInfo(code: -32602, message: "missing required param: layout")))
                return
            }
            var cmd = "@layout apply \(layoutID)"
            if let strategy = request.params?["strategy"]?.value as? String, !strategy.isEmpty {
                cmd += " --strategy \(strategy)"
            }
            dispatchAndRespond(request, commandString: cmd, completion: completion)
        }

        // grid.layout.refresh -- { display?: string }
        register(method: "grid.layout.refresh") { request, completion in
            var cmd = "@layout refresh"
            if let display = request.params?["display"]?.value as? String, !display.isEmpty {
                cmd += " --display \(display)"
            }
            dispatchAndRespond(request, commandString: cmd, completion: completion)
        }

        // grid.layout.cycle -- {}
        register(method: "grid.layout.cycle") { request, completion in
            let cmd = "@layout cycle"
            dispatchAndRespond(request, commandString: cmd, completion: completion)
        }

        // grid.cell.send -- { direction: string }
        register(method: "grid.cell.send") { request, completion in
            guard let direction = request.params?["direction"]?.value as? String, !direction.isEmpty else {
                completion(Response(id: request.id, error: ErrorInfo(code: -32602, message: "missing required param: direction")))
                return
            }
            let cmd = "@cell send \(direction)"
            dispatchAndRespond(request, commandString: cmd, completion: completion)
        }

        // grid.cell.mode -- { mode?: string }
        register(method: "grid.cell.mode") { request, completion in
            var cmd = "@cell mode"
            if let mode = request.params?["mode"]?.value as? String, !mode.isEmpty {
                cmd += " \(mode)"
            }
            dispatchAndRespond(request, commandString: cmd, completion: completion)
        }

        // grid.window.move -- { direction: string, wrap?: bool, extend?: bool }
        register(method: "grid.window.move") { request, completion in
            guard let direction = request.params?["direction"]?.value as? String, !direction.isEmpty else {
                completion(Response(id: request.id, error: ErrorInfo(code: -32602, message: "missing required param: direction")))
                return
            }
            var cmd = "@window move \(direction)"
            if let wrap = request.params?["wrap"]?.value as? Bool, wrap {
                cmd += " --wrap"
            }
            if let extend = request.params?["extend"]?.value as? Bool, extend {
                cmd += " --extend"
            }
            dispatchAndRespond(request, commandString: cmd, completion: completion)
        }

        // grid.window.swap -- { direction: string }
        register(method: "grid.window.swap") { request, completion in
            guard let direction = request.params?["direction"]?.value as? String, !direction.isEmpty else {
                completion(Response(id: request.id, error: ErrorInfo(code: -32602, message: "missing required param: direction")))
                return
            }
            let cmd = "@cell swap \(direction)"
            dispatchAndRespond(request, commandString: cmd, completion: completion)
        }

        // grid.resize.adjust -- { delta: double, cell?: bool, direction?: string }
        register(method: "grid.resize.adjust") { request, completion in
            var delta: Double = 0
            if let d = request.params?["delta"]?.value as? Double {
                delta = d
            } else if let d = request.params?["delta"]?.value as? Int {
                delta = Double(d)
            } else {
                completion(Response(id: request.id, error: ErrorInfo(code: -32602, message: "missing required param: delta")))
                return
            }
            let action = delta >= 0 ? "grow" : "shrink"
            let amount = abs(delta)
            var cmd = "@resize \(action) \(amount)"
            if let cell = request.params?["cell"]?.value as? Bool, cell {
                cmd += " --cell"
            }
            if let dir = request.params?["direction"]?.value as? String, !dir.isEmpty {
                cmd += " --direction \(dir)"
            }
            dispatchAndRespond(request, commandString: cmd, completion: completion)
        }

        // grid.resize.cell -- { direction: string, delta: double }
        register(method: "grid.resize.cell") { request, completion in
            guard let direction = request.params?["direction"]?.value as? String, !direction.isEmpty else {
                completion(Response(id: request.id, error: ErrorInfo(code: -32602, message: "missing required param: direction")))
                return
            }
            var delta: Double = 0
            if let d = request.params?["delta"]?.value as? Double {
                delta = d
            } else if let d = request.params?["delta"]?.value as? Int {
                delta = Double(d)
            } else {
                completion(Response(id: request.id, error: ErrorInfo(code: -32602, message: "missing required param: delta")))
                return
            }
            let action = delta >= 0 ? "grow" : "shrink"
            let amount = abs(delta)
            let cmd = "@resize \(action) \(amount) --cell --direction \(direction)"
            dispatchAndRespond(request, commandString: cmd, completion: completion)
        }

        // grid.resize.reset -- { cell?: bool, all?: bool }
        register(method: "grid.resize.reset") { request, completion in
            var cmd = "@resize reset"
            if let cell = request.params?["cell"]?.value as? Bool, cell {
                cmd += " --cell"
            }
            if let all = request.params?["all"]?.value as? Bool, all {
                cmd += " --all"
            }
            dispatchAndRespond(request, commandString: cmd, completion: completion)
        }

        // grid.state.reset -- {}
        register(method: "grid.state.reset") { request, completion in
            let cmd = "@state reset"
            dispatchAndRespond(request, commandString: cmd, completion: completion)
        }

        // ============================================================
        // QUERY RPCs -- call modules directly for structured responses
        // ============================================================

        // grid.layout.current -- {} -> { layout: string, space: string }
        register(method: "grid.layout.current") { request, completion in
            Task {
                let wmState = await stateManager.getState()
                // Use metadata.activeSpaceID for the focused display's space
                var spaceID = ""
                if let activeSpaceID = wmState.metadata.activeSpaceID {
                    spaceID = String(activeSpaceID)
                } else {
                    // Fallback: first display with a non-zero space
                    for display in wmState.displays {
                        if display.currentSpaceID != 0 {
                            spaceID = String(display.currentSpaceID)
                            break
                        }
                    }
                }
                let currentLayoutID = await gridState.getCurrentLayout(spaceID: spaceID)
                completion(Response(
                    id: request.id,
                    result: AnyCodable(["layout": currentLayoutID, "space": spaceID])
                ))
            }
        }

        // grid.layout.list -- {} -> { layouts: [string] }
        register(method: "grid.layout.list") { request, completion in
            Task { @MainActor in
                let layoutIDs = gridConfig.getLayoutIDs()
                completion(Response(
                    id: request.id,
                    result: AnyCodable(["layouts": layoutIDs])
                ))
            }
        }

        // grid.layout.get -- { layout: string } -> { layout: <layout def as JSON> }
        register(method: "grid.layout.get") { request, completion in
            guard let layoutID = request.params?["layout"]?.value as? String, !layoutID.isEmpty else {
                completion(Response(id: request.id, error: ErrorInfo(code: -32602, message: "missing required param: layout")))
                return
            }
            Task { @MainActor in
                do {
                    let layoutDef = try gridConfig.getLayout(id: layoutID)
                    let dict = layoutDefToDict(layoutDef)
                    completion(Response(
                        id: request.id,
                        result: AnyCodable(["layout": dict])
                    ))
                } catch {
                    completion(Response(
                        id: request.id,
                        error: ErrorInfo(code: -32000, message: "layout not found: \(layoutID)")
                    ))
                }
            }
        }

        // grid.layout.update -- stub
        register(method: "grid.layout.update") { request, completion in
            completion(Response(
                id: request.id,
                error: ErrorInfo(code: -32000, message: "not yet implemented")
            ))
        }

        // grid.layout.save -- stub
        register(method: "grid.layout.save") { request, completion in
            completion(Response(
                id: request.id,
                error: ErrorInfo(code: -32000, message: "not yet implemented")
            ))
        }

        // grid.state.show -- {} -> { state: <full grid state JSON> }
        register(method: "grid.state.show") { request, completion in
            Task {
                let stateData = await gridState.exportState()
                do {
                    let encoder = JSONEncoder()
                    encoder.outputFormatting = [.sortedKeys]
                    let jsonData = try encoder.encode(stateData)
                    if let dict = try JSONSerialization.jsonObject(with: jsonData) as? [String: Any] {
                        completion(Response(
                            id: request.id,
                            result: AnyCodable(["state": dict])
                        ))
                    } else {
                        completion(Response(
                            id: request.id,
                            error: ErrorInfo(code: -32000, message: "failed to serialize state")
                        ))
                    }
                } catch {
                    completion(Response(
                        id: request.id,
                        error: ErrorInfo(code: -32000, message: "failed to encode state: \(error)")
                    ))
                }
            }
        }

        // grid.config.show -- {} -> { config: <summary> }
        register(method: "grid.config.show") { request, completion in
            Task { @MainActor in
                let summary = gridConfig.exportSummary()
                completion(Response(
                    id: request.id,
                    result: AnyCodable(["config": summary])
                ))
            }
        }

        // grid.record.start -- record screen capture via command router
        register(method: "grid.record.start") { request, completion in
            Task {
                do {
                    // Parse target from params
                    let targetStr = request.params?["target"]?.value as? String ?? "cell"
                    let idStr = request.params?["id"]?.value as? String

                    // Build @ command string for the router
                    var parts = ["@record", "start", targetStr]
                    if let id = idStr {
                        parts.append(id)
                    }

                    // Map RPC params to --flags
                    let intFlags = ["duration", "fps", "width", "countdown"]
                    for flag in intFlags {
                        if let val = request.params?[flag]?.value as? Int, val != 0 || flag == "countdown" {
                            parts.append("--\(flag)")
                            parts.append(String(val))
                        }
                    }
                    let strFlags = ["format", "quality", "output"]
                    for flag in strFlags {
                        if let val = request.params?[flag]?.value as? String, !val.isEmpty {
                            parts.append("--\(flag)")
                            parts.append(val)
                        }
                    }
                    let boolFlags = ["cursor", "open", "follow"]
                    for flag in boolFlags {
                        if let val = request.params?[flag]?.value as? Bool, val {
                            parts.append("--\(flag)")
                        }
                    }

                    let cmd = parts.joined(separator: " ")
                    jlog("grid.rpc.record", data: ["cmd": cmd])
                    let cmdResult = await executor.submit(cmd)

                    if cmdResult.success {
                        // The message is JSON from the recorder, parse it back
                        if let data = cmdResult.message.data(using: .utf8),
                           let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                            completion(Response(id: request.id, result: AnyCodable(dict)))
                        } else {
                            completion(Response(
                                id: request.id,
                                result: AnyCodable(["ok": true, "message": cmdResult.message])
                            ))
                        }
                    } else {
                        completion(Response(
                            id: request.id,
                            error: ErrorInfo(code: -32000, message: cmdResult.message)
                        ))
                    }
                }
            }
        }

        // grid.record.stop -- stop whatever recording is active, return RecordingResult JSON
        register(method: "grid.record.stop") { request, completion in
            Task {
                let cmdResult = await executor.submit("@record stop")
                if cmdResult.success {
                    if let data = cmdResult.message.data(using: .utf8),
                       let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                        completion(Response(id: request.id, result: AnyCodable(dict)))
                    } else {
                        completion(Response(
                            id: request.id,
                            result: AnyCodable(["ok": true, "message": cmdResult.message])
                        ))
                    }
                } else {
                    completion(Response(
                        id: request.id,
                        error: ErrorInfo(code: -32000, message: cmdResult.message)
                    ))
                }
            }
        }

        // grid.record.toggle -- start if idle, stop if recording; same params as grid.record.start
        register(method: "grid.record.toggle") { request, completion in
            Task {
                let targetStr = request.params?["target"]?.value as? String ?? "cell"
                let idStr = request.params?["id"]?.value as? String

                var parts = ["@record", "toggle", targetStr]
                if let id = idStr {
                    parts.append(id)
                }

                let intFlags = ["duration", "fps", "width", "countdown"]
                for flag in intFlags {
                    if let val = request.params?[flag]?.value as? Int, val != 0 || flag == "countdown" {
                        parts.append("--\(flag)")
                        parts.append(String(val))
                    }
                }
                let strFlags = ["format", "quality", "output"]
                for flag in strFlags {
                    if let val = request.params?[flag]?.value as? String, !val.isEmpty {
                        parts.append("--\(flag)")
                        parts.append(val)
                    }
                }
                let boolFlags = ["cursor", "open", "follow"]
                for flag in boolFlags {
                    if let val = request.params?[flag]?.value as? Bool, val {
                        parts.append("--\(flag)")
                    }
                }

                let cmd = parts.joined(separator: " ")
                jlog("grid.rpc.record.toggle", data: ["cmd": cmd])
                let cmdResult = await executor.submit(cmd)

                if cmdResult.success {
                    if let data = cmdResult.message.data(using: .utf8),
                       let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                        completion(Response(id: request.id, result: AnyCodable(dict)))
                    } else {
                        completion(Response(
                            id: request.id,
                            result: AnyCodable(["ok": true, "message": cmdResult.message])
                        ))
                    }
                } else {
                    completion(Response(
                        id: request.id,
                        error: ErrorInfo(code: -32000, message: cmdResult.message)
                    ))
                }
            }
        }

        // grid.terminal -- {}
        register(method: "grid.terminal") { request, completion in
            let cmd = "@terminal"
            dispatchAndRespond(request, commandString: cmd, completion: completion)
        }

        // grid.notify.show -- { cell?: string }
        register(method: "grid.notify.show") { request, completion in
            let cmd = buildCommand(domain: "notify", action: "show", params: request.params)
            dispatchAndRespond(request, commandString: cmd, completion: completion)
        }

        // grid.notify.hide -- {}
        register(method: "grid.notify.hide") { request, completion in
            dispatchAndRespond(request, commandString: "@notify hide", completion: completion)
        }

        // grid.notify.toggle -- { cell?: string }
        register(method: "grid.notify.toggle") { request, completion in
            let cmd = buildCommand(domain: "notify", action: "toggle", params: request.params)
            dispatchAndRespond(request, commandString: cmd, completion: completion)
        }

        // grid.notify.push -- { title, body?, priority?, source?, action? }
        register(method: "grid.notify.push") { request, completion in
            let cmd = buildCommand(domain: "notify", action: "push", params: request.params)
            dispatchAndRespond(request, commandString: cmd, completion: completion)
        }

        // grid.notify.list -- { source?, priority?, all? }
        register(method: "grid.notify.list") { request, completion in
            let cmd = buildCommand(domain: "notify", action: "list", params: request.params)
            dispatchAndRespond(request, commandString: cmd, completion: completion)
        }

        // grid.notify.dismiss -- { id }
        register(method: "grid.notify.dismiss") { request, completion in
            let cmd = buildCommand(domain: "notify", action: "dismiss", params: request.params)
            dispatchAndRespond(request, commandString: cmd, completion: completion)
        }

        // grid.notify.clear -- { purge? }
        register(method: "grid.notify.clear") { request, completion in
            let cmd = buildCommand(domain: "notify", action: "clear", params: request.params)
            dispatchAndRespond(request, commandString: cmd, completion: completion)
        }

        // grid.notify.count -- {}
        register(method: "grid.notify.count") { request, completion in
            dispatchAndRespond(request, commandString: "@notify count", completion: completion)
        }

        // grid.notify.assign -- { cell }
        register(method: "grid.notify.assign") { request, completion in
            let cmd = buildCommand(domain: "notify", action: "assign", params: request.params)
            dispatchAndRespond(request, commandString: cmd, completion: completion)
        }

        // grid.notify.unassign -- {}
        register(method: "grid.notify.unassign") { request, completion in
            dispatchAndRespond(request, commandString: "@notify unassign", completion: completion)
        }

        jlog("grid.rpc.registered")
    }
}

// MARK: - Layout Def Serialization Helper

private func layoutDefToDict(_ layout: GridLayoutDef) -> [String: Any] {
    var columns: [[String: Any]] = []
    for col in layout.columns {
        columns.append(trackSizeToDict(col))
    }
    var rows: [[String: Any]] = []
    for row in layout.rows {
        rows.append(trackSizeToDict(row))
    }

    var cells: [[String: Any]] = []
    for cell in layout.cells {
        var cellDict: [String: Any] = [
            "id": cell.id,
            "columnStart": cell.columnStart,
            "columnEnd": cell.columnEnd,
            "rowStart": cell.rowStart,
            "rowEnd": cell.rowEnd,
        ]
        if let mode = cell.stackMode {
            cellDict["stackMode"] = mode.rawValue
        }
        cells.append(cellDict)
    }

    var cellModes: [String: String] = [:]
    for (k, v) in layout.cellModes {
        cellModes[k] = v.rawValue
    }

    var dict: [String: Any] = [
        "id": layout.id,
        "name": layout.name,
        "description": layout.description,
        "grid": ["columns": columns, "rows": rows],
        "cells": cells,
        "cellModes": cellModes,
    ]

    if let padding = layout.padding {
        dict["padding"] = [
            "top": paddingValueToDict(padding.top),
            "right": paddingValueToDict(padding.right),
            "bottom": paddingValueToDict(padding.bottom),
            "left": paddingValueToDict(padding.left),
        ]
    }

    if let ws = layout.windowSpacing {
        dict["windowSpacing"] = paddingValueToDict(ws)
    }

    return dict
}

private func trackSizeToDict(_ ts: GridTrackSize) -> [String: Any] {
    switch ts.type {
    case .fr:
        return ["type": "fr", "value": ts.value]
    case .px:
        return ["type": "px", "value": ts.value]
    case .auto:
        return ["type": "auto"]
    case .minmax:
        return ["type": "minmax", "min": ts.min, "max": ts.max]
    }
}

private func paddingValueToDict(_ pv: GridPaddingValue) -> [String: Any] {
    if pv.isRelative {
        return ["baseMultiple": pv.baseMultiple, "isRelative": true]
    }
    return ["pixels": pv.pixels]
}
