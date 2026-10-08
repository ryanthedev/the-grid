//
// MessageHandler+Input.swift
// GridServer
//
// input.* RPC methods: synthesized mouse and keyboard input. Coordinates are
// global Quartz points (top-left origin), the same space `display.list` and
// window frames use.
//

import Foundation
import CoreGraphics
import ApplicationServices

extension MessageHandler {

    func registerInputHandlers() {
        register(method: "input.mouse.position") { request, completion in
            let p = InputSynthesizer.shared.position()
            completion(Response(id: request.id, result: AnyCodable(["x": p.x, "y": p.y])))
        }

        register(method: "input.mouse.move") { request, completion in
            guard let point = Self.point(request.params, "x", "y") else {
                completion(Response(id: request.id, error: ErrorInfo(code: -32602, message: "x and y are required")))
                return
            }
            Self.synthesize(request, completion) { _ in
                try InputSynthesizer.shared.move(to: point)
                return ["x": point.x, "y": point.y]
            }
        }

        register(method: "input.mouse.click") { request, completion in
            let params = request.params
            let point = Self.point(params, "x", "y")
            let button = MouseButton(rawValue: Self.string(params, "button") ?? "left") ?? .left
            let count = Self.int(params, "count") ?? 1
            let modifiers = Self.string(params, "modifiers")
            Self.synthesize(request, completion, focusing: Self.windowID(params),
                            reaching: { point ?? InputSynthesizer.shared.position() }) { _ in
                let flags = try parseModifierFlags(modifiers)
                let at = try InputSynthesizer.shared.click(at: point, button: button, count: count, flags: flags)
                return ["x": at.x, "y": at.y, "button": button.rawValue, "count": count]
            }
        }

        register(method: "input.mouse.drag") { request, completion in
            let params = request.params
            guard let from = Self.point(params, "fromX", "fromY"),
                  let to = Self.point(params, "toX", "toY") else {
                completion(Response(id: request.id, error: ErrorInfo(code: -32602, message: "fromX, fromY, toX, toY are required")))
                return
            }
            let button = MouseButton(rawValue: Self.string(params, "button") ?? "left") ?? .left
            let steps = Self.int(params, "steps") ?? 12
            let modifiers = Self.string(params, "modifiers")
            Self.synthesize(request, completion, focusing: Self.windowID(params), reaching: { from }) { _ in
                let flags = try parseModifierFlags(modifiers)
                try InputSynthesizer.shared.drag(from: from, to: to, button: button, steps: steps, flags: flags)
                return ["from": ["x": from.x, "y": from.y], "to": ["x": to.x, "y": to.y]]
            }
        }

        register(method: "input.mouse.scroll") { request, completion in
            let params = request.params
            let point = Self.point(params, "x", "y")
            let dx = Self.int(params, "dx") ?? 0
            let dy = Self.int(params, "dy") ?? 0
            let modifiers = Self.string(params, "modifiers")
            Self.synthesize(request, completion, focusing: Self.windowID(params),
                            reaching: { point ?? InputSynthesizer.shared.position() }) { _ in
                let flags = try parseModifierFlags(modifiers)
                let at = try InputSynthesizer.shared.scroll(at: point, dx: dx, dy: dy, flags: flags)
                return ["x": at.x, "y": at.y, "dx": dx, "dy": dy]
            }
        }

        register(method: "input.key.type") { request, completion in
            guard let text = Self.string(request.params, "text") else {
                completion(Response(id: request.id, error: ErrorInfo(code: -32602, message: "text is required")))
                return
            }
            let allowSecure = request.params?["allowSecure"]?.value as? Bool ?? false
            Self.synthesize(request, completion, focusing: Self.windowID(request.params)) { guarded in
                // A guarded call knows its target app, so it can see where the caret is.
                if let guarded, !allowSecure, UIAutomation.focusIsSecureField(pid: guarded.pid) {
                    throw UIError.secureField
                }
                try InputSynthesizer.shared.type(text, stillFocused: guarded?.stillFocused, pid: guarded?.pid)
                return ["typed": text.count]
            }
        }

        register(method: "input.key.press") { request, completion in
            guard let spec = Self.string(request.params, "key") else {
                completion(Response(id: request.id, error: ErrorInfo(code: -32602, message: "key is required (e.g. 'cmd+s', 'enter')")))
                return
            }
            let count = Self.int(request.params, "count") ?? 1
            Self.synthesize(request, completion, focusing: Self.windowID(request.params)) { guarded in
                let combo = try parseKeyCombo(spec)
                try InputSynthesizer.shared.press(combo, count: count, stillFocused: guarded?.stillFocused, pid: guarded?.pid)
                return ["key": spec, "count": count]
            }
        }
    }

    // MARK: - Helpers

