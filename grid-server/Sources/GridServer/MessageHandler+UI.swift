//
// MessageHandler+UI.swift
// GridServer
//
// ui.* RPC methods: read a window's accessibility tree and act on its nodes
// by ref, so an agent can operate an app without reading pixels.
//

import ApplicationServices
import CoreGraphics
import Foundation

extension MessageHandler {

    func registerUIHandlers() {
        // window.at -- { x, y } -> the window a click at that point would reach
        register(method: "window.at") { request, completion in
            guard let x = Self.number(request.params, "x"), let y = Self.number(request.params, "y") else {
                completion(Response(id: request.id, error: ErrorInfo(code: -32602, message: "x and y are required")))
                return
            }
            guard let top = WindowHitTest.top(at: CGPoint(x: x, y: y), in: WindowHitTest.onScreenWindows()) else {
                completion(Response(id: request.id, result: AnyCodable(["found": false])))
                return
            }
            completion(Response(id: request.id, result: AnyCodable([
                "found": true, "windowId": String(top.windowID), "pid": Int(top.pid), "appName": top.ownerName, "layer": top.layer,
            ])))
        }

        // ui.snapshot -- { windowId | ref, [maxDepth], [maxNodes] } -> { windowId, count, outline, [truncated] }
        for method in ["ui.snapshot", "ui.query"] {
        register(method: method) { request, completion in
            let params = request.params
            let ref = Self.string(params, "ref")
            // A ref carries its window: "<windowId>:<n>".
            let refWindow = ref.flatMap { UInt32($0.split(separator: ":").first ?? "") }
            guard let wid = Self.windowID(params) ?? refWindow else {
                completion(Response(id: request.id, error: ErrorInfo(code: -32602, message: "windowId or ref is required")))
                return
            }
            if let ref, refWindow != wid {
                completion(Response(id: request.id, error: ErrorInfo(code: -32602, message: "ref '\(ref)' does not belong to window \(wid)")))
                return
            }
            var limits = UIAutomation.Limits()
            if let depth = Self.int(params, "maxDepth"), depth > 0 { limits.maxDepth = depth }
            if let nodes = Self.int(params, "maxNodes"), nodes > 0 { limits.maxNodes = min(nodes, 2000) }
            limits.includeOffscreen = params?["includeOffscreen"]?.value as? Bool ?? false
            // ui.query is ui.snapshot with a predicate: same walk, same refs, only the matches come back.
            if request.method == "ui.query" {
                var query = UIQuery()
                query.role = Self.string(params, "role")
                query.text = Self.string(params, "text")
                query.pressable = params?["pressable"]?.value as? Bool
                if let limit = Self.int(params, "limit"), limit > 0 { query.limit = min(limit, 200) }
                guard query.role != nil || query.text != nil || query.pressable != nil else {
                    completion(Response(id: request.id, error: ErrorInfo(code: -32602, message: "give at least one of role, text, pressable")))
                    return
                }
                limits.query = query
                // Searching is the point: look everywhere unless told otherwise.
                if params?["includeOffscreen"] == nil { limits.includeOffscreen = true }
                if Self.int(params, "maxNodes") == nil { limits.maxNodes = 2000 }
            }

            Task {
                guard let context = await ManipulationContext.from(windowID: wid) else {
                    completion(Response(id: request.id, error: ErrorInfo(code: -32001, message: "Window not found: \(wid)")))
                    return
                }
                // AX against our own pid runs in-place and trips AppKit's main-thread assertion.
                guard context.pid != ProcessInfo.processInfo.processIdentifier else {
                    completion(Response(id: request.id, error: ErrorInfo(code: -32000, message: "window \(wid) belongs to the grid server and cannot be snapshotted")))
                    return
                }
                let connectionID = await StateManager.shared.getState().metadata.connectionID
                Self.onUIQueue(request, completion) {
                    let ui = UIAutomation.shared
                    // Electron builds its tree only once asked; harmless elsewhere.
                    AXUIElementSetAttributeValue(makeAppElement(pid: context.pid), "AXManualAccessibility" as CFString, kCFBooleanTrue)
                    if let ref {
                        return ui.snapshot(windowID: wid, root: try ui.element(for: ref), subtree: true, limits: limits)
                    }
                    guard let window = WindowManipulator(connectionID: connectionID).getAXElement(pid: context.pid, windowID: wid) else {
                        throw UIError.unreachable(wid)
                    }
                    // getAXElement may hand back an app's sole window for a phantom ID; say so.
                    // Resolved before the walk, while the app is known to be answering.
                    let resolved = UIAutomation.windowID(of: window)
                    var result = ui.snapshot(windowID: wid, root: window, subtree: false, limits: limits)
                    if resolved != wid {
                        result["resolvedWindowId"] = resolved.map { Int($0) } ?? NSNull()
                    }
                    return result
                }
            }
        }
        }

        // ui.press -- { ref } -> AXPress on the element; needs neither focus nor the cursor
        register(method: "ui.press") { request, completion in
            guard let ref = Self.string(request.params, "ref") else {
                completion(Response(id: request.id, error: ErrorInfo(code: -32602, message: "ref is required")))
                return
            }
            Self.onUIQueue(request, completion) {
                return ["pressed": ref, "via": try UIAutomation.shared.press(ref)]
            }
        }

        // ui.value -- { ref } -> { value, [truncated] }: the node's full text, which the outline clips
        register(method: "ui.value") { request, completion in
            guard let ref = Self.string(request.params, "ref") else {
                completion(Response(id: request.id, error: ErrorInfo(code: -32602, message: "ref is required")))
                return
            }
            Self.onUIQueue(request, completion) {
                let value = try UIAutomation.shared.value(of: ref)
                var result: [String: Any] = ["ref": ref, "value": value.text, "length": value.text.count]
                if value.truncated { result["truncated"] = true }
                return result
            }
        }

        // ui.select -- { ref } -> select a row / list item / tab without the pointer
        register(method: "ui.select") { request, completion in
            guard let ref = Self.string(request.params, "ref") else {
                completion(Response(id: request.id, error: ErrorInfo(code: -32602, message: "ref is required")))
                return
            }
            Self.onUIQueue(request, completion) {
                try UIAutomation.shared.select(ref)
                return ["selected": ref]
            }
        }

        // ui.scrollTo -- { ref } -> scroll its container until the node is visible
        register(method: "ui.scrollTo") { request, completion in
            guard let ref = Self.string(request.params, "ref") else {
                completion(Response(id: request.id, error: ErrorInfo(code: -32602, message: "ref is required")))
                return
            }
            Self.onUIQueue(request, completion) {
                return ["scrolledTo": ref, "via": try UIAutomation.shared.scrollTo(ref)]
            }
        }

        // ui.setValue -- { ref, value } -> set AXValue (text fields, sliders that take strings)
        register(method: "ui.setValue") { request, completion in
            guard let ref = Self.string(request.params, "ref"), let value = Self.string(request.params, "value") else {
                completion(Response(id: request.id, error: ErrorInfo(code: -32602, message: "ref and value are required")))
                return
            }
            Self.onUIQueue(request, completion) {
                try UIAutomation.shared.setValue(ref, value, allowSecure: request.params?["allowSecure"]?.value as? Bool ?? false)
                return ["set": ref]
            }
        }

        // ui.click -- { ref, [button], [count] } -> synthesized click at the element's center
        register(method: "ui.click") { request, completion in
            let params = request.params
            guard let ref = Self.string(params, "ref") else {
                completion(Response(id: request.id, error: ErrorInfo(code: -32602, message: "ref is required")))
                return
            }
            guard let button = MouseButton(rawValue: Self.string(params, "button") ?? "left") else {
                completion(Response(id: request.id, error: ErrorInfo(code: -32602, message: "button must be left, right, or middle")))
                return
            }
            let count = Self.int(params, "count") ?? 1
            guard let wid = UInt32(ref.split(separator: ":").first ?? "") else {
                completion(Response(id: request.id, error: ErrorInfo(code: -32602, message: "malformed ref '\(ref)'")))
                return
            }
            Task {
                // A ref names its window, so the click is always guarded: raise and
                // focus that window, then make sure the point really reaches its app.
                let target: FocusTarget
                switch await Self.focusAndVerify(wid) {
                case .success(let verified): target = verified
                case .failure(let refusal):
                    JSONLogger.shared.log("ui.err", msg: refusal.reason, data: ["method": request.method, "id": request.id])
                    completion(Response(id: request.id, error: ErrorInfo(code: -32000, message: refusal.reason)))
                    return
                }
                let frames = await StateManager.shared.getState().displays.compactMap { $0.frame }
                Self.onUIQueue(request, completion) {
                    let point = try UIAutomation.shared.center(of: ref)
                    if let covered = WindowHitTest.obstruction(at: point, targetPid: target.pid, windowID: wid,
                                                               in: WindowHitTest.onScreenWindows()) {
                        throw UIError.covered(covered)
                    }
                    // The synthesizer's state is only ever touched on its own queue.
                    try InputSynthesizer.shared.queue.sync {
                        InputSynthesizer.shared.displayFrames = frames
                        _ = try InputSynthesizer.shared.click(at: point, button: button, count: count)
                    }
                    return ["clicked": ref, "x": point.x, "y": point.y]
                }
            }
        }
    }

    /// Run blocking AX work on the UI queue and reply from there.
    static func onUIQueue(_ request: Request,
                                  _ completion: @escaping (Response) -> Void,
                                  _ work: @escaping () throws -> [String: Any]) {
        UIAutomation.shared.queue.async {
            do {
                let result = try work()
                JSONLogger.shared.log("ui.ok", data: ["method": request.method, "id": request.id, "count": result["count"] ?? 0])
                completion(Response(id: request.id, result: AnyCodable(result)))
            } catch {
                // Menu errors quote item titles, which are user data; the log gets the kind of failure only.
                let logged = (error as? MenuError)?.logSummary ?? "\(error)"
                JSONLogger.shared.log("ui.err", msg: logged, data: ["method": request.method, "id": request.id])
                completion(Response(id: request.id, error: ErrorInfo(code: -32000, message: "\(error)")))
            }
        }
    }
}
