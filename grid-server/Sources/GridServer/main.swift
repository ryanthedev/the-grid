import ArgumentParser
import Foundation
import AppKit
import Logging

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
        // Delete old log file to start fresh
        let logFilePath = "grid-server.log"
        try? FileManager.default.removeItem(atPath: logFilePath)

        // Set up logging with both console and file output
        LoggingSystem.bootstrap { label in
            // Create console handler
            var consoleHandler = StreamLogHandler.standardOutput(label: label)

            // Create file handler
            var fileHandler = FileLogHandler(label: label, filePath: logFilePath)

            // Set log level for both handlers
            let level: Logger.Level
            if debug {
                level = .debug
            } else if verbose {
                level = .info
            } else {
                level = .notice
            }

            consoleHandler.logLevel = level
            fileHandler.logLevel = level

            // Combine both handlers
            return MultiplexLogHandler(handlers: [consoleHandler, fileHandler])
        }

        let logger = Logger(label: "com.thegrid.server")

        logger.notice("Starting GridServer", metadata: [
            "version": "0.1.0",
            "socketPath": "\(socketPath)"
        ])

        // Check for Accessibility permission
        if !PermissionChecker.checkAccessibilityPermission() {
            logger.warning("Running without Accessibility permission - window queries may not work")
            logger.notice("Requesting permission (dialog may appear)...")
            PermissionChecker.requestAccessibilityPermission()
        }

        // Create components
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
            logger.notice("Received SIGINT, shutting down...")
            shouldShutdown = true
            socketServer.stop()
            Darwin.exit(0)
        }
        signalSource.resume()
        signal(SIGINT, SIG_IGN)

        let termSignalSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: signalQueue)
        termSignalSource.setEventHandler {
            logger.notice("Received SIGTERM, shutting down...")
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
            // This is required for space change notifications to fire
            _ = NSApplication.shared
            NSApplication.shared.setActivationPolicy(.prohibited)
            logger.info("✓ NSApplication initialized for workspace notifications")

            // Initialize StateManager
            logger.info("Initializing StateManager...")
            StateManager.shared.start()
            logger.notice("StateManager initialization started")

            // Start heartbeat if requested
            if heartbeat {
                eventBroadcaster.startHeartbeat(interval: heartbeatInterval)
            }

            logger.notice("Server is running. Press Ctrl+C to stop.")

            // Keep the server running
            while !shouldShutdown {
                RunLoop.current.run(mode: .default, before: Date.distantFuture)
            }

        } catch {
            logger.error("Failed to start server", metadata: ["error": "\(error)"])
            throw ExitCode.failure
        }
    }
}

/// Custom log handler that writes to stdout
struct StreamLogHandler: LogHandler {
    var logLevel: Logger.Level = .info
    var metadata: Logger.Metadata = [:]

    private let label: String
    private let stream: TextOutputStream

    init(label: String, stream: TextOutputStream) {
        self.label = label
        self.stream = stream
    }

    static func standardOutput(label: String) -> StreamLogHandler {
        return StreamLogHandler(label: label, stream: StdoutOutputStream())
    }

    func log(
        level: Logger.Level,
        message: Logger.Message,
        metadata: Logger.Metadata?,
        source: String,
        file: String,
        function: String,
        line: UInt
    ) {
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let levelStr = levelString(level)

        var output = "[\(timestamp)] [\(levelStr)] \(message)"

        let combinedMetadata = self.metadata.merging(metadata ?? [:]) { _, new in new }
        if !combinedMetadata.isEmpty {
            let metadataStr = combinedMetadata
                .map { "\($0.key)=\($0.value)" }
                .joined(separator: " ")
            output += " | \(metadataStr)"
        }

        var stream = self.stream
        stream.write(output + "\n")
    }

    subscript(metadataKey key: String) -> Logger.Metadata.Value? {
        get { metadata[key] }
        set { metadata[key] = newValue }
    }

