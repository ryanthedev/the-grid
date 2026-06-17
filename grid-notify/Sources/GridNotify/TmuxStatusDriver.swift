import Foundation

// MARK: - TmuxDriverCommand

// Describes the executable + arguments for a single headless claude run.
// Injectable so tests can substitute /usr/bin/true or /bin/sleep without
// spawning a real claude process.
//
// All arguments are hardcoded constants; config values influence cwd
// (repoDir → currentDirectoryURL) and one discrete --model element only.
struct TmuxDriverCommand {

    // Absolute path to the executable (verified at startup).
    let executable: URL
    // Fixed argument list — built from constants, never shell-interpolated.
    let arguments: [String]

    // MARK: - Constants

    // Absolute path to the real Claude Code Mach-O binary.
    // Do NOT use the shell alias — that resolves to a python wrapper.
    static let claudeBinaryPath = "/Users/r/.local/bin/claude"

    // claude-mux MCP server invocation — hardcoded to avoid scatter.
    static let mcpConfigJSON = """
    {"mcpServers":{"claude-mux":{"command":"bun","args":["/Users/r/repos/claude-mux.mcp/server.js"]}}}
    """

    // Fixed allowed tools for the headless run.
    static let allowedTools = "mcp__claude-mux__tmux Write Bash"

    // Builds the canonical claude invocation for the tmux-status skill.
    // repoDir is used only as cwd (currentDirectoryURL), never injected
    // into arguments. model — when present — becomes a discrete argv pair.
    static func claudeDefault(model: String? = nil) -> TmuxDriverCommand {
        var args: [String] = [
            "-p", "/tmux-status",
            "--mcp-config", mcpConfigJSON,
            "--allowedTools", allowedTools,
            "--permission-mode", "bypassPermissions",
        ]
        if let model {
            args += ["--model", model]
        }
        return TmuxDriverCommand(
            executable: URL(fileURLWithPath: claudeBinaryPath),
            arguments: args
        )
    }
}

// MARK: - TmuxStatusDriverError

enum TmuxStatusDriverError: Error, LocalizedError {
    case binaryNotFound(String)
    case binaryNotExecutable(String)
    case spawnFailed(String)

    var errorDescription: String? {
        switch self {
        case .binaryNotFound(let path): return "claude binary not found: \(path)"
        case .binaryNotExecutable(let path): return "claude binary not executable: \(path)"
        case .spawnFailed(let reason): return "spawn failed: \(reason)"
        }
    }
}

// MARK: - TmuxStatusDriver

// Periodic driver that spawns a headless `claude -p "/tmux-status"` run on a
// configured interval and on demand, with a flock(2) + in-process mutex so
// only one run is ever in flight.
//
// Deep module: timer lifecycle, Process management, fd/flock management, and
// timeout enforcement are all hidden behind three public methods.
//
// flock strategy:
//   - Open the lockfile at XDG.stateHome/thegrid/tmux-status.lock (O_CREAT|O_RDWR).
//   - flock(fd, LOCK_EX|LOCK_NB) before each spawn attempt.
//   - On EWOULDBLOCK: log tmux.driver.skip, return (skip the tick).
//   - Hold fd open for the spawned process's lifetime; close in terminationHandler
//     (this releases the advisory lock).
//   - In-process isRunning Bool short-circuits refreshNow() without a syscall.
//
// Timeout: if a spawned process runs longer than hungRunTimeout, it is forcefully
// terminated to prevent resource leaks.
//
// Thread safety: all mutable state protected by a private serial DispatchQueue.
class TmuxStatusDriver {

    // MARK: - Configuration

    private let config: NotifyConfig.Tmux
    private let command: TmuxDriverCommand

    // MARK: - Constants

    // Kill a hung run after this many seconds.
    private static let hungRunTimeout: TimeInterval = 300

    // Default advisory lockfile path.
    static var defaultLockfilePath: String {
        "\(XDG.stateHome)/thegrid/tmux-status.lock"
    }

    // MARK: - Mutable state (queue-protected)

    private var isRunning: Bool = false
    private var lockFd: Int32 = -1
    private var process: Process?
    private var timer: DispatchSourceTimer?
    private var timeoutWorkItem: DispatchWorkItem?
    private var isStarted: Bool = false

