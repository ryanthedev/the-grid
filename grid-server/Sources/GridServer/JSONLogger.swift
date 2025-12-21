import Foundation

/// Thread-safe JSON logger that writes to ~/.local/state/thegrid/thegrid-server.json
actor JSONLogger {
    static let shared = JSONLogger()

    private let filePath: String
    private var fileHandle: FileHandle?
    private var isInitialized = false

    private init() {
        let homeDir = FileManager.default.homeDirectoryForCurrentUser.path
        let logDir = "\(homeDir)/.local/state/thegrid"
        self.filePath = "\(logDir)/thegrid-server.json"

        // Ensure directory exists
        try? FileManager.default.createDirectory(atPath: logDir, withIntermediateDirectories: true)
    }

    /// Get the log file path (for startup message)
    nonisolated func getLogPath() -> String {
        let homeDir = FileManager.default.homeDirectoryForCurrentUser.path
        return "\(homeDir)/.local/state/thegrid/thegrid-server.json"
    }

    /// Log an event
    func log(_ ev: String, msg: String? = nil, data: [String: Any]? = nil, tid: String? = nil, sid: String? = nil) {
        var event: [String: Any] = [:]
        event["ev"] = ev
        if let sid = sid { event["sid"] = sid }
        if let tid = tid { event["tid"] = tid }
        if let msg = msg { event["msg"] = msg }
        if let data = data { event["data"] = data }
        event["ts"] = Int64(Date().timeIntervalSince1970)

        writeEvent(event)
    }

    /// Log with trace context from CurrentSpan
    func log(_ ev: String, msg: String? = nil, data: [String: Any]? = nil) async {
        let tid = CurrentSpan.traceId
        let sid = CurrentSpan.spanId
        await self.log(ev, msg: msg, data: data, tid: tid, sid: sid)
    }

    /// Start a new span (called from MessageHandler with parent context)
    nonisolated func startSpan(_ name: String, tid: String, parentSid: String?, data: [String: Any]? = nil) -> Span {
        let sid = parentSid.map { "\($0).\(name)" } ?? tid
        let span = Span(tid: tid, sid: sid, name: name, start: Date())

        // Build start event
        var event: [String: Any] = [:]
        event["ev"] = "\(span.name).start"
        event["sid"] = span.sid
        event["tid"] = span.tid
        if let data = data {
            event["data"] = data
        }
        event["ts"] = Int64(Date().timeIntervalSince1970)

        // Log synchronously through actor to prevent race condition
        Task {
            await JSONLogger.shared.writeEventFromNonisolated(event)
        }

        return span
    }

    /// Write event from nonisolated context (internal actor method)
    func writeEventFromNonisolated(_ event: [String: Any]) {
        writeEvent(event)
    }

    /// Log span start event
    func logSpanStart(_ span: Span, data: [String: Any]? = nil) {
        var event: [String: Any] = [:]
        // Field order: ev, sid, tid, data, ts
        event["ev"] = "\(span.name).start"
        event["sid"] = span.sid
        event["tid"] = span.tid
        if let data = data {
            event["data"] = data
        }
        event["ts"] = Int64(Date().timeIntervalSince1970)

        writeEvent(event)
    }

    /// Log span end event with duration
    func logSpanEnd(_ span: Span, dur: Int64, err: String? = nil) {
        var event: [String: Any] = [:]
        // Field order: ev, sid, tid, dur, err, ts
        event["ev"] = "\(span.name).end"
        event["sid"] = span.sid
        event["tid"] = span.tid
        event["dur"] = dur
        if let err = err {
            event["err"] = err
        }
        event["ts"] = Int64(Date().timeIntervalSince1970)

        writeEvent(event)
    }

    /// Write event with correct field ordering
    private func writeEvent(_ event: [String: Any]) {
        // Escape special characters in strings to produce valid JSON
        func escapeString(_ str: String) -> String {
            return str
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
                .replacingOccurrences(of: "\n", with: "\\n")
                .replacingOccurrences(of: "\r", with: "\\r")
                .replacingOccurrences(of: "\t", with: "\\t")
        }

        if !isInitialized {
            openFileHandle()
            isInitialized = true
        }

        // Create ordered key array for field ordering
        let orderedKeys = ["ev", "sid", "tid", "dur", "err", "msg", "data", "ts"]
        var orderedPairs: [(String, Any)] = []

        for key in orderedKeys {
            if let value = event[key] {
                orderedPairs.append((key, value))
            }
        }

        // Build JSON string manually for field ordering
        var jsonParts: [String] = []
        for (key, value) in orderedPairs {
            if let strVal = value as? String {
                jsonParts.append("\"\(key)\":\"\(escapeString(strVal))\"")
            } else if let intVal = value as? Int64 {
                jsonParts.append("\"\(key)\":\(intVal)")
            } else if let intVal = value as? Int {
                jsonParts.append("\"\(key)\":\(intVal)")
            } else if let dictVal = value as? [String: Any],
                      let jsonData = try? JSONSerialization.data(withJSONObject: dictVal, options: [.sortedKeys]),
                      let jsonStr = String(data: jsonData, encoding: .utf8) {
                jsonParts.append("\"\(key)\":\(jsonStr)")
            }
        }

        let line = "{" + jsonParts.joined(separator: ",") + "}\n"
        guard let lineData = line.data(using: .utf8) else { return }

        if fileHandle == nil {
            openFileHandle()
        }

        fileHandle?.write(lineData)
        fileHandle?.synchronizeFile()
    }

    private func openFileHandle() {
        if !FileManager.default.fileExists(atPath: filePath) {
            FileManager.default.createFile(atPath: filePath, contents: nil, attributes: nil)
        }
        fileHandle = FileHandle(forUpdatingAtPath: filePath)
        fileHandle?.seekToEndOfFile()
    }

    deinit {
        try? fileHandle?.close()
    }
}

/// Represents a timed span with start/end events
struct Span {
    let tid: String
    let sid: String
    let name: String
    let start: Date

    /// Create a child span with dot-notation sid
    func startChild(_ name: String, data: [String: Any]? = nil) async -> Span {
        let child = Span(
            tid: self.tid,
            sid: "\(self.sid).\(name)",
            name: name,
            start: Date()
        )
        await JSONLogger.shared.logSpanStart(child, data: data)
        return child
    }

    /// End the span and log duration
    func end(err: String? = nil) async {
        let dur = Int64(Date().timeIntervalSince(start) * 1000)
        await JSONLogger.shared.logSpanEnd(self, dur: dur, err: err)
    }
}

/// Convenience function for non-async contexts
func jlog(_ ev: String, msg: String? = nil, data: [String: Any]? = nil) {
    let tid = CurrentSpan.traceId
    let sid = CurrentSpan.spanId
    Task { await JSONLogger.shared.log(ev, msg: msg, data: data, tid: tid, sid: sid) }
}
