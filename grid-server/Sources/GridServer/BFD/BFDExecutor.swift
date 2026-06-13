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

            // Set up timeout (30 seconds)
            let timeoutSeconds: TimeInterval = 30
            let timeout = DispatchWorkItem {
                if process.isRunning {
                    process.terminate()
                    BFDLogger.logError(
                        "Command timed out after \(Int(timeoutSeconds))s",
                        hotkey: hotkey
                    )
                }
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeoutSeconds, execute: timeout)

            // #38: read BOTH pipes concurrently with waitUntilExit. A command
            // that writes more than the ~64KB pipe buffer blocks on write until
            // someone drains it; calling waitUntilExit() first (the old code)
            // deadlocks and the 30s timeout then kills a valid verbose command.
            // Read on background threads (mirrors EnrichmentTypes.runProcess),
            // then wait. The readers finish when the process closes its fds.
            var stdoutData = Data()
            var stderrData = Data()
            let readGroup = DispatchGroup()
            readGroup.enter()
            DispatchQueue.global().async {
                stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
                readGroup.leave()
            }
            readGroup.enter()
            DispatchQueue.global().async {
                stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
                readGroup.leave()
            }

            process.waitUntilExit()
            timeout.cancel()
            // Both reads complete once the child's fds are closed (at/after exit).
            readGroup.wait()

            let stdout = String(data: stdoutData, encoding: .utf8) ?? ""
            let stderr = String(data: stderrData, encoding: .utf8) ?? ""

            let durationMs = Int(Date().timeIntervalSince(startTime) * 1000)

            BFDLogger.log(
                hotkey: hotkey,
                command: command,
                expanded: expanded,
                stdout: stdout.trimmingCharacters(in: .whitespacesAndNewlines),
                stderr: stderr.trimmingCharacters(in: .whitespacesAndNewlines),
                exitCode: process.terminationStatus,
                durationMs: durationMs
            )
        } catch {
            BFDLogger.logError(
                "Failed to execute: \(error.localizedDescription)",
                hotkey: hotkey
            )
        }
    }

    /// Execute command asynchronously (fire and forget with logging)
    func executeAsync(hotkey: String, command: String) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.execute(hotkey: hotkey, command: command)
        }
    }
}
