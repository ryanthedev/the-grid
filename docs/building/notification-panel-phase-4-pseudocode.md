# Pseudocode: Phase 4 - Notification sources (events, file/pipe watcher)

## Files to Create/Modify

- CREATE `grid-server/Sources/GridServer/Notifications/NotificationSourceConfig.swift` -- config structs with hardcoded defaults (Phase 5 wires to YAML)
- CREATE `grid-server/Sources/GridServer/Notifications/NotificationEventHandler.swift` -- StateEventHandler that maps grid events to notifications
- CREATE `grid-server/Sources/GridServer/Notifications/NotificationFileWatcher.swift` -- reads lines from file or named pipe, creates notifications
- MODIFY `grid-server/Sources/GridServer/main.swift` -- instantiate and configure both sources

---

## Pseudocode

### NotificationSourceConfig.swift

```
// Minimal config structs for Phase 4.
// Phase 5 will parse these from the notifications: YAML section.
// Defined here as value types with sensible defaults so the sources work
// without any config file changes by the user.

struct EventNotificationRule
    // Human-readable title for the generated notification.
    // Supports one substitution token: {event} -> the event name (e.g. "ev.win.create")
    title: String
    // Optional body text. Supports same {event} token.
    body: String  (default: "")
    priority: GridNotificationPriority  (default: .normal)

struct NotificationEventConfig
    // Map from StateEvent logInfo name to a notification rule.
    // Key is the event's logInfo string, e.g. "ev.win.create", "ev.focus", "ev.app.launch"
    // Empty map means no event-driven notifications (opt-in, not opt-out).
    rules: [String: EventNotificationRule]  (default: [:])

struct NotificationWatcherConfig
    // Path to watch. May be a regular file or a named pipe (FIFO).
    // Empty string means watcher is disabled.
    path: String  (default: "")
    // Source label written into GridNotification.source for notifications from this watcher
    sourceLabel: String  (default: "pipe")

// No shared state, no singletons -- both are pure value types.
```

### NotificationEventHandler.swift

```
// StateEventHandler that maps configurable grid events to notifications.
// Registered with EventRouter; one instance handles all mapped event types.
// Deep module: callers provide a config, this hides all event-to-notification
// translation details.

class NotificationEventHandler: StateEventHandler
    private let store: NotificationStore
    private let config: NotificationEventConfig

    init(store: NotificationStore, config: NotificationEventConfig)
        self.store = store
        self.config = config
        // Register with EventRouter in a Task (matches FocusTracker pattern)
        Task
            await EventRouter.shared.register(self)
            log "notify.event.handler.init", data: ["rule_count": config.rules.count]

    // StateEventHandler protocol requirement
    func handle(_ event: StateEvent, context: EventContext) async throws
        // Get the logInfo name for this event to look it up in the rules map
        let (eventName, _) = event.logInfo

        // Guard: skip if no rule for this event type
        guard let rule = config.rules[eventName] else { return }

        // Build the title: substitute {event} token with the event name
        let title = rule.title.replacingOccurrences(of: "{event}", with: eventName)
        let body = rule.body.replacingOccurrences(of: "{event}", with: eventName)

        // Create and add the notification
        let notification = GridNotification(
            source: "event",
            title: title,
            body: body,
            priority: rule.priority
        )
        await store.add(notification)

        // Refresh the panel view model if the panel is visible
        // Must hop to MainActor because NotificationPanelManager is @MainActor
        await MainActor.run
            if let vm = NotificationPanelManager.shared.currentViewModel
                vm.refreshNotifications()

    // Called when this source is no longer needed (e.g., config reload)
    func stop() async
        await EventRouter.shared.unregister(self)
```

### NotificationFileWatcher.swift

