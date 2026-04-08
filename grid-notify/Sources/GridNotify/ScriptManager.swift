import Foundation

// Manages external scripts as supervised child processes.
// Launches on startup, restarts on crash, kills on app quit.
// Each script is identified by a name and configured with a path + arguments.
class ScriptManager {

    struct ScriptConfig {
        let name: String
        let path: String
        let arguments: [String]
        // Restart delay after crash (seconds). 0 = don't restart.
        let restartDelay: TimeInterval
    }

    private var processes: [String: Process] = [:]
    private var configs: [String: ScriptConfig] = [:]
    private var restartTimers: [String: DispatchWorkItem] = [:]
    private let queue = DispatchQueue(label: "com.thegrid.notify.scripts")

    // Register a script. Does not start it yet.
    func register(_ config: ScriptConfig) {
        configs[config.name] = config
    }

    // Start all registered scripts.
    func startAll() {
        for config in configs.values {
            launchScript(config)
        }
    }

    // Stop all running scripts.
    func stopAll() {
        for (name, _) in configs {
            stopScript(name)
        }
    }

    // Stop a specific script by name.
    func stopScript(_ name: String) {
        // Cancel pending restart
        restartTimers[name]?.cancel()
        restartTimers[name] = nil

        guard let process = processes[name], process.isRunning else {
            processes.removeValue(forKey: name)
            return
        }
        process.terminate()
        processes.removeValue(forKey: name)
        jlog("script.stop", data: ["name": name, "pid": process.processIdentifier])
    }

    private func launchScript(_ config: ScriptConfig) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: config.path)
        process.arguments = config.arguments
        process.qualityOfService = .utility

        // Redirect stdout/stderr to /dev/null — script logs via JSONL file
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        // Watch for termination
        process.terminationHandler = { [weak self] proc in
            guard let self else { return }
            let exitCode = proc.terminationStatus
            let reason = proc.terminationReason

            jlog("script.exit", data: [
                "name": config.name,
                "pid": proc.processIdentifier,
                "exit": exitCode,
                "reason": reason == .uncaughtSignal ? "signal" : "exit",
            ])

            self.queue.async {
                self.processes.removeValue(forKey: config.name)

                // Restart if configured and not intentionally stopped
                if config.restartDelay > 0 {
                    self.scheduleRestart(config)
                }
            }
        }

        do {
            try process.run()
            processes[config.name] = process
            jlog("script.start", data: [
                "name": config.name,
                "pid": process.processIdentifier,
                "path": config.path,
            ])
        } catch {
            jlog("err.script.launch", data: [
                "name": config.name,
                "path": config.path,
                "err": "\(error)",
            ])
        }
    }

    private func scheduleRestart(_ config: ScriptConfig) {
        let work = DispatchWorkItem { [weak self] in
            jlog("script.restart", data: ["name": config.name, "delay": config.restartDelay])
            self?.launchScript(config)
        }
        restartTimers[config.name] = work
        queue.asyncAfter(deadline: .now() + config.restartDelay, execute: work)
    }
}
