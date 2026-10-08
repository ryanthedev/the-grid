//
// MessageHandler+Clipboard.swift
// GridServer
//
// clip.read and clip.write. The log gets sizes and type counts, never contents.
//

import AppKit
import Foundation

extension MessageHandler {

    func registerClipboardHandlers() {
        // clip.read -- { [type] } -> { changeCount, types, hasText, [text, bytes, truncated, returnedBytes] }
        register(method: "clip.read") { request, completion in
            let type = Self.string(request.params, "type") ?? "text"
            guard type == "text" else {
                completion(Response(id: request.id, error: ErrorInfo(code: -32602, message: "clip.read reads text only; type must be 'text'")))
                return
            }
            Self.onMain(request, completion) {
                let result = try Clipboard.read(from: .general)
                JSONLogger.shared.log("clip.read", data: ["bytes": result["bytes"] ?? 0, "types": (result["types"] as? [String])?.count ?? 0])
                return result
            }
        }

        // clip.write -- { text } -> { changeCount, previousChangeCount, bytes }
        register(method: "clip.write") { request, completion in
            guard let text = Self.string(request.params, "text") else {
                completion(Response(id: request.id, error: ErrorInfo(code: -32602, message: "text is required")))
                return
            }
            Self.onMain(request, completion) {
                let result = try Clipboard.write(text, to: .general)
                JSONLogger.shared.log("clip.write", data: ["bytes": result["bytes"] ?? 0])
                return result
            }
        }
    }

    /// NSPasteboard is AppKit: use it from the main thread. The calls are local and quick.
    private static func onMain(_ request: Request, _ completion: @escaping (Response) -> Void, _ work: @escaping () throws -> [String: Any]) {
        DispatchQueue.main.async {
            do {
                completion(Response(id: request.id, result: AnyCodable(try work())))
            } catch {
                // ClipboardError texts name types and sizes only.
                JSONLogger.shared.log("clip.err", msg: "\(error)", data: ["method": request.method, "id": request.id])
                completion(Response(id: request.id, error: ErrorInfo(code: -32000, message: "\(error)")))
            }
        }
    }
}