```
// Reads line-delimited JSON from a file or named pipe, creating GridNotification
// objects for each valid line. Handles EOF (pipe writer disconnect) by reopening.
// Handles regular file rotation (via DispatchSource filesystem events).
//
// Input format per line: JSON object with optional fields:
//   { "title": "...", "body": "...", "priority": "normal", "action": {...} }
// The "title" field is required. Any line failing to parse is silently skipped
// with a log entry.
//
// Deep module: caller provides a path + config, this hides all fd management,
// EOF reopening, and line buffering.

class NotificationFileWatcher
    private let store: NotificationStore
    private let config: NotificationWatcherConfig

    // File descriptor currently being watched (nil = watcher stopped)
    private var fd: Int32 = -1
    // DispatchSource for read readability (data available)
    private var readSource: DispatchSource?
    // DispatchSource for file system events (file rotation/deletion)
    private var fsSource: DispatchSource?
    // Buffer for partial lines between reads
    private var lineBuffer: String = ""
    // Prevents double-start and ensures clean stop
    private var isRunning: Bool = false

    // Private serial queue to protect fd, readSource, fsSource, lineBuffer
    private let queue: DispatchQueue

    init(store: NotificationStore, config: NotificationWatcherConfig)
        self.store = store
        self.config = config
        self.queue = DispatchQueue(label: "com.thegrid.notify.filewatcher")

    // MARK: - Start / Stop

    // Starts the watcher. No-op if config.path is empty or already running.
    func start()
        guard !config.path.isEmpty else
            log "notify.watcher.skip", msg: "no path configured"
            return
        guard !isRunning else { return }
        isRunning = true
        log "notify.watcher.start", data: ["path": config.path]
        queue.async
            self.openAndWatch()

    // Stops the watcher and releases all file descriptors.
    func stop()
        queue.sync
            isRunning = false
            tearDown()
        log "notify.watcher.stop"

    // MARK: - Internal: open and wire sources

    // Opens the path and sets up DispatchSource(s).
    // For a regular file: one readSource (data available) + one fsSource (rotation/deletion).
    // For a named pipe (FIFO): one readSource only (pipes don't rotate).
    // Called on self.queue.
    private func openAndWatch()
        // Open non-blocking so we don't hang on an empty named pipe with no writer
        let openFlags = O_RDONLY | O_NONBLOCK
        let newFD = open(config.path, openFlags)
        guard newFD >= 0 else
            log "err.notify.watcher.open", data: ["path": config.path, "errno": errno]
            // Retry after 5 seconds to handle the case where the path doesn't exist yet
            queue.asyncAfter(deadline: .now() + 5)
                if self.isRunning { self.openAndWatch() }
            return

        fd = newFD

        // Determine if this is a FIFO (named pipe) or a regular file
        var statBuf = stat()
        fstat(fd, &statBuf)
        let isFIFO = (statBuf.st_mode & S_IFMT) == S_IFIFO

        // Set up read source to fire when data is available
        let rs = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        rs.setEventHandler
            self.handleReadable(isFIFO: isFIFO)
        rs.setCancelHandler
            // fd is closed in tearDown, not here, to avoid double-close
        rs.resume()
        readSource = rs

        // For regular files, also watch for rotation (delete/rename/write events)
        if !isFIFO
            let evtFlags: DispatchSource.FileSystemEvent = [.write, .delete, .rename]
            let fss = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: evtFlags, queue: queue)
            fss.setEventHandler
                self.handleFSEvent()
            fss.resume()
            fsSource = fss

        log "notify.watcher.opened", data: ["path": config.path, "fifo": isFIFO]

    // MARK: - Internal: handle readable data

    // Called by readSource when data is available (or EOF on pipe).
    // Reads all available bytes, accumulates into lineBuffer, processes complete lines.
    private func handleReadable(isFIFO: Bool)
        let bufSize = 4096
        var buf = [UInt8](repeating: 0, count: bufSize)
        let bytesRead = read(fd, &buf, bufSize)

        if bytesRead > 0
            // Append new bytes to the line buffer
            let chunk = String(bytes: buf.prefix(bytesRead), encoding: .utf8) ?? ""
            lineBuffer += chunk
            processLines()

        else if bytesRead == 0
            // EOF: writer closed the pipe (or end of regular file)
            // Flush any remaining partial line in the buffer
            if !lineBuffer.isEmpty
                processLine(lineBuffer)
                lineBuffer = ""

            if isFIFO
                // Named pipe: writer disconnected. Tear down current fd/source,
                // then reopen the same path (will block in open() until next writer).
                // We use a background Task so the queue is not blocked.
                log "notify.watcher.pipe.eof", data: ["path": config.path]
                tearDown()
                // Reopen after a brief delay to let the writer fully exit
                queue.asyncAfter(deadline: .now() + 0.5)
                    if self.isRunning { self.openAndWatch() }
            else
                // Regular file: EOF means we've read to the current end.
                // File rotation is handled by fsSource; nothing to do here.

        else
            // Read error (EAGAIN on non-blocking fd means no data ready -- ignore)
            if errno != EAGAIN && errno != EINTR
                log "err.notify.watcher.read", data: ["errno": errno]

    // MARK: - Internal: handle filesystem events (regular files only)

    // Called by fsSource when the watched file is written, deleted, or renamed.
    // On delete/rename (rotation): reopen the path to get the new file.
    private func handleFSEvent()
        let events = fsSource?.data ?? 0
        let eventMask = DispatchSource.FileSystemEvent(rawValue: events)

        if eventMask.contains(.delete) || eventMask.contains(.rename)
            // File was rotated: reopen from the new file at the same path
            log "notify.watcher.rotate", data: ["path": config.path]
            tearDown()
            queue.asyncAfter(deadline: .now() + 0.1)
                if self.isRunning { self.openAndWatch() }

        // .write events are handled by readSource (data becomes available)

    // MARK: - Internal: line processing

    // Extracts complete newline-delimited lines from lineBuffer and processes each.
    private func processLines()
        // Split on newlines, keep last partial segment in buffer
        var lines = lineBuffer.components(separatedBy: "\n")
        // The last element is a partial line (or empty if buffer ends with \n)
        lineBuffer = lines.removeLast()
        for line in lines
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty
                processLine(trimmed)

    // Parses a single line as a JSON notification descriptor.
    // Silent skip with log on parse failure.
    // Required field: "title". Optional: "body", "priority", "action".
    private func processLine(_ line: String)
        guard let data = line.data(using: .utf8) else { return }

        do
            let decoder = JSONDecoder()
            let desc = try decoder.decode(NotificationLineDescriptor.self, from: data)

            // Build action if provided
            let action = parseLineAction(desc.action)

            let notification = GridNotification(
                source: config.sourceLabel,
                title: desc.title,
                body: desc.body ?? "",
                priority: GridNotificationPriority(rawValue: desc.priority ?? "normal") ?? .normal,
                action: action
            )

            // Add to store and refresh panel (must be async, hop to Task)
            Task
                await store.add(notification)
                await MainActor.run
                    if let vm = NotificationPanelManager.shared.currentViewModel
                        vm.refreshNotifications()

        catch
            log "err.notify.watcher.parse", msg: "invalid line JSON", data: ["err": "\(error)"]

    // Parses the optional action dictionary from the line descriptor.
    // Returns nil if no action or unrecognized type.
    private func parseLineAction(_ dict: [String: String]?) -> GridNotificationAction?
        guard let dict = dict, let type = dict["type"] else { return nil }
        switch type
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

    // MARK: - Internal: teardown

    // Cancels all sources and closes the fd. Called on self.queue.
    private func tearDown()
        readSource?.cancel()
        readSource = nil
        fsSource?.cancel()
        fsSource = nil
        if fd >= 0
            close(fd)
            fd = -1
```

