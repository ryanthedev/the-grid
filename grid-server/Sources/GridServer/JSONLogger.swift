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
        if !isInitialized {
            openFileHandle()
            isInitialized = true
        }

        var event: [String: Any] = [
            "ts": Int64(Date().timeIntervalSince1970),
            "ev": ev
        ]

        if let msg = msg {
            event["msg"] = msg
        }
        if let data = data {
            event["data"] = data
        }
        if let tid = tid {
            event["tid"] = tid
        }
        if let sid = sid {
            event["sid"] = sid
        }

        guard let jsonData = try? JSONSerialization.data(withJSONObject: event, options: [.sortedKeys]),
              let jsonString = String(data: jsonData, encoding: .utf8) else {
            return
        }

        let line = jsonString + "\n"
        guard let lineData = line.data(using: .utf8) else { return }

        if fileHandle == nil {
            openFileHandle()
        }

        fileHandle?.write(lineData)
        fileHandle?.synchronizeFile()
    }

    /// Log with trace context from CurrentSpan
    func log(_ ev: String, msg: String? = nil, data: [String: Any]? = nil) async {
        let tid = CurrentSpan.traceId
        let sid = CurrentSpan.spanId
        await self.log(ev, msg: msg, data: data, tid: tid, sid: sid)
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

/// Convenience function for non-async contexts
func jlog(_ ev: String, msg: String? = nil, data: [String: Any]? = nil) {
    let tid = CurrentSpan.traceId
    let sid = CurrentSpan.spanId
    Task { await JSONLogger.shared.log(ev, msg: msg, data: data, tid: tid, sid: sid) }
}
