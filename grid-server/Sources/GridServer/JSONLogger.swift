import Foundation

// MARK: - JSONLogWriter (Queue-based batch writer)

/// Singleton writer that buffers log lines and writes in batches.
/// Opens file fresh for each batch - handles external file deletion gracefully.
final class JSONLogWriter {
    static let shared = JSONLogWriter()

    private let queue = DispatchQueue(label: "thegrid.logwriter")
    private var buffer: [String] = []
    private var flushWorkItem: DispatchWorkItem?
    private let filePath: String

    private let batchSize = 50
    private let flushInterval: TimeInterval = 0.1

    private init() {
        let homeDir = FileManager.default.homeDirectoryForCurrentUser.path
        let logDir = "\(homeDir)/.local/state/thegrid"
        self.filePath = "\(logDir)/thegrid-server.json"

        // Ensure directory exists
        try? FileManager.default.createDirectory(atPath: logDir, withIntermediateDirectories: true)
    }

    /// Enqueue a log line (thread-safe, non-blocking)
    func enqueue(_ line: String) {
        queue.async { [weak self] in
            guard let self = self else { return }
            self.buffer.append(line)
            self.scheduleFlush()
        }
    }

    private func scheduleFlush() {
        // Cancel existing timer
        flushWorkItem?.cancel()

        // Flush immediately if buffer is large
        if buffer.count >= batchSize {
            flush()
            return
        }

        // Otherwise schedule flush after interval
        let work = DispatchWorkItem { [weak self] in
            self?.flush()
        }
        flushWorkItem = work
        queue.asyncAfter(deadline: .now() + flushInterval, execute: work)
    }

    private func flush() {
        guard !buffer.isEmpty else { return }

        let lines = buffer
        buffer.removeAll(keepingCapacity: true)
        flushWorkItem = nil

        writeBatch(lines)
    }

    private func writeBatch(_ lines: [String]) {
        // Ensure file exists
        if !FileManager.default.fileExists(atPath: filePath) {
            FileManager.default.createFile(atPath: filePath, contents: nil)
        }

        // Open fresh handle
        guard let file = FileHandle(forWritingAtPath: filePath) else { return }
        defer { try? file.close() }

        // Seek to end and write
        do {
            try file.seekToEnd()
            let data = lines.joined(separator: "\n") + "\n"
            if let bytes = data.data(using: .utf8) {
                try file.write(contentsOf: bytes)
            }
        } catch {
            // Silent fail - logging shouldn't crash the app
        }
    }

    /// Get the log file path (for startup message)
    var logPath: String { filePath }
}

// MARK: - JSONLogger (Formatting + Span management)

/// Thread-safe JSON logger that formats events and enqueues to writer.
/// Maintains span/trace context support.
enum JSONLogger {
    static let shared = JSONLoggerImpl()
}

final class JSONLoggerImpl: @unchecked Sendable {

    /// Get the log file path (for startup message)
    func getLogPath() -> String {
        JSONLogWriter.shared.logPath
    }

    /// Log an event with explicit trace context
    func log(_ ev: String, msg: String? = nil, data: [String: Any]? = nil, tid: String? = nil, sid: String? = nil) {
        let line = formatLine(ev: ev, msg: msg, data: data, tid: tid, sid: sid)
        JSONLogWriter.shared.enqueue(line)
    }

    /// Log with trace context from CurrentSpan (sync - TaskLocal reads work from any context)
    func log(_ ev: String, msg: String? = nil, data: [String: Any]? = nil) {
        let tid = CurrentSpan.traceId
        let sid = CurrentSpan.spanId
        log(ev, msg: msg, data: data, tid: tid, sid: sid)
    }

    /// Start a new span
    func startSpan(_ name: String, tid: String, parentSid: String?, data: [String: Any]? = nil) -> Span {
        let sid = parentSid.map { "\($0).\(name)" } ?? tid
        let span = Span(tid: tid, sid: sid, name: name, start: Date())

        // Log start event
        let line = formatLine(ev: "\(name).start", data: data, tid: tid, sid: sid)
        JSONLogWriter.shared.enqueue(line)

        return span
    }

    /// Log span start event
    func logSpanStart(_ span: Span, data: [String: Any]? = nil) {
        let line = formatLine(ev: "\(span.name).start", data: data, tid: span.tid, sid: span.sid)
        JSONLogWriter.shared.enqueue(line)
    }

    /// Log span end event with duration
    func logSpanEnd(_ span: Span, dur: Int64, err: String? = nil) {
        let line = formatLineWithDur(ev: "\(span.name).end", dur: dur, err: err, tid: span.tid, sid: span.sid)
        JSONLogWriter.shared.enqueue(line)
    }

    // MARK: - Formatting

    private func formatLine(ev: String, msg: String? = nil, data: [String: Any]? = nil, tid: String? = nil, sid: String? = nil) -> String {
        var parts: [String] = []

        parts.append("\"ev\":\"\(escapeString(ev))\"")
        if let sid = sid { parts.append("\"sid\":\"\(escapeString(sid))\"") }
        if let tid = tid { parts.append("\"tid\":\"\(escapeString(tid))\"") }
        if let msg = msg { parts.append("\"msg\":\"\(escapeString(msg))\"") }
        if let data = data, let jsonStr = encodeData(data) {
            parts.append("\"data\":\(jsonStr)")
        }
        parts.append("\"ts\":\(Int64(Date().timeIntervalSince1970))")

        return "{" + parts.joined(separator: ",") + "}"
    }

    private func formatLineWithDur(ev: String, dur: Int64, err: String? = nil, tid: String, sid: String) -> String {
        var parts: [String] = []

        parts.append("\"ev\":\"\(escapeString(ev))\"")
        parts.append("\"sid\":\"\(escapeString(sid))\"")
        parts.append("\"tid\":\"\(escapeString(tid))\"")
        parts.append("\"dur\":\(dur)")
        if let err = err { parts.append("\"err\":\"\(escapeString(err))\"") }
        parts.append("\"ts\":\(Int64(Date().timeIntervalSince1970))")

        return "{" + parts.joined(separator: ",") + "}"
    }

    private func escapeString(_ str: String) -> String {
        str.replacingOccurrences(of: "\\", with: "\\\\")
           .replacingOccurrences(of: "\"", with: "\\\"")
           .replacingOccurrences(of: "\n", with: "\\n")
           .replacingOccurrences(of: "\r", with: "\\r")
           .replacingOccurrences(of: "\t", with: "\\t")
    }

    private func encodeData(_ data: [String: Any]) -> String? {
        guard let jsonData = try? JSONSerialization.data(withJSONObject: data, options: [.sortedKeys]),
              let jsonStr = String(data: jsonData, encoding: .utf8) else {
            return nil
        }
        return jsonStr
    }
}

// MARK: - Span

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
        JSONLogger.shared.logSpanStart(child, data: data)
        return child
    }

    /// End the span and log duration
    func end(err: String? = nil) async {
        let dur = Int64(Date().timeIntervalSince(start) * 1000)
        JSONLogger.shared.logSpanEnd(self, dur: dur, err: err)
    }
}

// MARK: - Convenience

/// Convenience function for non-async contexts
func jlog(_ ev: String, msg: String? = nil, data: [String: Any]? = nil) {
    let tid = CurrentSpan.traceId
    let sid = CurrentSpan.spanId
    JSONLogger.shared.log(ev, msg: msg, data: data, tid: tid, sid: sid)
}
