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

        // Log server start
        jlog("srv.start", data: ["ver": GridServerVersion, "commit": GridServerCommit, "socket": socketPath])

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
            Task {
                do {
                    try await gridConfig.load()
                    jlog("grid.cfg.ready")
                } catch {
                    jlog("err.grid.cfg", data: ["err": "\(error)"])
                }
            }

            // Initialize GridState (load persisted state)
            let gridState = GridState()
            Task {
                await gridState.load()
            }

            // Load notification store (persisted notifications)
            Task {
                await NotificationStore.shared.load()
                jlog("notify.store.ready")
            }

            // Instantiate notification event handler with empty config (no event notifications
            // by default -- opt-in). Phase 5 will wire config from YAML.
            let notificationEventConfig = NotificationEventConfig()
            let notificationEventHandler = NotificationEventHandler(
                store: NotificationStore.shared,
                config: notificationEventConfig
            )
            // NotificationEventHandler self-registers with EventRouter in its init Task

            // Instantiate notification file watcher with empty path (disabled by default).
            // Phase 5 will wire the path from YAML.
            let notificationWatcherConfig = NotificationWatcherConfig()
            let notificationFileWatcher = NotificationFileWatcher(
                store: NotificationStore.shared,
                config: notificationWatcherConfig
            )
            // No-op if path is empty
            notificationFileWatcher.start()

            // Initialize GridReconciler (wired after StateManager starts)
            let gridReconciler = GridReconciler()

            // Initialize StateManager (async) and connect border events + reconciler
            Task {
                await StateManager.shared.start(gridConfig: gridConfig)
                await StateManager.shared.setBorderEvents(borderEvents)
                jlog("state.init")

                // Wire reconciler after StateManager is ready
                gridReconciler.setup(
                    gridState: gridState,
                    gridConfig: gridConfig,
                    stateManager: StateManager.shared,
                    simpleBorderManager: simpleBorderManager
                )

                // Instantiate StateValidator and wire into reconciler for on-wake calls
                let stateValidator = StateValidator(
                    gridState: gridState,
                    stateManager: StateManager.shared,
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
                gridTerminalManager: gridTerminalManager,
                notificationStore: NotificationStore.shared
            )

            // Register Grid RPC handlers (thin CLI bridge)
            messageHandler.registerGridHandlers(
                router: commandRouter,
                gridState: gridState,
                gridConfig: gridConfig,
                stateManager: StateManager.shared
            )

            // Initialize BFD hotkey daemon
            // Note: bfdManager captured by shutdown closure - will be stopped on exit
            let bfdManager = BFDManager()
            BFDManager.shared = bfdManager
            bfdManager.setCommandRouter(commandRouter)
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
                    notificationFileWatcher.stop()
                    await notificationEventHandler.stop()
                    await NotificationStore.shared.flush()
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
                    notificationFileWatcher.stop()
                    await notificationEventHandler.stop()
                    await NotificationStore.shared.flush()
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

// Run the command
GridServerCommand.main()
