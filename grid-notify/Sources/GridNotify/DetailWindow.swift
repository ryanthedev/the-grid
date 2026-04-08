import AppKit
import SwiftUI

// MARK: - DetailWindow

// NSWindow subclass for the detail pop-out window.
// Intercepts Escape key to dismiss (DW-3.4).
class DetailWindow: NSWindow {

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    // DW-3.4: Escape dismisses the detail window
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {
            DetailWindowController.shared.dismissDetail()
            return
        }
        super.keyDown(with: event)
    }

    override func cancelOperation(_ sender: Any?) {
        DetailWindowController.shared.dismissDetail()
    }
}

// MARK: - DetailWindowController

// Singleton manager for the detail pop-out window.
// Only one detail window is open at a time (DW-3.5).
// Opening detail for a different notification replaces the content.
@MainActor
class DetailWindowController: NSObject, NSWindowDelegate {

    static let shared = DetailWindowController()

    private var window: DetailWindow?
    private var viewModel: DetailViewModel?

    private override init() {
        super.init()
    }

    // DW-3.1: Opens a detail window for the given command.
    // DW-3.5: If already open, replaces content instead of creating a new window.
    func openDetail(command: String, title: String, theme: NotificationPanelTheme) {
        // If window and viewModel already exist, just update content
        if let vm = viewModel, let win = window {
            vm.loadDetail(command: command, title: title)
            win.title = title
            win.makeKeyAndOrderFront(nil)
            jlog("notify.detail.replace", data: ["title": title])
            return
        }

        // Create new view model
        let vm = DetailViewModel(theme: theme)
        self.viewModel = vm

        // Calculate window rect, offset from main screen center
        let width: CGFloat = 400
        let height: CGFloat = 500
        let contentRect: NSRect
        if let screen = NSScreen.main ?? NSScreen.screens.first {
            let origin = NSPoint(
                x: screen.frame.midX - width / 2 + 220,
                y: screen.frame.midY - height / 2
            )
            contentRect = NSRect(origin: origin, size: CGSize(width: width, height: height))
        } else {
            contentRect = NSRect(x: 0, y: 0, width: width, height: height)
        }

        // Create the window
        let win = DetailWindow(
            contentRect: contentRect,
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        // Configure appearance to match the notification panel
        win.titleVisibility = .visible
        win.titlebarAppearsTransparent = true
        win.backgroundColor = theme.windowBackgroundNSColor
        win.hasShadow = true
        win.isReleasedWhenClosed = false
        win.title = title
        win.delegate = self

        // Set up SwiftUI content
        let hostingView = NSHostingView(rootView: DetailContentView(viewModel: vm))
        hostingView.translatesAutoresizingMaskIntoConstraints = false
        win.contentView = hostingView

        self.window = win
        win.makeKeyAndOrderFront(nil)

        // Start loading
        vm.loadDetail(command: command, title: title)
        jlog("notify.detail.open", data: ["title": title])
    }

    // DW-3.4: Dismisses the detail window.
    func dismissDetail() {
        window?.orderOut(nil)
        viewModel = nil
        jlog("notify.detail.dismiss")
    }

    // MARK: - NSWindowDelegate

    // DW-3.4: Window close button dismisses
    func windowWillClose(_ notification: Notification) {
        viewModel = nil
        jlog("notify.detail.close")
    }
}
