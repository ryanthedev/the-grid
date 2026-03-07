//
// ActionExecutor.swift
// GridServer
//
// Stateless executor that routes and performs picker actions.
// Hides subprocess mechanics: clean env, tmux session creation,
// Chrome profile args, process spawning.
//

import AppKit

/// Routes and executes picker actions by type.
/// All methods are static -- no state needed.
struct ActionExecutor {

    /// Execute the given picker action
    static func execute(_ action: PickerAction) {
        switch action {
        case .focusWindow(let pid, let windowID):
            let connectionID = SLSMainConnectionID()
            let manipulator = WindowManipulator(connectionID: connectionID)
            let success = manipulator.focusWindow(pid: pid, windowID: windowID)
            jlog("pick.focus", data: [
                "pid": "\(pid)",
                "wid": "\(windowID)",
                "ok": "\(success)"
            ])

        case .openApp(let bundleID):
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
                NSWorkspace.shared.openApplication(
                    at: url,
                    configuration: NSWorkspace.OpenConfiguration()
                ) { _, error in
                    if let error = error {
                        jlog("pick.err.open", data: ["bundle": bundleID, "err": "\(error)"])
                    }
                }
            }

        case .openChromeProfile(let profileDir):
            // open -na "Google Chrome" --args --profile-directory="Profile 1"
            spawnDetached("/usr/bin/open", args: [
                "-na", "Google Chrome", "--args",
                "--profile-directory=" + profileDir
            ], cleanEnv: true)

        case .exec(let command):
            // Run command via user's shell with clean environment
            let shell = userShell()
            spawnDetached(shell, args: ["-c", command], cleanEnv: true)

        case .openDir(let dirPath):
            // Create or attach tmux session, open in Ghostty
            // Must run async because tmux commands need to be awaited
            Task {
                await openDirInTmux(dirPath)
            }
        }
    }

    // MARK: - Private Helpers

    /// Open a directory in a tmux session via Ghostty
    private static func openDirInTmux(_ dirPath: String) async {
        let sessionName = sanitizeTmuxName((dirPath as NSString).lastPathComponent)
        let tmuxPath = findTmux()

        // Boost zoxide frecency (best-effort, fire-and-forget)
        if let zoxide = findZoxideBinary() {
            _ = await runProcess(zoxide, args: ["add", dirPath])
        }

        // Check if session exists (await -- need exit status)
        let hasSession = await runProcess(tmuxPath, args: ["has-session", "-t", sessionName])

        if hasSession == nil {
            // Session doesn't exist -- create new detached session
            _ = await runProcess(tmuxPath, args: [
                "new-session", "-d", "-s", sessionName, "-c", dirPath
            ])
        }

        // Open Ghostty with tmux attach (fire-and-forget)
        let shell = userShell()
        let attachCmd = tmuxPath + " attach -t " + sessionName
        spawnDetached("/usr/bin/open", args: [
            "-na", "Ghostty", "--args",
            "--title=" + sessionName,
            "--command=" + shell + " -l -c '" + attachCmd + "'"
        ], cleanEnv: true)
    }

    /// Get user's default shell
    private static func userShell() -> String {
        return ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
    }

    /// Clean environment (strip TMUX vars to prevent inheriting session)
    private static func cleanEnvironment() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        env.removeValue(forKey: "TMUX")
        env.removeValue(forKey: "TMUX_PANE")
        env.removeValue(forKey: "TMUX_PLUGIN_MANAGER_PATH")
        return env
    }

    /// Sanitize tmux session name (no dots or colons)
    private static func sanitizeTmuxName(_ name: String) -> String {
        return name
            .replacingOccurrences(of: ".", with: "_")
            .replacingOccurrences(of: ":", with: "_")
    }

    /// Find zoxide binary (same pattern as findTmux)
    private static func findZoxideBinary() -> String? {
        let home = NSHomeDirectory()
        let candidates = [
            home + "/.cargo/bin/zoxide",
            "/opt/homebrew/bin/zoxide",
            "/usr/local/bin/zoxide"
        ]
        for path in candidates {
            if FileManager.default.isExecutableFile(atPath: path) {
                return path
            }
        }
        return nil
    }

    /// Spawn a process detached, don't wait for result.
    /// Runs on DispatchQueue.global() to avoid blocking the main thread.
    private static func spawnDetached(_ exe: String, args: [String], cleanEnv: Bool = false) {
        DispatchQueue.global().async {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: exe)
            process.arguments = args
            if cleanEnv {
                process.environment = cleanEnvironment()
            }
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            do {
                try process.run()
                // Don't waitUntilExit -- fire and forget
            } catch {
                jlog("pick.exec.err", data: ["exe": exe, "err": error.localizedDescription])
            }
        }
    }
}
