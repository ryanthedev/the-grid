import AppKit
import SwiftUI

// MARK: - TmuxDashboardWindow

// NSWindow subclass for the tmux dashboard. Uses .titled style mask so it
// appears in CGWindowListCopyWindowInfo for cell assignment. The title bar is
// transparent; full-size content view renders SwiftUI via NSHostingView.
// Mirrors NotificationPanelWindow exactly: isReleasedWhenClosed=false,
// setFrameAutosaveName, NSHostingView, keyDown interception.
class TmuxDashboardWindow: NSWindow {

    // The view model, shared with SwiftUI views.
    private let viewModel: TmuxDashboardViewModel

    // Hosting view wrapping the SwiftUI content.
    private var hostingView: NSHostingView<TmuxDashboardContentView>?

    init(viewModel: TmuxDashboardViewModel) {
        self.viewModel = viewModel

        // Calculate initial window rect, centered on main screen.
        // Fall back to a safe default if no screen is available (headless/test).
        let width: CGFloat = 500
        let height: CGFloat = 700
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
            // .titled + .closable so it appears in CGWindowListCopyWindowInfo
            // .fullSizeContentView draws over the entire frame including the hidden title bar
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        setupWindow()
        setupContent()
    }

    private func setupWindow() {
        titleVisibility = .visible
        titlebarAppearsTransparent = true
        isOpaque = false
        backgroundColor = viewModel.theme.windowBackgroundNSColor
        hasShadow = true
        title = "Tmux Sessions"
        // Reuse across show/hide cycles — mirrors NotificationPanelWindow
        isReleasedWhenClosed = false
        // Persist window frame across launches
        setFrameAutosaveName("TmuxDashboard")
    }

    private func setupContent() {
        let swiftUIView = TmuxDashboardContentView(viewModel: viewModel)
        let hosting = NSHostingView(rootView: swiftUIView)
        hosting.translatesAutoresizingMaskIntoConstraints = false
        contentView = hosting
        hostingView = hosting
    }

    // MARK: - Key Handling

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    // Intercept Return to open the detail pop-out for the selected window.
    // All other keys are forwarded to the responder chain (SwiftUI handles clicks).
    override func keyDown(with event: NSEvent) {
        // Return (keyCode 36) — open pane detail for selected window
        if event.keyCode == 36 {
            openDetailForSelectedWindow()
            return
        }
        super.keyDown(with: event)
    }

    // Open the detail pop-out for the currently selected window row.
    // Uses DetailWindowController.shared — the same singleton as notifications.
    private func openDetailForSelectedWindow() {
        guard let window = viewModel.currentWindow else {
            jlog("tmux.dashboard.detail.noselection")
            return
        }
        let command = viewModel.openDetailCommand(for: window)
        let title = "\(window.target) — \(window.name)"
        DetailWindowController.shared.openDetail(
            command: command,
            title: title,
            theme: viewModel.theme
        )
        jlog("tmux.dashboard.detail.open", data: [
            "target": window.target,
            "window": window.name,
        ])
    }
}