### Supporting type: NotificationLineDescriptor (private, in NotificationFileWatcher.swift)

```
// Codable struct for parsing a single notification line.
// Defined privately in NotificationFileWatcher.swift -- not part of public interface.

private struct NotificationLineDescriptor: Codable
    let title: String
    let body: String?
    let priority: String?
    // action is a flat string-to-string dict for simplicity:
    // { "type": "focusWindow", "windowID": "123" }
    // { "type": "runShellCommand", "command": "echo hi" }
    // { "type": "openURL", "url": "https://..." }
    let action: [String: String]?
```

### main.swift modifications

```
// After the NotificationStore.shared.load() Task block,
// add event handler and file watcher initialization:

// Instantiate notification event handler with empty config (no event notifications by default)
// Phase 5 will wire config from YAML
let notificationEventConfig = NotificationEventConfig()  // empty rules = opt-in, no events active
let notificationEventHandler = NotificationEventHandler(
    store: NotificationStore.shared,
    config: notificationEventConfig
)
// NotificationEventHandler self-registers with EventRouter in its init Task

// Instantiate notification file watcher with empty path (disabled by default)
// Phase 5 will wire the path from YAML
let notificationWatcherConfig = NotificationWatcherConfig()  // empty path = disabled
let notificationFileWatcher = NotificationFileWatcher(
    store: NotificationStore.shared,
    config: notificationWatcherConfig
)
notificationFileWatcher.start()  // no-op if path is empty

// Keep strong references: store in locals that are captured by the signal handler closure
// Add to the signal handler cleanup
signalSource.setEventHandler {
    // ...existing shutdown code...
    notificationFileWatcher.stop()
    // notificationEventHandler unregisters itself when deallocated (weak ref in EventRouter)
}
// Same for termSignalSource
```

