import Foundation

/// Thread-safe event logger that writes compact JSON-lines to disk
/// - Writes to ~/.local/state/thegrid/events.jsonl
/// - Append-only, synchronous flush after each write
/// - Auto-rotates when file exceeds 1MB
actor EventLog {
    static let shared = EventLog()

    private let filePath: String
    private let maxFileSize: UInt64 = 1_048_576 // 1MB
    private var fileHandle: FileHandle?
    private var isInitialized = false

    private init() {
        let homeDir = FileManager.default.homeDirectoryForCurrentUser.path
        let logDir = "\(homeDir)/.local/state/thegrid"
        self.filePath = "\(logDir)/events.jsonl"

        // Ensure directory exists
        try? FileManager.default.createDirectory(atPath: logDir, withIntermediateDirectories: true)
    }

    /// Log an event with arbitrary data
    /// - Parameters:
    ///   - eventType: Event type identifier (will be stored as "ev" field)
    ///   - data: Additional fields to include in the event (e.g., ["wid": 123, "app": "Terminal"])
    func log(_ eventType: String, _ data: [String: Any] = [:]) {
        // Lazy initialization on first use
        if !isInitialized {
            openFileHandle()
            isInitialized = true
        }

        // Build event dictionary
        var event: [String: Any] = [
            "t": Int64(Date().timeIntervalSince1970),
            "ev": eventType
        ]

        // Merge additional data
        for (key, value) in data {
            event[key] = value
        }

        // Encode to compact JSON
        guard let jsonData = try? JSONSerialization.data(withJSONObject: event, options: [.sortedKeys]),
              let jsonString = String(data: jsonData, encoding: .utf8) else {
            return
        }

        // Write line to file
        let line = jsonString + "\n"
        guard let lineData = line.data(using: .utf8) else { return }

        // Ensure file handle is open
        if fileHandle == nil {
            openFileHandle()
        }

        // Write and flush
        fileHandle?.write(lineData)
        fileHandle?.synchronizeFile() // Synchronous flush for crash safety

        // Check if rotation is needed
        checkRotation()
    }

    /// Open or create the file handle for appending
    private func openFileHandle() {
        // Create file if it doesn't exist
        if !FileManager.default.fileExists(atPath: filePath) {
            FileManager.default.createFile(atPath: filePath, contents: nil, attributes: nil)
        }

        // Open for appending
        fileHandle = FileHandle(forUpdatingAtPath: filePath)
        fileHandle?.seekToEndOfFile()
    }

    /// Check file size and rotate if needed
    private func checkRotation() {
        guard let handle = fileHandle else { return }

        do {
            let currentOffset = handle.offsetInFile
            if currentOffset > maxFileSize {
                // Close current handle
                try handle.close()
                fileHandle = nil

                // Truncate file (simple rotation strategy)
                try Data().write(to: URL(fileURLWithPath: filePath))

                // Reopen
                openFileHandle()
            }
        } catch {
            // If rotation fails, try to reopen the handle
            fileHandle = nil
            openFileHandle()
        }
    }

    deinit {
        try? fileHandle?.close()
    }
}
