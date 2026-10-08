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
            Self.synthesize(request, completion) {
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
            Self.synthesize(request, completion) {
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
            Self.synthesize(request, completion) {
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
            Self.synthesize(request, completion) {
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
            Self.synthesize(request, completion) {
                try InputSynthesizer.shared.type(text)
                return ["typed": text.count]
            }
        }

        register(method: "input.key.press") { request, completion in
            guard let spec = Self.string(request.params, "key") else {
                completion(Response(id: request.id, error: ErrorInfo(code: -32602, message: "key is required (e.g. 'cmd+s', 'enter')")))
                return
            }
            let count = Self.int(request.params, "count") ?? 1
            Self.synthesize(request, completion) {
                let combo = try parseKeyCombo(spec)
                try InputSynthesizer.shared.press(combo, count: count)
                return ["key": spec, "count": count]
            }
        }
    }

    // MARK: - Helpers

    /// Refresh the on-screen bounds check, then run `work` on the input queue
    /// (it sleeps between events) and reply from there.
    private static func synthesize(_ request: Request,
                                   _ completion: @escaping (Response) -> Void,
                                   _ work: @escaping () throws -> [String: Any]) {
        Task {
            let frames = await StateManager.shared.getState().displays.compactMap { $0.frame }
            // displayFrames is only ever touched on the input queue.
            InputSynthesizer.shared.queue.async {
                InputSynthesizer.shared.displayFrames = frames
                do {
                    let result = try work()
                    JSONLogger.shared.log("input.ok", data: ["method": request.method, "id": request.id])
                    completion(Response(id: request.id, result: AnyCodable(result)))
                } catch {
                    JSONLogger.shared.log("input.err", msg: "\(error)", data: ["method": request.method, "id": request.id])
                    completion(Response(id: request.id, error: ErrorInfo(code: -32000, message: "\(error)")))
                }
            }
        }
    }

    private static func number(_ params: [String: AnyCodable]?, _ key: String) -> Double? {
        guard let v = params?[key]?.value else { return nil }
        if let d = v as? Double { return d }
        if let i = v as? Int { return Double(i) }
        if let s = v as? String { return Double(s) }
        return nil
    }

    private static func int(_ params: [String: AnyCodable]?, _ key: String) -> Int? {
        number(params, key).map { Int($0) }
    }

    private static func string(_ params: [String: AnyCodable]?, _ key: String) -> String? {
        params?[key]?.value as? String
    }

    private static func point(_ params: [String: AnyCodable]?, _ xKey: String, _ yKey: String) -> CGPoint? {
        guard let x = number(params, xKey), let y = number(params, yKey) else { return nil }
        return CGPoint(x: x, y: y)
    }
}
