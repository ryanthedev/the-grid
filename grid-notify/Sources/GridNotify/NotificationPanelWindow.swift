import AppKit
import SwiftUI

// NSWindow subclass for the notification panel. Uses .titled style mask
// so it appears in CGWindowListCopyWindowInfo for cell assignment. The
// title bar is hidden and the full-size content view renders SwiftUI
// content via NSHostingView. Vim keybindings are intercepted in keyDown
// before they reach SwiftUI, matching the PickerWindow/TestPanel pattern.
class NotificationPanelWindow: NSWindow {

    // The view model, shared with SwiftUI views
    private let viewModel: NotificationPanelViewModel

    // The hosting view wrapping SwiftUI content
    private var hostingView: NSHostingView<NotificationPanelContentView>?

    init(viewModel: NotificationPanelViewModel) {
        self.viewModel = viewModel

        // Calculate initial window rect, centered on main screen.
        // Fall back to a safe default rect if no screen is available (headless/test).
        let width: CGFloat = 400
        let height: CGFloat = 600
        let contentRect: NSRect
        if let screen = NSScreen.main ?? NSScreen.screens.first {
            let origin = NSPoint(
                x: screen.frame.midX - width / 2,
                y: screen.frame.midY - height / 2
            )
            contentRect = NSRect(origin: origin, size: CGSize(width: width, height: height))
        } else {
            contentRect = NSRect(x: 0, y: 0, width: width, height: height)
        }

        super.init(
            contentRect: contentRect,
            // .titled + .closable so it appears as a real window in CGWindowListCopyWindowInfo
            // .fullSizeContentView to draw over the entire frame including hidden title bar
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        setupWindow()
        setupContent()
    }

    private func setupWindow() {
        // Standard window (not floating, not transient)
        // Must appear in CGWindowListCopyWindowInfo for cell assignment
        titleVisibility = .visible
        titlebarAppearsTransparent = true
        isOpaque = false
        backgroundColor = viewModel.theme.windowBackgroundNSColor
        hasShadow = true
        title = "Notifications"
        // Reuse across show/hide cycles
        isReleasedWhenClosed = false
        // Persist window frame across launches
        setFrameAutosaveName("GridNotifyPanel")
    }

    func updateTitle(unreadCount: Int) {
        if unreadCount > 0 {
            title = "Notifications (\(unreadCount))"
        } else {
            title = "Notifications"
        }
    }

    private func setupContent() {
        let swiftUIView = NotificationPanelContentView(viewModel: viewModel)
        let hosting = NSHostingView(rootView: swiftUIView)
        hosting.translatesAutoresizingMaskIntoConstraints = false
        contentView = hosting
        hostingView = hosting

        viewModel.onRefresh = { [weak self] unreadCount in
            self?.updateTitle(unreadCount: unreadCount)
        }
    }

    // MARK: - Key Handling

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override func keyDown(with event: NSEvent) {
        // In filter mode, forward non-escape keys to the responder chain
        // so the SwiftUI TextField receives typed characters
        if viewModel.mode == .filter && event.keyCode != 53 {
            super.keyDown(with: event)
            return
        }

        let action = viewModel.handleKeyDown(
            keyCode: event.keyCode,
            modifiers: event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        )

        switch action {
        case .none:
            // Key was consumed by viewModel
            break
        case .executeAction(let notifAction):
            executeNotificationAction(notifAction)
        case .openDetail(let command, let title):
            DetailWindowController.shared.openDetail(
                command: command,
                title: title,
                theme: viewModel.theme
            )
        case .enterFilterMode:
            // Make the hosting view first responder so the TextField receives focus
            if let hosting = hostingView {
                makeFirstResponder(hosting)
            }
        case .exitFilterMode:
            // Return first responder to the window itself
            makeFirstResponder(nil)
        }
    }

    // MARK: - Action Execution

    // Executes the action carried by a notification.
    // In standalone mode, focusWindow is not available (requires grid-server).
    // runShellCommand and openURL work independently.
    private func executeNotificationAction(_ action: GridNotificationAction) {
        switch action {
        case .focusWindow(let windowID):
            // focusWindow requires grid-server's WindowManipulator and StateManager.
            // In standalone mode, log a warning and no-op.
            jlog("warn.notify.action.focus", msg: "focusWindow not available in standalone mode", data: ["wid": windowID])

        case .runShellCommand(let command):
            // Run via user's shell, fire-and-forget
            let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
            DispatchQueue.global().async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: shell)
                process.arguments = ["-c", command]
                process.standardOutput = FileHandle.nullDevice
                process.standardError = FileHandle.nullDevice
                do {
                    try process.run()
                    jlog("notify.action.exec", data: ["cmd": command])
                } catch {
                    jlog("err.notify.action.exec", data: ["cmd": command, "err": "\(error)"])
                }
            }

        case .openURL(let urlString):
            if let url = URL(string: urlString) {
                NSWorkspace.shared.open(url)
            }
            jlog("notify.action.url", data: ["url": urlString])
        }
    }
}
