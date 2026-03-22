import Foundation

// MARK: - NotificationLineDescriptor

// Codable struct for parsing a single notification line.
// Defined privately here -- not part of the public interface.
private struct NotificationLineDescriptor: Codable {
    let title: String
    let body: String?
    let priority: String?
    // action is a flat string-to-string dict for simplicity:
    // { "type": "focusWindow", "windowID": "123" }
    // { "type": "runShellCommand", "command": "echo hi" }
    // { "type": "openURL", "url": "https://..." }
    let action: [String: String]?
}

// MARK: - NotificationFileWatcher

// Reads line-delimited JSON from a file or named pipe, creating GridNotification
// objects for each valid line. Handles EOF (pipe writer disconnect) by reopening.
// Handles regular file rotation via DispatchSource filesystem events.
//
// Input format per line: JSON object with optional fields:
//   { "title": "...", "body": "...", "priority": "normal", "action": {...} }
// The "title" field is required. Any line failing to parse is silently skipped
// with a log entry.
//
// Deep module: caller provides a path + config, this hides all fd management,
// EOF reopening, and line buffering.
class NotificationFileWatcher {
    private let store: NotificationStore
    private let config: NotificationWatcherConfig

    // File descriptor currently being watched (-1 = watcher stopped)
    private var fd: Int32 = -1
    // DispatchSource for read readability (data available)
    private var readSource: DispatchSourceRead?
    // DispatchSource for filesystem events (file rotation/deletion)
    private var fsSource: DispatchSourceFileSystemObject?
    // Buffer for partial lines between reads
    private var lineBuffer: String = ""
    // Prevents double-start and ensures clean stop
    private var isRunning: Bool = false

    // Private serial queue to protect fd, readSource, fsSource, lineBuffer
    private let queue: DispatchQueue

    init(store: NotificationStore, config: NotificationWatcherConfig) {
        self.store = store
        self.config = config
        self.queue = DispatchQueue(label: "com.thegrid.notify.filewatcher")
    }

    // MARK: - Start / Stop

    // Starts the watcher. No-op if config.path is empty or already running.
    func start() {
        guard !config.path.isEmpty else {
            JSONLogger.shared.log("notify.watcher.skip", msg: "no path configured", data: [:])
            return
        }
        guard !isRunning else { return }
        isRunning = true
        JSONLogger.shared.log("notify.watcher.start", data: ["path": config.path])
        queue.async {
            self.openAndWatch()
        }
    }

    // Stops the watcher and releases all file descriptors.
    func stop() {
        queue.sync {
            self.isRunning = false
            self.tearDown()
        }
        JSONLogger.shared.log("notify.watcher.stop", data: [:])
    }

    // MARK: - Internal: open and wire sources

    // Opens the path and sets up DispatchSource(s).
    // For a regular file: one readSource (data available) + one fsSource (rotation/deletion).
    // For a named pipe (FIFO): one readSource only (pipes don't rotate).
    // Called on self.queue.
    private func openAndWatch() {
        // Open non-blocking so we don't hang on an empty named pipe with no writer
        let openFlags: Int32 = O_RDONLY | O_NONBLOCK
        let newFD = open(config.path, openFlags)
        guard newFD >= 0 else {
            JSONLogger.shared.log("err.notify.watcher.open", data: [
                "path": config.path,
                "errno": errno
            ])
            // Retry after 5 seconds to handle the case where the path doesn't exist yet
            queue.asyncAfter(deadline: .now() + 5) {
                if self.isRunning { self.openAndWatch() }
            }
            return
        }

        fd = newFD

        // Determine if this is a FIFO (named pipe) or a regular file
        var statBuf = stat()
        fstat(fd, &statBuf)
        let isFIFO = (statBuf.st_mode & S_IFMT) == S_IFIFO

        // Set up read source to fire when data is available
        let rs = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        rs.setEventHandler {
            self.handleReadable(isFIFO: isFIFO)
        }
        rs.setCancelHandler {
            // fd is closed in tearDown, not here, to avoid double-close
        }
        rs.resume()
        readSource = rs

        // For regular files, also watch for rotation (delete/rename events)
        if !isFIFO {
            let evtFlags: DispatchSource.FileSystemEvent = [.write, .delete, .rename]
            let fss = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: fd,
                eventMask: evtFlags,
                queue: queue
            )
            fss.setEventHandler {
                self.handleFSEvent()
            }
            fss.resume()
            fsSource = fss
        }

