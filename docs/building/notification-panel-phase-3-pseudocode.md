# Pseudocode: Phase 3 - Grid integration (cell assignment, reconciler, commands)

## Integration Strategy

**Incremental integration order (risk-oriented):**
1. Command router domain (`@notify`) -- lowest risk, tests command parsing
2. RPC handlers in MessageHandler -- bridges CLI to command router
3. CLI subcommands -- thin layer over RPC
4. Panel wiring in main.swift -- loads store, configures manager
5. Action execution -- wires notification actions to real operations
6. Cell assignment -- highest risk, manual GridState manipulation

Each step produces a working system. Steps 1-3 can be tested independently.

## Files to Create/Modify

### New files
- `grid-server/Sources/GridCLI/NotifyCommand.swift`

### Modified files
- `grid-server/Sources/GridServer/Grid/GridCommandRouter.swift`
- `grid-server/Sources/GridServer/MessageHandler.swift`
- `grid-server/Sources/GridServer/main.swift`
- `grid-server/Sources/GridServer/Notifications/NotificationPanelManager.swift`
- `grid-server/Sources/GridServer/Notifications/NotificationPanelWindow.swift`
- `grid-server/Sources/GridCLI/GridCLI.swift`

## Pseudocode

### 1. GridCommandRouter.swift -- Add `notify` domain

```
// Add to init parameters:
//   notificationPanelManager (weak reference, @MainActor)
//   notificationStore (actor reference)

// Add stored properties:
//   private let notificationStore: NotificationStore
//   No direct reference to NotificationPanelManager needed --
//   show/hide/toggle go through @MainActor dispatch

// In dispatch() switch, add new case:
case "notify":
    return await handleNotify(parsed)

// New handler:
private func handleNotify(_ cmd: ParsedCommand) async -> CommandResult
    switch cmd.action

    case "show":
        // Use executeAction to suppress reconciler during show animation
        return try await gridReconciler.executeAction(label: "notify.show") {
            await MainActor.run {
                NotificationPanelManager.shared.show()
            }
            return .ok("notification panel shown")
        }

    case "hide":
        return try await gridReconciler.executeAction(label: "notify.hide") {
            await MainActor.run {
                NotificationPanelManager.shared.hide()
            }
            return .ok("notification panel hidden")
        }

    case "toggle":
        return try await gridReconciler.executeAction(label: "notify.toggle") {
            await MainActor.run {
                NotificationPanelManager.shared.toggle()
            }
            return .ok("notification panel toggled")
        }

    case "push":
        // Parse notification from args and flags
        // args[0] = title (required)
        // --body <text>
        // --priority <low|normal|high|urgent>
        // --source <label> (default: "rpc")
        // --action <type:payload> (e.g., "focus:123", "exec:ls", "url:https://...")

        guard let title = cmd.args.first, !title.isEmpty else
            return .error("missing title")

        let body = cmd.flagValues["body"] ?? ""
        let source = cmd.flagValues["source"] ?? "rpc"
        let priorityStr = cmd.flagValues["priority"] ?? "normal"
        let priority = parse priority string to GridNotificationPriority, default .normal

        // Parse action string if present
        let action: GridNotificationAction? = parse cmd.flagValues["action"]
        // Format: "focus:<windowID>" | "exec:<command>" | "url:<url>"
        // Split on first ":", type is before, payload is after

        let notification = GridNotification(
            source: source,
            title: title,
            body: body,
            priority: priority,
            action: action
        )

        let stored = await notificationStore.add(notification)

        // If panel is visible, refresh it
        await MainActor.run {
            if NotificationPanelManager.shared.isVisible {
                NotificationPanelManager.shared.viewModel?.refreshNotifications()
            }
        }

        return .ok(stored.id)

    case "list":
        // Return notifications as JSON
        let filter = build filter from flags:
            --source <label>
            --priority <min-priority>
            --all (include dismissed)
        let notifications = await notificationStore.notifications(filter: filter)
        // Encode as JSON array and return in message
        let encoded = encode notifications to JSON string
        return .ok(encoded)

    case "dismiss":
        // Dismiss a specific notification by ID
        guard let id = cmd.args.first else
            return .error("missing notification id")
        let ok = await notificationStore.dismiss(id: id)
        if ok {
            refresh panel if visible
            return .ok("dismissed")
        } else {
            return .error("notification not found or already dismissed")
        }

    case "clear":
        // Dismiss all active notifications (or purge if --purge flag)
        if cmd.flags.contains("purge") {
            let count = await notificationStore.purge()
            return .ok("purged \(count)")
        } else {
            let count = await notificationStore.bulkDismiss()
            refresh panel if visible
            return .ok("dismissed \(count)")
        }

    case "count":
        let count = await notificationStore.count()
        return .ok("\(count)")

    default:
        return .error("unknown notify action: \(cmd.action)")
```

