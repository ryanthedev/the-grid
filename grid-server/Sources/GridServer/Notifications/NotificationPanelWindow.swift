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

        // Calculate initial window rect, centered on main screen
        let screen = NSScreen.main ?? NSScreen.screens.first!
        let width: CGFloat = 400
        let height: CGFloat = 600
        let origin = NSPoint(
            x: screen.frame.midX - width / 2,
            y: screen.frame.midY - height / 2
        )

        super.init(
            contentRect: NSRect(origin: origin, size: CGSize(width: width, height: height)),
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
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        isOpaque = false
        backgroundColor = viewModel.theme.windowBackgroundNSColor
        hasShadow = true
        // Window title used for identification (Phase 3 blacklisting)
        title = "Grid Notifications"
        // Reuse across show/hide cycles
        isReleasedWhenClosed = false
    }

    private func setupContent() {
        let swiftUIView = NotificationPanelContentView(viewModel: viewModel)
        let hosting = NSHostingView(rootView: swiftUIView)
        hosting.translatesAutoresizingMaskIntoConstraints = false
        contentView = hosting
        hostingView = hosting
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
            // Phase 2: log the action; Phase 3 will wire to ActionExecutor
            jlog("notify.action", data: ["action": "\(notifAction)"])
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
}