---

## Design Notes

### Information hiding
`NotificationFileWatcher` hides: fd management, FIFO vs file detection, EOF/rotation handling, line buffering, JSON parsing. The caller only calls `start()` and `stop()` with a config. This is intentionally deep -- the complexity of POSIX fd management is hidden behind a two-method interface.

`NotificationEventHandler` hides: the `logInfo` event name lookup, token substitution, store interaction. The caller provides a rules map; everything else is internal.

### Why string event names in the rules map?
The `StateEvent.logInfo` property already produces a canonical string name for each event (e.g., `"ev.win.create"`). Using these strings as config keys means:
- Users can reference event names they already see in logs
- No separate "allowed event names" enum to maintain in sync with `StateEvent`
- Events not in the map are silently skipped (O(1) dict lookup)

### Named pipe reopening strategy
On EOF, the watcher tears down the current source and calls `openAndWatch()` after a 0.5s delay. The `open(path, O_RDONLY | O_NONBLOCK)` call on a named pipe with no writer returns `ENXIO` (no such device). The 5-second retry in the error path handles this -- the watcher polls until a writer opens the pipe. Once a writer appears, `open()` succeeds and the watcher proceeds normally.

Alternative considered: blocking `open()` on a background thread. Rejected because it ties up a thread indefinitely and makes cancellation harder. The retry loop is simpler and more cancellation-friendly.

### Source label in notifications
- RPC/CLI: `"rpc"` (set in Phase 3 MessageHandler)
- Event handler: `"event"` (hardcoded in `NotificationEventHandler`)
- File/pipe watcher: `config.sourceLabel` (defaults to `"pipe"`, configurable per watcher)
- These labels are already rendered by `NotificationItemView` as a text tag

### Phase 5 integration boundary
Phase 4 defines the Swift structs (`NotificationEventConfig`, `NotificationWatcherConfig`) with hardcoded defaults. Phase 5 adds a `notifications:` YAML section to `GridConfig` and replaces the hardcoded defaults. The instances in `main.swift` are replaced with config-driven initialization. The `NotificationEventHandler` and `NotificationFileWatcher` classes need no changes.

### No unit tests for Phase 4
The plan says "Backend only" testing. Phase 4 sources are I/O-bound (EventRouter subscription, file/pipe reading) -- unit testing would require mocking the EventRouter and the filesystem. Manual verification is sufficient:
- Create a named pipe: `mkfifo /tmp/test-notify.pipe`
- Configure `notificationWatcherConfig` with that path in main.swift for testing
- Write a JSON line: `echo '{"title":"test"}' > /tmp/test-notify.pipe`
- Verify notification appears in the panel

---

## PRE-GATE Status

- [x] Discovery complete
- [x] Named pipe assumption verified (BUILD with implementation note)
- [x] Design reviewed (aposd-designing-deep-modules: two alternatives considered per component)
- [x] Pseudocode complete
- [ ] Ready for implementation