    // MARK: - Queue

    private let queue = DispatchQueue(label: "com.thegrid.notify.tmuxdriver")

    // MARK: - Test hooks

    // Override the lockfile path in tests to avoid contention on the global lockfile.
    var _test_lockfilePath: String? = nil
    var _test_spawnCount: Int = 0
    var _test_isRunning: Bool { isRunning }

    private var lockfilePath: String {
        _test_lockfilePath ?? TmuxStatusDriver.defaultLockfilePath
    }

    // MARK: - Init

    init(config: NotifyConfig.Tmux, command: TmuxDriverCommand? = nil) {
        self.config = config
        if let command {
            self.command = command
        } else {
            self.command = TmuxDriverCommand.claudeDefault(model: config.model)
        }
    }

    // MARK: - Public API

    // Starts the driver: validates the binary, performs an immediate run,
    // then schedules repeating runs at config.interval. No-op if already started.
    func start() {
        queue.async { [weak self] in
            guard let self else { return }
            guard !self.isStarted else { return }
            self.isStarted = true
            jlog("tmux.driver.start", data: [
                "interval": self.config.interval,
                "repoDir": self.config.repoDir,
            ])
            guard self.validateBinary() else { return }
            self.attemptRun()
            self.scheduleTimer()
        }
    }

    // Stops the driver: cancels the timer, terminates any in-flight process,
    // and releases the lock. Safe to call when not running.
    func stop() {
        queue.async { [weak self] in
            guard let self else { return }
            guard self.isStarted else { return }
            self.isStarted = false
            jlog("tmux.driver.stop", data: [:])
            self.cancelTimer()
            self.terminateInFlight()
        }
    }

    // Triggers an immediate run if idle; no-op while one is in flight.
    func refreshNow() {
        queue.async { [weak self] in
            guard let self else { return }
            guard !self.isRunning else {
                jlog("tmux.driver.refresh.skip", msg: "run already in flight", data: [:])
                return
            }
            jlog("tmux.driver.refresh", data: [:])
            self.attemptRun()
        }
    }

    // MARK: - Private: binary validation

    // Returns true if the executable exists and is executable.
    // Logs err.tmux.driver.spawn and returns false on failure.
    // Must be called on queue.
    private func validateBinary() -> Bool {
        let path = command.executable.path
        let fm = FileManager.default
        guard fm.fileExists(atPath: path) else {
            jlog("err.tmux.driver.spawn", msg: "binary not found", data: ["path": path])
            return false
        }
        guard fm.isExecutableFile(atPath: path) else {
            jlog("err.tmux.driver.spawn", msg: "binary not executable", data: ["path": path])
            return false
        }
        return true
    }

    // MARK: - Private: timer

    // Schedules a repeating DispatchSourceTimer on the serial queue.
    // Must be called on queue.
    private func scheduleTimer() {
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(
            deadline: .now() + config.interval,
            repeating: config.interval,
            leeway: .seconds(5)
        )
        t.setEventHandler { [weak self] in
            guard let self else { return }
            self.attemptRun()
        }
        t.resume()
        timer = t
        jlog("tmux.driver.timer.start", data: ["interval": config.interval])
    }

    // Cancels and releases the timer.
    // Must be called on queue.
    private func cancelTimer() {
        timer?.cancel()
        timer = nil
    }

    // MARK: - Private: flock + spawn

    // Attempts a single claude run under the flock mutex.
    // If the lock is already held (by another process) or isRunning is true,
    // logs tmux.driver.skip and returns without spawning.
    // Must be called on queue.
    private func attemptRun() {
        guard !isRunning else {
            jlog("tmux.driver.skip", msg: "in-process guard: already running", data: [:])
            return
        }

        // Open (or create) the lockfile.
        let path = lockfilePath
        ensureLockfileDir(path: path)
        let fd = open(path, O_CREAT | O_RDWR, 0o644 as mode_t)
        guard fd >= 0 else {
            jlog("err.tmux.driver.spawn", msg: "cannot open lockfile",
                 data: ["path": path, "errno": errno])
            return
        }

        // Try to acquire exclusive advisory lock (non-blocking).
        // EWOULDBLOCK means another process holds the lock.
        let lockResult = flock(fd, LOCK_EX | LOCK_NB)
        guard lockResult == 0 else {
            close(fd)
            jlog("tmux.driver.skip", msg: "lock already held", data: ["errno": errno])
            return
        }

        // Lock acquired — store fd and mark as running before spawning.
        lockFd = fd
        isRunning = true
        _test_spawnCount += 1

        spawnProcess()
    }

