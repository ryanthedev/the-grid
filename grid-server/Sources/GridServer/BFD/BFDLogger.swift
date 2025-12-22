import Foundation

/// BFD logging via unified JSONLogger
enum BFDLogger {
    /// Log a hotkey execution with full details
    static func log(
        hotkey: String,
        command: String,
        expanded: String,
        stdout: String,
        stderr: String,
        exitCode: Int32,
        durationMs: Int
    ) {
        var data: [String: Any] = [
            "hk": hotkey,
            "cmd": command,
            "exp": expanded,
            "exit": exitCode,
            "ms": durationMs
        ]
        // Truncate long output
        let outTrunc = String(stdout.prefix(500))
        let errTrunc = String(stderr.prefix(500))
        if !outTrunc.isEmpty { data["out"] = outTrunc }
        if !errTrunc.isEmpty { data["err"] = errTrunc }

        jlog("bfd.exec", data: data)
    }

    /// Log an error
    static func logError(_ message: String, hotkey: String? = nil) {
        var data: [String: Any] = [:]
        if let hk = hotkey { data["hk"] = hk }
        jlog("bfd.error", msg: message, data: data.isEmpty ? nil : data)
    }
}