    /// Refresh the on-screen bounds check, then run `work` on the input queue
    /// (it sleeps between events) and reply from there. With `focusing`, the
    /// window must verifiably hold keyboard focus or nothing is posted.
    static func synthesize(_ request: Request,
                           _ completion: @escaping (Response) -> Void,
                           focusing windowID: UInt32? = nil,
                           reaching point: (() -> CGPoint)? = nil,
                           _ work: @escaping (_ guarded: KeyGuard?) throws -> [String: Any]) {
        func refuse(_ reason: String) {
            JSONLogger.shared.log("input.err", msg: reason, data: ["method": request.method, "id": request.id, "wid": windowID ?? 0])
            completion(Response(id: request.id, error: ErrorInfo(code: -32000, message: reason)))
        }
        Task {
            var target: FocusTarget?
            if let windowID {
                switch await focusAndVerify(windowID) {
                case .success(let verified): target = verified
                case .failure(let refusal):
                    refuse(refusal.reason)
                    return
                }
            }
            let frames = await StateManager.shared.getState().displays.compactMap { $0.frame }
            // displayFrames is only ever touched on the input queue.
            InputSynthesizer.shared.queue.async {
                InputSynthesizer.shared.displayFrames = frames
                // Focus can move after the check above: during the queue hop, or while a
                // long string is going out. The synthesizer asks this before every chunk.
                let guarded: KeyGuard? = target.map { target in
                    KeyGuard(pid: target.pid) { UIAutomation.checkFocus(pid: target.pid, window: target.window) == .held }
                }
                // A pointer event goes to whatever is on top, not to the window the caller
                // was looking at; with a windowId the point must really reach that app.
                if let target, let point,
                   let covered = WindowHitTest.obstruction(at: point(), targetPid: target.pid, windowID: target.windowID,
                                                           in: WindowHitTest.onScreenWindows()) {
                    refuse(covered)
                    return
                }
                do {
                    let result = try work(guarded)
                    JSONLogger.shared.log("input.ok", data: ["method": request.method, "id": request.id])
                    completion(Response(id: request.id, result: AnyCodable(result)))
                } catch {
                    JSONLogger.shared.log("input.err", msg: "\(error)", data: ["method": request.method, "id": request.id])
                    completion(Response(id: request.id, error: ErrorInfo(code: -32000, message: "\(error)")))
                }
            }
        }
    }

    /// What a guarded key call hands the synthesizer: the process to deliver
    /// to, and the focus check to repeat before every chunk.
    struct KeyGuard {
        let pid: pid_t
        let stillFocused: () -> Bool
    }

    struct FocusTarget: @unchecked Sendable {
        let windowID: UInt32
        let pid: pid_t
        let window: AXUIElement
    }

    struct FocusRefusal: Error {
        let reason: String
    }

    /// Focus `windowID`, then poll the OS until it really is the focused
    /// window. The grid's own focus cache is written optimistically by
    /// focusWindow, so it cannot be the check.
    static func focusAndVerify(_ windowID: UInt32) async -> Result<FocusTarget, FocusRefusal> {
        guard let context = await ManipulationContext.from(windowID: windowID) else {
            return .failure(FocusRefusal(reason: "window \(windowID) not found"))
        }
        guard context.pid != ProcessInfo.processInfo.processIdentifier else {
            return .failure(FocusRefusal(reason: "window \(windowID) belongs to the grid server; its focus cannot be verified"))
        }
        // Same preamble as window.focus: the intent mark stops the border sync loop.
        await EventRouter.shared.route(
            .commandFocusWindow(windowID: windowID, requestID: UUID().uuidString),
            from: .manual(reason: "cli")
        )
        await StateManager.shared.markCLIFocusIntent(windowID)
        let state = await StateManager.shared.getState()
        let manipulator = WindowManipulator(connectionID: state.metadata.connectionID)
        // The result is advisory: some apps (Calculator) reject AXRaise yet take
        // focus from the earlier steps. The OS check below is the verdict.
        let focusReported = await manipulator.focusWindow(context: context)
        var last = UIAutomation.FocusCheck.unknown("not checked")
        for _ in 0..<20 {
            let reading: (FocusTarget?, UIAutomation.FocusCheck) = await withCheckedContinuation { continuation in
                UIAutomation.shared.queue.async {
                    guard let window = manipulator.getAXElement(pid: context.pid, windowID: windowID) else {
                        continuation.resume(returning: (nil, .unknown("window is not reachable through accessibility")))
                        return
                    }
                    let target = FocusTarget(windowID: windowID, pid: context.pid, window: window)
                    continuation.resume(returning: (target, UIAutomation.checkFocus(pid: context.pid, window: window)))
                }
            }
            last = reading.1
            if let target = reading.0, last == .held { return .success(target) }
            try? await Task.sleep(nanoseconds: 25_000_000)
        }
        let why: String
        switch last {
        case .held: why = "unknown"
        case .elsewhere(let what), .unknown(let what): why = what
        }
        let note = focusReported ? "" : "; the focus request itself reported failure"
        return .failure(FocusRefusal(reason: "window \(windowID) did not take keyboard focus (\(why)\(note)); nothing was posted"))
    }

    static func windowID(_ params: [String: AnyCodable]?, _ key: String = "windowId") -> UInt32? {
        number(params, key).flatMap { UInt32(exactly: $0) }
    }

    static func number(_ params: [String: AnyCodable]?, _ key: String) -> Double? {
        guard let v = params?[key]?.value else { return nil }
        if let d = v as? Double { return d }
        if let i = v as? Int { return Double(i) }
        if let s = v as? String { return Double(s) }
        return nil
    }

    static func int(_ params: [String: AnyCodable]?, _ key: String) -> Int? {
        // Int(Double) traps on NaN and out-of-range values; a bad param must not take the server down.
        number(params, key).flatMap { Int(exactly: $0.rounded(.towardZero)) }
    }

    static func string(_ params: [String: AnyCodable]?, _ key: String) -> String? {
        params?[key]?.value as? String
    }

    private static func point(_ params: [String: AnyCodable]?, _ xKey: String, _ yKey: String) -> CGPoint? {
        guard let x = number(params, xKey), let y = number(params, yKey) else { return nil }
        return CGPoint(x: x, y: y)
    }
}
