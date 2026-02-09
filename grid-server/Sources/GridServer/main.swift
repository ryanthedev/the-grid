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

        // Kill any stale grid-terminal from previous server session
        let killTask = Process()
        killTask.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        killTask.arguments = ["-9", "-f", "grid-terminal"]
        try? killTask.run()
        killTask.waitUntilExit()

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
        var shouldShutdown = false

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
            NSApplication.shared.setActivationPolicy(.prohibited)

            // Initialize border system
            let connectionID = SLSMainConnectionID()
            let simpleBorderManager = SimpleBorderManager(connectionID: connectionID)
            let borderEvents = BorderEvents()
            borderEvents.setup(simpleBorderManager: simpleBorderManager)
            messageHandler.simpleBorderManager = simpleBorderManager
            jlog("bdr.init")

            // Initialize StateManager (async) and connect border events
            Task {
                await StateManager.shared.start()
                await StateManager.shared.setBorderEvents(borderEvents)
                jlog("state.init")
            }

            // Initialize BFD hotkey daemon
            // Note: bfdManager captured by shutdown closure - will be stopped on exit
            let bfdManager = BFDManager()
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
                shouldShutdown = true
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
                shouldShutdown = true
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

            // Keep the server running
            while !shouldShutdown {
                RunLoop.current.run(mode: .default, before: Date.distantFuture)
            }

        } catch {
            jlog("err.srv.start", data: ["err": "\(error)"])
            throw ExitCode.failure
        }
    }
}

// Run the command
GridServerCommand.main()
