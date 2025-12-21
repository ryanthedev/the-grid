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
        version: "0.1.0"
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

        // Log server start
        jlog("srv.start", data: ["ver": "0.1.0", "socket": socketPath])

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
        let signalQueue = DispatchQueue(label: "com.thegrid.signals")
        var shouldShutdown = false

        let signalSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: signalQueue)
        signalSource.setEventHandler {
            jlog("srv.sig.int")
            shouldShutdown = true
            socketServer.stop()
            Darwin.exit(0)
        }
        signalSource.resume()
        signal(SIGINT, SIG_IGN)

        let termSignalSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: signalQueue)
        termSignalSource.setEventHandler {
            jlog("srv.sig.term")
            shouldShutdown = true
            socketServer.stop()
            Darwin.exit(0)
        }
        termSignalSource.resume()
        signal(SIGTERM, SIG_IGN)

        // Start server
        do {
            try socketServer.start()

            // Initialize NSApplication for NSWorkspace notifications
            _ = NSApplication.shared
            NSApplication.shared.setActivationPolicy(.prohibited)

            // Initialize StateManager
            StateManager.shared.start()
            jlog("state.init")

            // Initialize border system
            let connectionID = SLSMainConnectionID()
            let simpleBorderManager = SimpleBorderManager(connectionID: connectionID)
            let borderEvents = BorderEvents()
            borderEvents.setup(simpleBorderManager: simpleBorderManager, stateManager: StateManager.shared)
            StateManager.shared.borderEvents = borderEvents
            messageHandler.simpleBorderManager = simpleBorderManager
            jlog("bdr.init")

            // Initialize BFD hotkey daemon
            let bfdManager = BFDManager()
            if bfdManager.start() {
                jlog("bfd.ready")
            } else {
                jlog("warn.bfd.init", msg: "Failed to start BFD")
            }

            // Start heartbeat if requested
            if heartbeat {
                eventBroadcaster.startHeartbeat(interval: heartbeatInterval)
            }

            jlog("srv.ready")

            // Start auto-layout in background (don't block startup)
            AutoLayoutManager.shared.applyStartupLayoutsAsync()
            jlog("autolayout.init")

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