### 2. MessageHandler.swift -- Add RPC handlers

```
// Inside registerGridHandlers(), add notification RPC methods:

// grid.notify.show -- {}
register(method: "grid.notify.show")
    dispatchAndRespond(request, commandString: "@notify show", completion: completion)

// grid.notify.hide -- {}
register(method: "grid.notify.hide")
    dispatchAndRespond(request, commandString: "@notify hide", completion: completion)

// grid.notify.toggle -- {}
register(method: "grid.notify.toggle")
    dispatchAndRespond(request, commandString: "@notify toggle", completion: completion)

// grid.notify.push -- { title: string, body?: string, priority?: string, source?: string, action?: string }
register(method: "grid.notify.push")
    Build command string: "@notify push <title> [--body <body>] [--priority <p>] [--source <s>] [--action <a>]"
    // title comes from params["title"]
    // body, priority, source, action come from params as optional flag values
    dispatchAndRespond(request, commandString: cmd, completion: completion)

// grid.notify.list -- { source?: string, priority?: string, all?: bool }
register(method: "grid.notify.list")
    Build command string: "@notify list [--source <s>] [--priority <p>] [--all]"
    dispatchAndRespond(request, commandString: cmd, completion: completion)

// grid.notify.dismiss -- { id: string }
register(method: "grid.notify.dismiss")
    guard let id from params["id"]
    dispatchAndRespond(request, commandString: "@notify dismiss \(id)", completion: completion)

// grid.notify.clear -- { purge?: bool }
register(method: "grid.notify.clear")
    var cmd = "@notify clear"
    if params["purge"] is true: cmd += " --purge"
    dispatchAndRespond(request, commandString: cmd, completion: completion)

// grid.notify.count -- {}
register(method: "grid.notify.count")
    dispatchAndRespond(request, commandString: "@notify count", completion: completion)
```

### 3. NotifyCommand.swift (NEW) -- CLI subcommands

