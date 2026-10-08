//
// Clipboard.swift
// GridServer
//
// The general pasteboard as text, for clip.read and clip.write. It lives in
// the server because the pasteboard belongs to the GUI login session: the
// server is a launchd agent in that session, while `thegrid mcp serve` may be
// started from ssh or a sandbox where NSPasteboard reaches nothing.
//
// Contents are never logged: sizes and type names only.
//

import AppKit
import Foundation

/// What may be read. Pure, so the rule can be tested without a pasteboard.
enum ClipboardPolicy {
    /// nspasteboard.org markers: password managers flag secrets as concealed, and
    /// apps flag contents that are not meant to be recorded as transient.
    static let concealedType = "org.nspasteboard.ConcealedType"
    static let transientType = "org.nspasteboard.TransientType"

    static let maxReadBytes = 65_536
    static let maxWriteBytes = 1_048_576

    enum ReadDecision: Equatable {
        case read
        case noText
        case refuse(String)
    }

    static func readDecision(types: [String]) -> ReadDecision {
        if types.contains(concealedType) {
            return .refuse("the clipboard holds a concealed item (a password manager marked it \(concealedType)); it is not read")
        }
        if types.contains(transientType) {
            return .refuse("the clipboard holds a transient item (its app marked it \(transientType), not to be recorded); it is not read")
        }
        let text = [NSPasteboard.PasteboardType.string.rawValue, "public.utf16-external-plain-text", "NSStringPboardType"]
        return types.contains(where: text.contains) ? .read : .noText
    }

    /// At most `limit` UTF-8 bytes, cut on a character boundary.
    static func clip(_ text: String, limit: Int = maxReadBytes) -> (text: String, truncated: Bool) {
        guard text.utf8.count > limit else { return (text, false) }
        var out = ""
        var used = 0
        for character in text {
            let size = String(character).utf8.count
            if used + size > limit { break }
            out.append(character)
            used += size
        }
        return (out, true)
    }
}

enum ClipboardError: Error, CustomStringConvertible {
    case refused(String)
    case tooLarge(Int)
    case writeFailed

    var description: String {
        switch self {
        case .refused(let why): return "clip.read refused: \(why)"
        case .tooLarge(let bytes): return "clip.write refused: \(bytes) bytes is over the \(ClipboardPolicy.maxWriteBytes)-byte limit"
        case .writeFailed: return "the pasteboard did not accept the text"
        }
    }
}

enum Clipboard {
    /// `pasteboard` is a parameter so tests use a private one and never the user's.
    static func read(from pasteboard: NSPasteboard) throws -> [String: Any] {
        let types = (pasteboard.types ?? []).map(\.rawValue)
        var result: [String: Any] = ["changeCount": pasteboard.changeCount, "types": types]
        switch ClipboardPolicy.readDecision(types: types) {
        case .refuse(let why):
            throw ClipboardError.refused(why)
        case .noText:
            result["hasText"] = false
        case .read:
            guard let text = pasteboard.string(forType: .string) else {
                result["hasText"] = false
                break
            }
            let clipped = ClipboardPolicy.clip(text)
            result["hasText"] = true
            result["text"] = clipped.text
            result["bytes"] = text.utf8.count
            if clipped.truncated {
                result["truncated"] = true
                result["returnedBytes"] = clipped.text.utf8.count
            }
        }
        return result
    }

    static func write(_ text: String, to pasteboard: NSPasteboard) throws -> [String: Any] {
        let bytes = text.utf8.count
        guard bytes <= ClipboardPolicy.maxWriteBytes else { throw ClipboardError.tooLarge(bytes) }
        let previous = pasteboard.changeCount
        pasteboard.clearContents()
        guard pasteboard.setString(text, forType: .string) else { throw ClipboardError.writeFailed }
        return ["changeCount": pasteboard.changeCount, "previousChangeCount": previous, "bytes": bytes]
    }
}
