import ArgumentParser
import Foundation
import AppKit
import Logging


/// No-op log handler to silence legacy Logger calls during migration
struct SilentLogHandler: LogHandler {
    var logLevel: Logger.Level = .critical
    var metadata: Logger.Metadata = [:]
    subscript(metadataKey key: String) -> Logger.Metadata.Value? {
        get { nil }
        set { }
    }
    func log(level: Logger.Level, message: Logger.Message, metadata: Logger.Metadata?, source: String, file: String, function: String, line: UInt) {}
}

/// GridServer - Unix domain socket server for macOS Spaces and Windows API
struct GridServerCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "grid-server",
        abstract: "Unix domain socket server for macOS window management",
        version: "\(GridServerVersion) (\(String(GridServerCommit.prefix(7))))"
    )

    @Option(name: .shortAndLong, help: "Path to the Unix domain socket")
    var socketPath: String = "/tmp/grid-server.sock"

    @Flag(name: .long, help: "Enable periodic heartbeat events for testing")
    var heartbeat: Bool = false

    @Option(name: .long, help: "Heartbeat interval in seconds")
    var heartbeatInterval: Double = 10.0

    // Test-only: after installing crash reporter + logging srv.start, trigger
    // a synthetic fault so we can verify the crash instrumentation path.
    // Accepted values: SIGSEGV, SIGABRT, SIGILL, SIGBUS, SIGFPE, SIGPIPE,
    // NSException, exit-after-startlog.
    @Option(name: .long, help: .hidden)
    var crashTest: String? = nil

    func run() throws {
        // Silence legacy Logger output (components will be migrated to JSONLogger)
        LoggingSystem.bootstrap { _ in SilentLogHandler() }

        // Print log path on startup
        print("logging to \(JSONLogger.shared.getLogPath())")

        // Initialize OpenTelemetry tracing
        Tracing.initialize()

        // Kill any stale grid-picker from previous sessions
        let killPicker = Process()
        killPicker.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        killPicker.arguments = ["-9", "-f", "grid-picker"]
        try? killPicker.run()
        killPicker.waitUntilExit()

        // Remove stale Go CLI mutex file
        let stateDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/state/thegrid")
        let lockPath = stateDir.appendingPathComponent("cli.lock")
        if FileManager.default.fileExists(atPath: lockPath.path) {
            try? FileManager.default.removeItem(at: lockPath)
            jlog("srv.cleanup", data: ["file": lockPath.path])
        }

        // Classify the previous run's exit from the on-disk log BEFORE we
        // write our own srv.start (otherwise our srv.start would be the last
        // line and shadow the prior run).
        let prevExit = PrevExitClassifier.classify(
            jsonlTail: PrevExitClassifier.readTail(path: JSONLogger.shared.getLogPath())
        )
        jlog("srv.prev_exit", data: ["exit": prevExit.rawValue])

        // Install crash-exit instrumentation: fatal-signal handlers,
        // NSSetUncaughtExceptionHandler, atexit. Do this before srv.start so
        // a crash in component init still produces a srv.fatal line.
        CrashReporter.install()

        // Log server start
        jlog("srv.start", data: ["ver": GridServerVersion, "commit": GridServerCommit, "socket": socketPath])

        // Test-only: optionally trigger a synthetic fault and exit. Used by
        // crash-instrumentation tests to verify DW-1.1 / DW-1.2 / DW-1.3 / DW-1.5.
        if let mode = crashTest {
            triggerCrashTest(mode: mode)
            return
        }

        // Check for Accessibility permission
        if !PermissionChecker.checkAccessibilityPermission() {
            jlog("warn.ax.permission")
            jlog("ax.permission.request")
            PermissionChecker.requestAccessibilityPermission()
        }

        // Create components (logger kept temporarily for components not yet converted)
        let logger = Logger(label: "com.thegrid.server")
        let messageHandler = MessageHandler(logger: logger)
        let eventBroadcaster = EventBroadcaster(logger: logger)
        let socketServer = SocketServer(socketPath: socketPath, logger: logger)

        // Wire up components
        socketServer.messageHandler = messageHandler
        socketServer.eventBroadcaster = eventBroadcaster
        eventBroadcaster.setSocketServer(socketServer)

        // Set up signal handling for graceful shutdown
        // Note: Handlers are re-wired after BFD initialization to include bfdManager cleanup
        let signalQueue = DispatchQueue(label: "com.thegrid.signals")
        let signalSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: signalQueue)
        signalSource.resume()
        signal(SIGINT, SIG_IGN)

        let termSignalSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: signalQueue)
        termSignalSource.resume()
        signal(SIGTERM, SIG_IGN)

        // Start server
        do {
            try socketServer.start()

            // Initialize NSApplication for NSWorkspace notifications
            _ = NSApplication.shared
            NSApplication.shared.setActivationPolicy(.accessory)

            // Initialize border system
            let connectionID = SLSMainConnectionID()
            let simpleBorderManager = SimpleBorderManager(connectionID: connectionID)
            let borderEvents = BorderEvents()
            borderEvents.setup(simpleBorderManager: simpleBorderManager)
            messageHandler.simpleBorderManager = simpleBorderManager
            jlog("bdr.init")

            // Initialize GridConfig (replaces ServerConfig)
            let gridConfig = GridConfig()

            // Initialize GridState. Persisted state is loaded inside the wiring
            // Task below, BEFORE the reconciler registers with EventRouter (#45),
            // so an early windowCreated/layout-apply cannot be clobbered by a
            // late load() that wholesale-replaces spaces.
            let gridState = GridState()

            // Load config on @MainActor so that:
            // - gridConfig.onReload (MainActor-isolated) can be assigned safely
            Task { @MainActor in
                do {
                    try await gridConfig.load()
                    jlog("grid.cfg.ready")
                } catch {
                    jlog("err.grid.cfg", data: ["err": "\(error)"])
                }
            }

            // Initialize GridReconciler (wired after StateManager starts)
            let gridReconciler = GridReconciler()

            // Initialize StateManager (async) and connect border events + reconciler
            Task {
                // #45: load persisted grid state BEFORE wiring the reconciler.
                // load() is cheap (a single JSON decode) and replaces `spaces`
                // wholesale, so it must complete before any event handler or
                // command can mutate in-memory state.
                await gridState.load()

                await StateManager.shared.start(gridConfig: gridConfig)
                await StateManager.shared.setBorderEvents(borderEvents)
                jlog("state.init")

                // Wire reconciler after StateManager is ready
                gridReconciler.setup(
                    gridState: gridState,
                    gridConfig: gridConfig,
                    stateProvider: StateManager.shared,
                    borderRenderer: simpleBorderManager
                )

                // Instantiate StateValidator and wire into reconciler for on-wake calls
                let stateValidator = StateValidator(
                    gridState: gridState,
                    stateProvider: StateManager.shared,
                    connectionID: connectionID
                )
                gridReconciler.setValidator(stateValidator)

                // Start periodic 30-second validation timer
                await stateValidator.start()

                jlog("validate.init")
            }

            // Initialize Grid feature modules + command router
            let gridFocus = GridFocus()
            let gridCellOps = GridCellOps()
            let gridWindowMove = GridWindowMove()
            let gridApply = GridApply()
            let gridResize = GridResize()
            let gridNudge = GridNudge()
            let windowManipulator = WindowManipulator(connectionID: connectionID)

            // Configure PickerManager with window manipulator for focus restoration
            PickerManager.shared.configure(with: gridConfig, windowManipulator: windowManipulator, gridReconciler: gridReconciler, gridState: gridState)

            let gridRecorder = GridRecorder(
                gridState: gridState,
                gridConfig: gridConfig,
                stateManager: StateManager.shared
            )

            let gridTerminalManager = GridTerminalManager(
                windowManipulator: windowManipulator,
                stateManager: StateManager.shared,
                gridReconciler: gridReconciler
            )

            let commandRouter = GridCommandRouter(
                gridFocus: gridFocus,
                gridCellOps: gridCellOps,
                gridWindowMove: gridWindowMove,
                gridApply: gridApply,
                gridResize: gridResize,
                gridNudge: gridNudge,
                gridState: gridState,
                gridConfig: gridConfig,
                stateManager: StateManager.shared,
                windowManipulator: windowManipulator,
                gridReconciler: gridReconciler,
                simpleBorderManager: simpleBorderManager,
                gridRecorder: gridRecorder,
                gridTerminalManager: gridTerminalManager
            )

            // Serial command executor (Phase 1 serialization seam). Wraps the router
            // so all command ingress (RPC + BFD hotkeys) runs one body at a time.
            let commandExecutor = CommandExecutor(runner: commandRouter)

            // Register Grid RPC handlers (thin CLI bridge)
            messageHandler.registerGridHandlers(
                router: commandRouter,
                executor: commandExecutor,
                gridState: gridState,
                gridConfig: gridConfig,
                stateManager: StateManager.shared
            )

            // #49: registration is complete — grid.* methods no longer 404 in
            // the startup window; the dict is fully populated and guarded.
            messageHandler.finalizeRegistration()

            // Reapply layouts on startup to reposition windows after server restart.
            // Runs after all modules are wired, with a brief delay to let
            // StateManager finish its initial poll cycle.
            Task {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                let errors = await gridApply.refreshAllDisplays()
                if errors.isEmpty {
                    jlog("srv.layout.restore")
                } else {
                    jlog("srv.layout.restore", data: [
                        "errors": errors.count,
                    ])
                }
            }

            // Initialize BFD hotkey daemon
            // Note: bfdManager captured by shutdown closure - will be stopped on exit
            let bfdManager = BFDManager()
            BFDManager.shared = bfdManager
            bfdManager.setCommandRouter(commandRouter)
            bfdManager.setCommandExecutor(commandExecutor)
            Task {
                if await bfdManager.start() {
                    jlog("bfd.ready")
                } else {
                    jlog("warn.bfd.init", msg: "Failed to start BFD")
                }
            }

            // Update shutdown handler to include BFD cleanup
            // Re-wire the signal handlers with bfdManager in scope
            signalSource.setEventHandler {
                jlog("srv.sig.int")
                Task {
                    await StateManager.shared.shutdown()
                    bfdManager.stop()
                    socketServer.stop()
                    jlog("srv.shutdown.done")
                    Darwin.exit(0)
                }
            }
            termSignalSource.setEventHandler {
                jlog("srv.sig.term")
                Task {
                    await StateManager.shared.shutdown()
                    bfdManager.stop()
                    socketServer.stop()
                    jlog("srv.shutdown.done")
                    Darwin.exit(0)
                }
            }

            // Start heartbeat if requested
            if heartbeat {
                eventBroadcaster.startHeartbeat(interval: heartbeatInterval)
            }

            jlog("srv.ready")

            // Run the NSApplication event loop.
            // Required when launched via `open -a` so macOS treats us as a
            // responsive GUI app and delivers keyboard/mouse events properly.
            NSApp.run()

        } catch {
            jlog("err.srv.start", data: ["err": "\(error)"])
            throw ExitCode.failure
        }
    }
}

