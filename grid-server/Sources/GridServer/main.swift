import ArgumentParser
import Foundation
import AppKit
import Logging

/// Helper to log events synchronously from non-async contexts
func log(_ event: String, _ data: [String: Any] = [:]) {
    Task { await EventLog.shared.log(event, data) }
}

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

    @Flag(name: .shortAndLong, help: "Enable verbose logging")
    var verbose: Bool = false

    @Flag(name: .shortAndLong, help: "Enable debug logging")
    var debug: Bool = false

    @Flag(name: .long, help: "Enable periodic heartbeat events for testing")
    var heartbeat: Bool = false

    @Option(name: .long, help: "Heartbeat interval in seconds")
    var heartbeatInterval: Double = 10.0

    func run() throws {
        // Silence legacy Logger output (components will be migrated to EventLog)
        LoggingSystem.bootstrap { _ in SilentLogHandler() }

        // Log server start
        log("srv.start", ["ver": "0.1.0", "socket": socketPath])

        // Check for Accessibility permission
        if !PermissionChecker.checkAccessibilityPermission() {
            log("warn.ax.permission")
            log("ax.permission.request")
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
            log("srv.sig.int")
            shouldShutdown = true
            socketServer.stop()
            Darwin.exit(0)
        }
        signalSource.resume()
        signal(SIGINT, SIG_IGN)

        let termSignalSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: signalQueue)
        termSignalSource.setEventHandler {
            log("srv.sig.term")
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
            log("state.init")

            // Initialize border system
            let connectionID = SLSMainConnectionID()
            let simpleBorderManager = SimpleBorderManager(connectionID: connectionID)
            let borderEvents = BorderEvents()
            borderEvents.setup(simpleBorderManager: simpleBorderManager, stateManager: StateManager.shared)
            StateManager.shared.borderEvents = borderEvents
            messageHandler.simpleBorderManager = simpleBorderManager
            log("bdr.init")

            // Start heartbeat if requested
            if heartbeat {
                eventBroadcaster.startHeartbeat(interval: heartbeatInterval)
            }

            log("srv.ready")

            // Keep the server running
            while !shouldShutdown {
                RunLoop.current.run(mode: .default, before: Date.distantFuture)
            }

        } catch {
            log("err.srv.start", ["err": "\(error)"])
            throw ExitCode.failure
        }
    }
}

// Run the command
GridServerCommand.main()