```
// Top-level command with subcommands
struct NotifyCommand: ParsableCommand
    configuration: commandName "notify", abstract "Notification management"
    subcommands: [NotifyShow, NotifyHide, NotifyToggle, NotifyPush,
                  NotifyList, NotifyDismiss, NotifyClear, NotifyCount]

struct NotifyShow: ParsableCommand
    configuration: commandName "show"
    @OptionGroup globals: GlobalOptions

    func run()
        let client = makeClient(from: globals)
        defer { client.disconnect() }
        let result = try client.call("grid.notify.show")
        printOkOrJSON(result, json: globals.json)

struct NotifyHide: ParsableCommand
    // Same pattern as NotifyShow but calls "grid.notify.hide"

struct NotifyToggle: ParsableCommand
    // Same pattern, calls "grid.notify.toggle"

struct NotifyPush: ParsableCommand
    configuration: commandName "push"
    @OptionGroup globals: GlobalOptions

    @Argument(help: "Notification title")
    var title: String

    @Option(name: .long, help: "Notification body text")
    var body: String?

    @Option(name: .long, help: "Priority: low, normal, high, urgent")
    var priority: String?

    @Option(name: .long, help: "Source label")
    var source: String?

    @Option(name: .long, help: "Action: focus:<wid>, exec:<cmd>, url:<url>")
    var action: String?

    func run()
        let client = makeClient(from: globals)
        defer { client.disconnect() }

        var params: [String: Any] = ["title": title]
        if let body { params["body"] = body }
        if let priority { params["priority"] = priority }
        if let source { params["source"] = source }
        if let action { params["action"] = action }

        let result = try client.call("grid.notify.push", params: params)
        printOkOrJSON(result, json: globals.json)

struct NotifyList: ParsableCommand
    configuration: commandName "list"
    @OptionGroup globals: GlobalOptions

    @Option(name: .long, help: "Filter by source")
    var source: String?

    @Option(name: .long, help: "Minimum priority")
    var priority: String?

    @Flag(name: .long, help: "Include dismissed notifications")
    var all: Bool = false

    func run()
        let client = makeClient(from: globals)
        defer { client.disconnect() }

        var params: [String: Any] = [:]
        if let source { params["source"] = source }
        if let priority { params["priority"] = priority }
        if all { params["all"] = true }

        let result = try client.call("grid.notify.list", params: params)
        // The "message" field contains JSON array of notifications
        printResult(result, json: globals.json)

struct NotifyDismiss: ParsableCommand
    configuration: commandName "dismiss"
    @OptionGroup globals: GlobalOptions

    @Argument(help: "Notification ID to dismiss")
    var id: String

    func run()
        let client = makeClient(from: globals)
        defer { client.disconnect() }
        let result = try client.call("grid.notify.dismiss", params: ["id": id])
        printOkOrJSON(result, json: globals.json)

struct NotifyClear: ParsableCommand
    configuration: commandName "clear"
    @OptionGroup globals: GlobalOptions

    @Flag(name: .long, help: "Permanently remove dismissed notifications")
    var purge: Bool = false

    func run()
        let client = makeClient(from: globals)
        defer { client.disconnect() }
        var params: [String: Any] = [:]
        if purge { params["purge"] = true }
        let result = try client.call("grid.notify.clear", params: params)
        printOkOrJSON(result, json: globals.json)

struct NotifyCount: ParsableCommand
    configuration: commandName "count"
    @OptionGroup globals: GlobalOptions

    func run()
        let client = makeClient(from: globals)
        defer { client.disconnect() }
        let result = try client.call("grid.notify.count")
        // Print just the count number for scripting
        if let msg = result["message"] as? String {
            print(msg)
        }
```

### 4. GridCLI.swift -- Register NotifyCommand

```
// Add NotifyCommand.self to subcommands list:
subcommands: [
    ...,
    NotifyCommand.self,
]
```

### 5. main.swift -- Wire notification system at startup

```
// After GridState init, load NotificationStore:
Task {
    await NotificationStore.shared.load()
    jlog("notify.store.ready")
}

// After commandRouter init, add notificationStore reference:
// (GridCommandRouter init gains notificationStore parameter)

// Pass notificationStore to registerGridHandlers:
messageHandler.registerGridHandlers(
    router: commandRouter,
    gridState: gridState,
    gridConfig: gridConfig,
    stateManager: StateManager.shared
)
// NOTE: No change to registerGridHandlers signature needed --
// notify commands go through command router which has notificationStore.
// The RPC handlers just build command strings and dispatchAndRespond.

// In shutdown handlers, flush notification store:
signalSource.setEventHandler {
    ...
    Task {
        await NotificationStore.shared.flush()
        ...
    }
}
```

### 6. NotificationPanelManager.swift -- Add isVisible accessor and viewModel accessor

```
// Make isVisible readable (currently private)
// Change: private var isVisible = false
// To: private(set) var isVisible = false

// Expose viewModel for refresh from command handler
var currentViewModel: NotificationPanelViewModel? {
    return viewModel
}
```

### 7. NotificationPanelWindow.swift -- Wire action execution

