# Pseudocode: iMessage Notifications Phase 3 - Conversation Detail Pop-Out Window

## DW Coverage
- DW-3.1: Pressing Return on a notification with `detail_cmd` opens a pop-out detail window
- DW-3.2: iMessage detail window shows last 10 messages with sender direction and timestamps
- DW-3.3: Running `imessage-watch.py --history <handle>` returns JSON array of messages
- DW-3.4: Escape or closing the detail window dismisses it
- DW-3.5: Opening detail for a different notification replaces the current detail content

## File 1: Notification.swift - Add detailCmd field

```
// Add to GridNotification struct:
var detailCmd: String?

// Add to init parameter list:
detailCmd: String? = nil

// Add to init body:
self.detailCmd = detailCmd
```

## File 2: NotificationFileWatcher.swift - Parse detail_cmd from pipe JSON

```
// Add to NotificationLineDescriptor:
let detail_cmd: String?

// In processLine, pass to GridNotification init:
detailCmd: desc.detail_cmd
```

## File 3: NotificationPanelViewModel.swift - Return key checks detailCmd

```
// Add new case to NotificationPanelAction:
case openDetail(command: String, title: String)

// Modify executeSelectedAction():
func executeSelectedAction() -> NotificationPanelAction:
    guard notification = currentNotification else return .none
    // Mark as read
    Task { await store.markRead(id: notification.id) }
    // Check detailCmd first -- takes priority over action
    if let detailCmd = notification.detailCmd:
        return .openDetail(command: detailCmd, title: notification.title)
    // Fall through to existing action behavior
    if let action = notification.action:
        return .executeAction(action)
    return .none
```

## File 4: NotificationPanelWindow.swift - Route openDetail action

```
// In keyDown switch on action:
case .openDetail(let command, let title):
    DetailWindowController.shared.openDetail(command: command, title: title, theme: viewModel.theme)

// No changes to executeNotificationAction -- that stays for the other action types
```

## File 5: DetailWindowController.swift - Singleton detail window manager

```
// @MainActor class, singleton
// Owns one NSWindow instance, reuses it across openDetail calls

@MainActor
class DetailWindowController:
    static let shared = DetailWindowController()

    private var window: NSWindow?
    private var viewModel: DetailViewModel?

    // Opens (or re-focuses) the detail window with a new command
    // DW-3.1: pressing Return opens detail window
    // DW-3.5: opening for different notification replaces content
    func openDetail(command: String, title: String, theme: NotificationPanelTheme):
        // If window exists, update content (DW-3.5)
        if let existing viewModel:
            viewModel.loadDetail(command: command, title: title)
            window?.makeKeyAndOrderFront(nil)
            return

        // Create new view model
        let vm = DetailViewModel(theme: theme)
        self.viewModel = vm

        // Create NSWindow
        let window = NSWindow(...)
            contentRect: positioned near notification panel (400x500)
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView]
            backing: .buffered
            defer: false

        // Configure window appearance (match notification panel style)
        window.titleVisibility = .visible
        window.titlebarAppearsTransparent = true
        window.backgroundColor = theme.windowBackgroundNSColor
        window.hasShadow = true
        window.isReleasedWhenClosed = false
        window.title = title

        // Set up SwiftUI content via NSHostingView
        let hostingView = NSHostingView(rootView: DetailContentView(viewModel: vm))
        window.contentView = hostingView

        // Handle window close (DW-3.4)
        window.delegate = self  // implement NSWindowDelegate

        self.window = window
        window.makeKeyAndOrderFront(nil)

        // Start loading
        vm.loadDetail(command: command, title: title)

    // DW-3.4: Escape key dismisses
    // Override keyDown on the window to catch Escape
    // Actually: use a custom NSWindow subclass (DetailWindow) that overrides keyDown

    func dismissDetail():
        window?.orderOut(nil)
        viewModel = nil
        // Don't destroy window, just hide it
        jlog("notify.detail.dismiss")

    // NSWindowDelegate: windowWillClose
    func windowWillClose(_):
        viewModel = nil
        jlog("notify.detail.close")
```

## File 6: DetailViewModel.swift - Async command execution + state