    private func levelString(_ level: Logger.Level) -> String {
        switch level {
        case .trace: return "TRACE"
        case .debug: return "DEBUG"
        case .info: return "INFO"
        case .notice: return "NOTICE"
        case .warning: return "WARN"
        case .error: return "ERROR"
        case .critical: return "CRITICAL"
        }
    }
}

struct StdoutOutputStream: TextOutputStream {
    func write(_ string: String) {
        print(string, terminator: "")
    }
}

/// Custom log handler that writes to a file asynchronously
struct FileLogHandler: LogHandler {
    var logLevel: Logger.Level = .info
    var metadata: Logger.Metadata = [:]

    private let label: String
    private let filePath: String
    private let writeQueue: DispatchQueue

    init(label: String, filePath: String) {
        self.label = label
        self.filePath = filePath
        self.writeQueue = DispatchQueue(label: "com.thegrid.filelogger", qos: .background)
    }

    func log(
        level: Logger.Level,
        message: Logger.Message,
        metadata: Logger.Metadata?,
        source: String,
        file: String,
        function: String,
        line: UInt
    ) {
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let levelStr = levelString(level)

        var output = "[\(timestamp)] [\(levelStr)] \(message)"

        let combinedMetadata = self.metadata.merging(metadata ?? [:]) { _, new in new }
        if !combinedMetadata.isEmpty {
            let metadataStr = combinedMetadata
                .map { "\($0.key)=\($0.value)" }
                .joined(separator: " ")
            output += " | \(metadataStr)"
        }

        let logLine = output + "\n"
        let filePath = self.filePath

        // Write to file asynchronously to avoid blocking
        writeQueue.async {
            guard let data = logLine.data(using: .utf8) else { return }

            if !FileManager.default.fileExists(atPath: filePath) {
                FileManager.default.createFile(atPath: filePath, contents: nil, attributes: nil)
            }

            if let fileHandle = FileHandle(forWritingAtPath: filePath) {
                fileHandle.seekToEndOfFile()
                fileHandle.write(data)
                fileHandle.closeFile()
            }
        }
    }

    subscript(metadataKey key: String) -> Logger.Metadata.Value? {
        get { metadata[key] }
        set { metadata[key] = newValue }
    }

    private func levelString(_ level: Logger.Level) -> String {
        switch level {
        case .trace: return "TRACE"
        case .debug: return "DEBUG"
        case .info: return "INFO"
        case .notice: return "NOTICE"
        case .warning: return "WARN"
        case .error: return "ERROR"
        case .critical: return "CRITICAL"
        }
    }
}

/// Multiplex log handler that sends logs to multiple handlers
struct MultiplexLogHandler: LogHandler {
    private var handlers: [LogHandler]

    var logLevel: Logger.Level {
        get {
            handlers.first?.logLevel ?? .info
        }
        set {
            for i in handlers.indices {
                handlers[i].logLevel = newValue
            }
        }
    }

    var metadata: Logger.Metadata {
        get {
            handlers.first?.metadata ?? [:]
        }
        set {
            for i in handlers.indices {
                handlers[i].metadata = newValue
            }
        }
    }

    init(handlers: [LogHandler]) {
        self.handlers = handlers
    }

    func log(
        level: Logger.Level,
        message: Logger.Message,
        metadata: Logger.Metadata?,
        source: String,
        file: String,
        function: String,
        line: UInt
    ) {
        for handler in handlers {
            handler.log(
                level: level,
                message: message,
                metadata: metadata,
                source: source,
                file: file,
                function: function,
                line: line
            )
        }
    }

    subscript(metadataKey key: String) -> Logger.Metadata.Value? {
        get {
            handlers.first?[metadataKey: key]
        }
        set {
            for i in handlers.indices {
                handlers[i][metadataKey: key] = newValue
            }
        }
    }
}

// Run the command
GridServerCommand.main()