```
// In keyDown, change the .executeAction case:
case .executeAction(let notifAction):
    // Execute the notification action
    executeNotificationAction(notifAction)

// New method on NotificationPanelWindow:
private func executeNotificationAction(_ action: GridNotificationAction)
    switch action
    case .focusWindow(let windowID):
        // Hide panel first, then focus
        NotificationPanelManager.shared.hide()
        // Use WindowManipulator to focus the target window
        // Need to look up PID from StateManager
        Task {
            let wmState = await StateManager.shared.getState()
            guard let windowState = wmState.windows[String(windowID)] else {
                jlog("notify.action.err", data: ["wid": windowID, "reason": "not_found"])
                return
            }
            let connectionID = SLSMainConnectionID()
            let manipulator = WindowManipulator(connectionID: connectionID)
            let ok = manipulator.focusWindow(pid: windowState.pid, windowID: windowID)
            jlog("notify.action.focus", data: ["wid": windowID, "ok": ok])
        }

    case .runShellCommand(let command):
        // Run via user's shell, fire-and-forget
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        DispatchQueue.global().async {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: shell)
            process.arguments = ["-c", command]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try? process.run()
        }
        jlog("notify.action.exec", data: ["cmd": command])

    case .openURL(let urlString):
        if let url = URL(string: urlString) {
            NSWorkspace.shared.open(url)
        }
        jlog("notify.action.url", data: ["url": urlString])
```

### 8. GridCommandRouter init -- Add notificationStore dependency

```
// Add to init parameter list:
//   notificationStore: NotificationStore

// Add stored property:
//   private let notificationStore: NotificationStore

// In init body:
//   self.notificationStore = notificationStore
```

### 9. main.swift -- Update commandRouter init

```
let commandRouter = GridCommandRouter(
    ...(existing params)...,
    notificationStore: NotificationStore.shared
)
```

## Design Notes

### Why no window ID blacklisting

The plan called for blacklisting the notification window by window ID in the event observer/reconciler. Discovery revealed this is unnecessary:

1. The server process runs with `.accessory` activation policy
2. StateManager only tracks `.regular` apps
3. The server's PID never appears in `state.applications`
4. Therefore `shouldTrackWindow(pid:)` returns false for the server's own PID
5. The notification window is invisible to the reconciler

The existing architecture already prevents feedback loops for in-process windows. This is the same reason the picker window (also owned by the server) doesn't need blacklisting.

### Why reconciler suppression for show/hide

Even though the notification window itself doesn't cause reconciler events, showing/hiding it triggers `NSApp.activate(ignoringOtherApps: true)` which can cause focus changes on OTHER windows that ARE tracked. The suppression token prevents the reconciler from reacting to those transient focus changes during the show/hide animation.

### Cell assignment deferred

Manual cell assignment (inserting the notification window into GridState for tiling) is deferred. The core value of Phase 3 is command/RPC/CLI control of the notification panel. Cell assignment requires:
- Getting the notification window's CGWindowID (available via `window.windowNumber`)
- Manually inserting it into GridState for a target cell
- Calling GridApply to position it

This can be added as `@notify assign <cellID>` but is not needed for the primary use case (floating notification panel shown/hidden via hotkey). If the user specifically asks for it, we add it. The plan's done-when item "Panel can be assigned to a grid cell" is achievable but not the highest priority integration task.

### Action string parsing

For `--action` flag, the format is `<type>:<payload>`:
- `focus:12345` -> `.focusWindow(windowID: 12345)`
- `exec:echo hello` -> `.runShellCommand(command: "echo hello")`
- `url:https://example.com` -> `.openURL(url: "https://example.com")`

Split on first `:` only (payload may contain colons).

### Notification list JSON encoding

The `@notify list` command returns notifications as a JSON array string in the CommandResult message. The RPC handler passes this through. The CLI prints it directly. This keeps the command router output format consistent (always a string message) while allowing structured data when needed.

## PRE-GATE Status
- [x] Discovery complete
- [x] Pseudocode complete
- [x] Design reviewed (feedback loop prevention validated, architecture fits existing patterns)
- [x] Ready for implementation