```
@MainActor
class DetailViewModel: ObservableObject:

    enum DetailState:
        case idle
        case loading
        case loaded(messages: [DetailMessage])
        case error(message: String)

    @Published var state: DetailState = .idle
    @Published var title: String = ""

    let theme: NotificationPanelTheme

    // Track in-flight task so we can cancel on re-load (DW-3.5)
    private var loadTask: Task<Void, Never>?

    init(theme: NotificationPanelTheme):
        self.theme = theme

    // Run the detail command and parse output
    // DW-3.5: cancels previous load if still running
    func loadDetail(command: String, title: String):
        self.title = title
        loadTask?.cancel()
        state = .loading

        loadTask = Task:
            do:
                let output = try await runShellCommand(command)
                guard !Task.isCancelled else return
                let messages = try parseDetailOutput(output)
                state = .loaded(messages: messages)
                jlog("notify.detail.loaded", data: ["count": messages.count, "title": title])
            catch:
                guard !Task.isCancelled else return
                state = .error(message: error.localizedDescription)
                jlog("err.notify.detail.load", data: ["err": "\(error)", "cmd": command])

    // Run shell command asynchronously, return stdout as String
    private func runShellCommand(_ command: String) async throws -> String:
        // Use Process on a background thread
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global().async:
                let process = Process()
                let pipe = Pipe()
                let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
                process.executableURL = URL(fileURLWithPath: shell)
                process.arguments = ["-c", command]
                process.standardOutput = pipe
                process.standardError = FileHandle.nullDevice

                do:
                    try process.run()
                    process.waitUntilExit()

                    let data = pipe.fileHandleForReading.readDataToEndOfFile()
                    guard let output = String(data: data, encoding: .utf8) else:
                        throw DetailError.invalidOutput

                    if process.terminationStatus != 0:
                        throw DetailError.commandFailed(status: process.terminationStatus)

                    continuation.resume(returning: output)
                catch:
                    continuation.resume(throwing: error)
        }

    // Parse JSON array output from detail command
    // Expected format: [{"body": "...", "is_from_me": true, "timestamp": 1234567890}]
    private func parseDetailOutput(_ output: String) throws -> [DetailMessage]:
        guard let data = output.data(using: .utf8) else:
            throw DetailError.invalidOutput

        let decoder = JSONDecoder()
        let rawMessages = try decoder.decode([RawDetailMessage].self, from: data)

        let now = Date()
        return rawMessages.map { raw in
            DetailMessage(
                body: raw.body,
                isFromMe: raw.is_from_me,
                relativeTime: formatRelativeTime(unix: raw.timestamp, now: now)
            )
        }

// Supporting types:
struct RawDetailMessage: Codable:
    let body: String
    let is_from_me: Bool
    let timestamp: Int

struct DetailMessage: Identifiable:
    let id = UUID()
    let body: String
    let isFromMe: Bool
    let relativeTime: String

enum DetailError: Error:
    case invalidOutput
    case commandFailed(status: Int32)

// Relative time formatter:
func formatRelativeTime(unix: Int, now: Date) -> String:
    let messageDate = Date(timeIntervalSince1970: TimeInterval(unix))
    let interval = now.timeIntervalSince(messageDate)
    if interval < 60: return "now"
    if interval < 3600: return "\(Int(interval / 60))m ago"
    if interval < 86400: return "\(Int(interval / 3600))h ago"
    return "\(Int(interval / 86400))d ago"
```

## File 7: DetailViews.swift - SwiftUI views for detail content

