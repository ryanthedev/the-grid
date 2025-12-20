import Foundation

/// Thread-safe logger for bfd.log with command execution details
actor BFDLogger {
    static let shared = BFDLogger()

    private let filePath: String
    private let maxFileSize: UInt64 = 1_048_576 // 1MB
    private var fileHandle: FileHandle?
    private var isInitialized = false

    private init() {
        let homeDir = FileManager.default.homeDirectoryForCurrentUser.path
        let logDir = "\(homeDir)/.local/state/thegrid"
        self.filePath = "\(logDir)/bfd.log"

        // Ensure directory exists
        try? FileManager.default.createDirectory(atPath: logDir, withIntermediateDirectories: true)
    }

    /// Log a hotkey execution with full details
    func log(
        hotkey: String,
        command: String,
        expanded: String,
        stdout: String,
        stderr: String,
        exitCode: Int32,
        durationMs: Int
    ) {
        if !isInitialized {
            openFileHandle()
            isInitialized = true
        }

        let event: [String: Any] = [
            "t": Int64(Date().timeIntervalSince1970),
            "hk": hotkey,
            "cmd": command,
            "exp": expanded,
            "out": stdout.prefix(500),  // Truncate long output
            "err": stderr.prefix(500),
            "exit": exitCode,
            "ms": durationMs
        ]

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

        checkRotation()
    }

    /// Log an error
    func logError(_ message: String, hotkey: String? = nil) {
        if !isInitialized {
            openFileHandle()
            isInitialized = true
        }

        var event: [String: Any] = [
            "t": Int64(Date().timeIntervalSince1970),
            "err": message
        ]
        if let hk = hotkey {
            event["hk"] = hk
        }

        guard let jsonData = try? JSONSerialization.data(withJSONObject: event, options: [.sortedKeys]),
              let jsonString = String(data: jsonData, encoding: .utf8) else {
            return
        }

        let line = jsonString + "\n"
        guard let lineData = line.data(using: .utf8) else { return }

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

    private func checkRotation() {
        guard let handle = fileHandle else { return }

        do {
            let currentOffset = handle.offsetInFile
            if currentOffset > maxFileSize {
                try handle.close()
                fileHandle = nil
                try Data().write(to: URL(fileURLWithPath: filePath))
                openFileHandle()
            }
        } catch {
            fileHandle = nil
            openFileHandle()
        }
    }
}