    // Spawns the headless claude process.
    // Must be called on queue after lock is held and isRunning is true.
    private func spawnProcess() {
        let proc = Process()
        proc.executableURL = command.executable
        proc.arguments = command.arguments
        proc.qualityOfService = .utility

        // cwd = repoDir so .claude/commands/ is discoverable.
        if !config.repoDir.isEmpty {
            proc.currentDirectoryURL = URL(fileURLWithPath: config.repoDir)
        }

        // Discard stdout/stderr — the skill writes the file directly.
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice

        let capturedFd = lockFd

        proc.terminationHandler = { [weak self] p in
            guard let self else {
                // Self deallocated — still release the lock fd.
                if capturedFd >= 0 { close(capturedFd) }
                return
            }
            let exitCode = p.terminationStatus
            let reason = p.terminationReason
            jlog("tmux.driver.run.exit", data: [
                "pid": p.processIdentifier,
                "exit": exitCode,
                "reason": reason == .uncaughtSignal ? "signal" : "exit",
            ])
            self.queue.async { [weak self] in
                guard let self else {
                    if capturedFd >= 0 { close(capturedFd) }
                    return
                }
                self.releaseRun(fd: capturedFd)
            }
        }

        do {
            try proc.run()
            process = proc
            jlog("tmux.driver.run.start", data: [
                "pid": proc.processIdentifier,
                "exe": command.executable.path,
            ])
            scheduleHungRunTimeout()
        } catch {
            // Spawn failed — release lock and reset state immediately.
            jlog("err.tmux.driver.spawn", data: ["err": "\(error)"])
            releaseRun(fd: capturedFd)
        }
    }

    // Schedules a timeout to kill a hung run.
    // Must be called on queue immediately after a successful spawn.
    private func scheduleHungRunTimeout() {
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            guard self.isRunning, let proc = self.process, proc.isRunning else { return }
            jlog("warn.tmux.driver.timeout", msg: "killing hung run",
                 data: ["pid": proc.processIdentifier, "timeout": Self.hungRunTimeout])
            proc.terminate()
        }
        timeoutWorkItem = work
        queue.asyncAfter(deadline: .now() + Self.hungRunTimeout, execute: work)
    }

    // Releases the lock fd and resets in-flight state.
    // Must be called on queue.
    private func releaseRun(fd: Int32) {
        timeoutWorkItem?.cancel()
        timeoutWorkItem = nil
        process = nil
        isRunning = false
        if fd >= 0 {
            // flock is released automatically when the fd is closed.
            close(fd)
        }
        lockFd = -1
    }

    // MARK: - Private: stop helpers

    // Terminates any in-flight process and releases the lock.
    // Closes lockFd immediately (releases the flock) rather than waiting for
    // terminationHandler — stop() must fully release resources synchronously.
    // Must be called on queue.
    private func terminateInFlight() {
        guard isRunning, let proc = process else { return }
        let pid = proc.processIdentifier
        proc.terminate()
        jlog("tmux.driver.run.terminate", data: ["pid": pid])
        // Close the lockFd immediately so the flock is released without waiting
        // for the async terminationHandler.
        let fd = lockFd
        lockFd = -1
        if fd >= 0 { close(fd) }
        // Cancel the timeout since we've already terminated.
        timeoutWorkItem?.cancel()
        timeoutWorkItem = nil
        process = nil
        isRunning = false
    }

    // MARK: - Private: helpers

    // Creates the directory for the lockfile if it does not exist.
    private func ensureLockfileDir(path: String) {
        let dir = (path as NSString).deletingLastPathComponent
        let fm = FileManager.default
        guard !fm.fileExists(atPath: dir) else { return }
        do {
            try fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
        } catch {
            jlog("warn.tmux.driver.lockdir", msg: "cannot create lockfile dir",
                 data: ["dir": dir, "err": "\(error)"])
        }
    }
}