/// Test-only fault injector used by `--crash-test=<mode>`. Invoked after
/// CrashReporter is installed and srv.start is logged; raises the requested
/// fault and never returns (for signal modes and NSException). For
/// `exit-after-startlog`, writes a final srv.shutdown.done and returns so the
/// caller can Darwin.exit(0) through the normal path.
func triggerCrashTest(mode: String) {
    switch mode {
    case "SIGSEGV": raise(SIGSEGV)
    case "SIGABRT": raise(SIGABRT)
    case "SIGILL":  raise(SIGILL)
    case "SIGBUS":  raise(SIGBUS)
    case "SIGFPE":  raise(SIGFPE)
    case "SIGPIPE": raise(SIGPIPE)
    case "NSException":
        // Raise on a background queue so the uncaught handler path is exercised
        // exactly like a real escaped ObjC exception.
        DispatchQueue.global().async {
            NSException(name: .init("CrashTestException"), reason: "synthetic", userInfo: nil).raise()
        }
        // Give the async raise time to terminate the process through the
        // uncaught handler. If we return first, the test harness would see
        // a clean exit.
        sleep(5)
    case "exit-after-startlog":
        // Used by DW-1.5: a second run that only needs to emit srv.prev_exit
        // before exiting, so the test can check the prev-exit classification.
        jlog("srv.shutdown.done")
        // Give JSONLogWriter a beat to flush before we exit.
        usleep(300_000)
        Darwin.exit(0)
    default:
        jlog("warn.crash.test", msg: "unknown crash-test mode", data: ["mode": mode])
    }
    // Belt-and-suspenders: if somehow the signal didn't kill us, hang so the
    // test observes no clean exit rather than a false-positive pass.
    sleep(10)
}

// Run the command
GridServerCommand.main()
