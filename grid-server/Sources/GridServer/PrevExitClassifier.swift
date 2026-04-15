import Foundation

/// Classification of the previous grid-server run's exit, derived from the tail
/// of `thegrid-server.json`. Emitted as `srv.prev_exit {"exit": "<case>"}` once
/// at startup so we can correlate restarts with whether they were graceful,
/// crashed, or launchd-killed / OOM.
enum PrevExit: String {
    case graceful
    case fatal
    case unknown
}

enum PrevExitClassifier {

    /// Default size to read back from the log file when classifying — large enough
    /// to catch the previous run's `srv.start` plus any terminal event, small
    /// enough to stay cheap on every startup.
    static let defaultTailBytes: Int = 8192

    /// Classify from a raw JSONL string (typically the last ~8KB of the log file).
    /// Contract: the tail passed in is from BEFORE the current run wrote its own
    /// `srv.start` line. Therefore the most-recent `srv.start` in the tail is the
    /// previous run's.
    ///
    /// Rules, scanning lines in reverse:
    ///   - first `srv.shutdown.done` encountered before any `srv.start` → `.graceful`
    ///   - first `srv.fatal` or `srv.fatal.exception` encountered before any `srv.start` → `.fatal`
    ///   - first `srv.start` encountered with no terminal event after it → `.unknown`
    ///   - empty or unparseable tail → `.unknown`
    static func classify(jsonlTail: String) -> PrevExit {
        guard !jsonlTail.isEmpty else { return .unknown }

        // Split by newline; skip the last (possibly partial) trailing line only if
        // it doesn't parse. We iterate in reverse and look for the first
        // recognizable event.
        let lines = jsonlTail.split(separator: "\n", omittingEmptySubsequences: true)

        for line in lines.reversed() {
            if let ev = extractEv(from: line) {
                switch ev {
                case "srv.shutdown.done":
                    return .graceful
                case "srv.fatal", "srv.fatal.exception":
                    return .fatal
                case "srv.start":
                    return .unknown
                default:
                    continue
                }
            }
        }

        return .unknown
    }

    /// Extract the `"ev":"..."` value from a JSON line without full parsing.
    /// Tolerates partial lines (returns nil if malformed).
    private static func extractEv<S: StringProtocol>(from line: S) -> String? {
        guard let evRange = line.range(of: "\"ev\":\"") else { return nil }
        let afterKey = line[evRange.upperBound...]
        guard let closeQuote = afterKey.firstIndex(of: "\"") else { return nil }
        return String(afterKey[..<closeQuote])
    }

    /// Read the last `tailBytes` of a file and return as a UTF-8 string. Returns
    /// empty string if file is missing, empty, or unreadable. Tolerates partial
    /// leading line (the classifier's line-split discards unparseable lines).
    static func readTail(path: String, tailBytes: Int = defaultTailBytes) -> String {
        guard FileManager.default.fileExists(atPath: path) else { return "" }
        guard let handle = FileHandle(forReadingAtPath: path) else { return "" }
        defer { try? handle.close() }

        do {
            let size = try handle.seekToEnd()
            let offset = size > UInt64(tailBytes) ? size - UInt64(tailBytes) : 0
            try handle.seek(toOffset: offset)
            let data = handle.availableData
            return String(data: data, encoding: .utf8) ?? ""
        } catch {
            return ""
        }
    }
}