        JSONLogger.shared.log("notify.watcher.opened", data: [
            "path": config.path,
            "fifo": isFIFO
        ])
    }

    // MARK: - Internal: handle readable data

    // Called by readSource when data is available (or EOF on pipe).
    // Reads all available bytes, accumulates into lineBuffer, processes complete lines.
    private func handleReadable(isFIFO: Bool) {
        let bufSize = 4096
        var buf = [UInt8](repeating: 0, count: bufSize)
        let bytesRead = read(fd, &buf, bufSize)

        if bytesRead > 0 {
            // Append new bytes to the line buffer
            let chunk = String(bytes: buf.prefix(bytesRead), encoding: .utf8) ?? ""
            lineBuffer += chunk
            processLines()
        } else if bytesRead == 0 {
            // EOF: writer closed the pipe (or end of regular file)
            // Flush any remaining partial line in the buffer
            if !lineBuffer.isEmpty {
                processLine(lineBuffer)
                lineBuffer = ""
            }

            if isFIFO {
                // Named pipe: writer disconnected. Tear down current fd/source,
                // then reopen the same path (will block in open() until next writer).
                // We use asyncAfter so the queue is not blocked.
                JSONLogger.shared.log("notify.watcher.pipe.eof", data: ["path": config.path])
                tearDown()
                // Reopen after a brief delay to let the writer fully exit
                queue.asyncAfter(deadline: .now() + 0.5) {
                    if self.isRunning { self.openAndWatch() }
                }
            }
            // Regular file: EOF means we've read to the current end.
            // File rotation is handled by fsSource; nothing to do here.
        } else {
            // Read error (EAGAIN on non-blocking fd means no data ready -- ignore)
            if errno != EAGAIN && errno != EINTR {
                JSONLogger.shared.log("err.notify.watcher.read", data: ["errno": errno])
            }
        }
    }

    // MARK: - Internal: handle filesystem events (regular files only)

    // Called by fsSource when the watched file is written, deleted, or renamed.
    // On delete/rename (rotation): reopen the path to get the new file.
    private func handleFSEvent() {
        let events = fsSource?.data ?? 0
        let eventMask = DispatchSource.FileSystemEvent(rawValue: events)

        if eventMask.contains(.delete) || eventMask.contains(.rename) {
            // File was rotated: reopen from the new file at the same path
            JSONLogger.shared.log("notify.watcher.rotate", data: ["path": config.path])
            tearDown()
            queue.asyncAfter(deadline: .now() + 0.1) {
                if self.isRunning { self.openAndWatch() }
            }
        }
        // .write events are handled by readSource (data becomes available)
    }

    // MARK: - Internal: line processing

    // Extracts complete newline-delimited lines from lineBuffer and processes each.
    private func processLines() {
        // Split on newlines, keep last partial segment in buffer
        var lines = lineBuffer.components(separatedBy: "\n")
        // The last element is a partial line (or empty if buffer ends with \n)
        lineBuffer = lines.removeLast()
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty {
                processLine(trimmed)
            }
        }
    }

    // Parses a single line as a JSON notification descriptor.
    // Silent skip with log on parse failure.
    // Required field: "title". Optional: "body", "priority", "action".
    private func processLine(_ line: String) {
        guard let data = line.data(using: .utf8) else { return }

        do {
            let decoder = JSONDecoder()
            let desc = try decoder.decode(NotificationLineDescriptor.self, from: data)

            let action = parseLineAction(desc.action)

            let notification = GridNotification(
                source: config.sourceLabel,
                title: desc.title,
                body: desc.body ?? "",
                priority: GridNotificationPriority(rawValue: desc.priority ?? "normal") ?? .normal,
                action: action
            )

            // Add to store and refresh panel (must be async, hop to Task)
            let store = self.store
            Task {
                await store.add(notification)
                await MainActor.run {
                    if let vm = NotificationPanelManager.shared.currentViewModel {
                        vm.refreshNotifications()
                    }
                }
            }
        } catch {
            JSONLogger.shared.log("err.notify.watcher.parse", msg: "invalid line JSON", data: [
                "err": "\(error)"
            ])
        }
    }

    // Parses the optional action dictionary from the line descriptor.
    // Returns nil if no action or unrecognized type.
    private func parseLineAction(_ dict: [String: String]?) -> GridNotificationAction? {
        guard let dict = dict, let type = dict["type"] else { return nil }
        switch type {
        case "focusWindow":
            guard let wid = dict["windowID"].flatMap({ UInt32($0) }) else { return nil }
            return .focusWindow(windowID: wid)
        case "runShellCommand":
            guard let cmd = dict["command"] else { return nil }
            return .runShellCommand(command: cmd)
        case "openURL":
            guard let url = dict["url"] else { return nil }
            return .openURL(url: url)
        default:
            return nil
        }
    }

    // MARK: - Internal: teardown

    // Cancels all sources and closes the fd. Called on self.queue.
    private func tearDown() {
        readSource?.cancel()
        readSource = nil
        fsSource?.cancel()
        fsSource = nil
        if fd >= 0 {
            close(fd)
            fd = -1
        }
    }
}
