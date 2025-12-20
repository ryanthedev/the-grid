import Foundation

/// Executes commands and captures output
class BFDExecutor {
    let shell: String
    let config: BFDConfig

    init(config: BFDConfig) {
        self.shell = config.shell
        self.config = config
    }

    /// Execute a command and log the result
    func execute(hotkey: String, command: String) {
        let expanded = config.expandVars(command)
        let startTime = Date()

        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        process.arguments = ["-c", expanded]

        // Detach from terminal
        process.standardInput = FileHandle.nullDevice

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        do {
            try process.run()
            process.waitUntilExit()

            let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
            let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            let stdout = String(data: stdoutData, encoding: .utf8) ?? ""
            let stderr = String(data: stderrData, encoding: .utf8) ?? ""

            let durationMs = Int(Date().timeIntervalSince(startTime) * 1000)

            Task {
                await BFDLogger.shared.log(
                    hotkey: hotkey,
                    command: command,
                    expanded: expanded,
                    stdout: stdout.trimmingCharacters(in: .whitespacesAndNewlines),
                    stderr: stderr.trimmingCharacters(in: .whitespacesAndNewlines),
                    exitCode: process.terminationStatus,
                    durationMs: durationMs
                )
            }
        } catch {
            Task {
                await BFDLogger.shared.logError(
                    "Failed to execute: \(error.localizedDescription)",
                    hotkey: hotkey
                )
            }
        }
    }

    /// Execute command asynchronously (fire and forget with logging)
    func executeAsync(hotkey: String, command: String) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.execute(hotkey: hotkey, command: command)
        }
    }
}