```
// Spacing and type scale: reuse same values as NotificationPanelViews
private enum Space: xs=4, sm=6, md=8, lg=12, xl=16, xxl=24
private enum TypeSize: title=20, body=16, meta=12

// berkeleyMono font helper (same pattern as other view files)

// MARK: - DetailContentView (top-level)
struct DetailContentView: View:
    @ObservedObject var viewModel: DetailViewModel

    var body:
        VStack(spacing: 0):
            // Title bar area
            DetailTitleBar(title: viewModel.title, theme: viewModel.theme)

            switch viewModel.state:
                case .idle:
                    Spacer()
                case .loading:
                    DetailLoadingView(theme: viewModel.theme)
                case .loaded(let messages):
                    DetailMessageList(messages: messages, theme: viewModel.theme)
                case .error(let message):
                    DetailErrorView(message: message, theme: viewModel.theme)
        .background(viewModel.theme.background)

// MARK: - DetailTitleBar
struct DetailTitleBar: View:
    let title: String
    let theme: NotificationPanelTheme

    var body:
        HStack:
            Text(title)
                .font(berkeleyMono(size: TypeSize.title, weight: .bold))
                .foregroundColor(theme.textPrimary)
            Spacer()
        .padding(.horizontal, Space.xl)
        .padding(.vertical, Space.lg)
        .background(theme.surface)

// MARK: - DetailMessageList
// DW-3.2: shows messages with sender direction and timestamps
struct DetailMessageList: View:
    let messages: [DetailMessage]
    let theme: NotificationPanelTheme

    var body:
        ScrollViewReader { proxy in
            ScrollView:
                LazyVStack(spacing: Space.md):
                    ForEach(messages) { msg in
                        DetailMessageBubble(message: msg, theme: theme)
                            .id(msg.id)
                    }
                .padding(Space.lg)
            // Scroll to bottom on appear (most recent message)
            .onAppear:
                if let last = messages.last:
                    proxy.scrollTo(last.id, anchor: .bottom)
        }

// MARK: - DetailMessageBubble
// DW-3.2: sender direction (me vs them) + relative timestamp
struct DetailMessageBubble: View:
    let message: DetailMessage
    let theme: NotificationPanelTheme

    var body:
        VStack(alignment: message.isFromMe ? .trailing : .leading, spacing: 2):
            // Sender indicator
            HStack(spacing: Space.xs):
                if message.isFromMe:
                    Spacer()
                Text(message.isFromMe ? "you" : "them")
                    .font(berkeleyMono(size: TypeSize.meta))
                    .foregroundColor(theme.textTertiary)
                Text(message.relativeTime)
                    .font(berkeleyMono(size: TypeSize.meta))
                    .foregroundColor(theme.textTertiary)
                if !message.isFromMe:
                    Spacer()

            // Message body
            Text(message.body)
                .font(berkeleyMono(size: TypeSize.body))
                .foregroundColor(message.isFromMe ? theme.textSecondary : theme.textPrimary)
                .padding(.horizontal, Space.lg)
                .padding(.vertical, Space.md)
                .background(
                    message.isFromMe ? theme.surface : theme.surfaceSelected
                )
                .cornerRadius(Space.md)
        .frame(maxWidth: .infinity, alignment: message.isFromMe ? .trailing : .leading)

// MARK: - DetailLoadingView
struct DetailLoadingView: View:
    let theme: NotificationPanelTheme

    var body:
        VStack:
            Text("Loading...")
                .font(berkeleyMono(size: TypeSize.body))
                .foregroundColor(theme.textTertiary)
        .frame(maxWidth: .infinity, maxHeight: .infinity)

// MARK: - DetailErrorView
struct DetailErrorView: View:
    let message: String
    let theme: NotificationPanelTheme

    var body:
        VStack(spacing: Space.md):
            Text("Error loading detail")
                .font(berkeleyMono(size: TypeSize.body, weight: .bold))
                .foregroundColor(theme.urgent)
            Text(message)
                .font(berkeleyMono(size: TypeSize.meta))
                .foregroundColor(theme.textSecondary)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(Space.xxl)
```

## File 8: DetailWindow.swift - NSWindow subclass for Escape key handling

```
// DW-3.4: Escape dismisses the detail window
class DetailWindow: NSWindow:

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override func keyDown(with event: NSEvent):
        // Escape key (keyCode 53) dismisses the window
        if event.keyCode == 53:
            DetailWindowController.shared.dismissDetail()
            return
        super.keyDown(with: event)

    // Also close on Cmd+W
    override func cancelOperation(_ sender: Any?):
        DetailWindowController.shared.dismissDetail()
```

## File 9: imessage-watch.py - Add detail_cmd to notification format

```
// In format_notification():
// Add detail_cmd field pointing to the script with --history flag
// Use os.path.abspath(__file__) for the script path

def format_notification(msg, config):
    handle = msg["handle_id"]
    script_path = os.path.abspath(__file__)
    notification = {
        "id": f"imsg-{handle}",
        "title": handle,
        "body": msg["body"],
        "ttl": config["ttl"],
        "warn_before": config["warn_before"],
        "detail_cmd": f"python3 {script_path} --history {handle}",
    }
    return json.dumps(notification, ensure_ascii=False)
```

## Implementation Order

1. Notification.swift - add detailCmd field
2. NotificationFileWatcher.swift - parse detail_cmd
3. imessage-watch.py - add detail_cmd to output
4. DetailViewModel.swift - async command execution + parsing (new file)
5. DetailViews.swift - SwiftUI views (new file)
6. DetailWindow.swift + DetailWindowController - NSWindow subclass + singleton manager (new file)
7. NotificationPanelViewModel.swift - add .openDetail action, modify Return key
8. NotificationPanelWindow.swift - handle .openDetail action
9. Build and verify
