import AppKit

// Singleton orchestrator for notification panel lifecycle.
// Follows PickerManager pattern: main-thread class, not actor.
// @MainActor ensures compile-time safety for UI operations and
// access to the @MainActor view model.
@MainActor
class NotificationPanelManager {

    static let shared = NotificationPanelManager()

    private var window: NotificationPanelWindow?
    private var viewModel: NotificationPanelViewModel?
    private(set) var isVisible = false

    // Theme stored for lazy window creation; can be replaced for hot-reload.
    private var storedTheme: NotificationPanelTheme = .default

    private init() {}

    // MARK: - Configuration

    // Configure with theme. Call after server startup; can be called again
    // to hot-reload theme colors.
    func configure(theme: NotificationPanelTheme = .default) {
        dispatchPrecondition(condition: .onQueue(.main))
        storedTheme = theme
        // If view model exists, update its theme
        if let vm = viewModel {
            vm.theme = theme
        }
    }

    // MARK: - Show / Hide / Toggle

    func show() {
        dispatchPrecondition(condition: .onQueue(.main))

        if isVisible {
            return
        }

        // Create window lazily
        if window == nil {
            let vm = NotificationPanelViewModel(
                store: NotificationStore.shared,
                theme: storedTheme
            )
            viewModel = vm
            window = NotificationPanelWindow(viewModel: vm)
        }

        // Refresh notifications before showing
        viewModel?.refreshNotifications()

        // Switch to .regular so macOS treats our window like any 3rd-party app window.
        // This makes AX, focus, borders, picker, and tiling all work natively.
        NSApp.setActivationPolicy(.regular)
        // trackSelf after policy switch so StateManager discovers us before the
        // window becomes visible and the reconciler runs.
        Task { await StateManager.shared.trackSelf() }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        isVisible = true
        jlog("notify.panel.show")
    }

    func hide() {
        dispatchPrecondition(condition: .onQueue(.main))

        guard isVisible else { return }
        isVisible = false

        window?.orderOut(nil)
        // untrackSelf after window is hidden but before reverting policy,
        // so StateManager removes our windows cleanly.
        Task { await StateManager.shared.untrackSelf() }
        // Revert to .accessory so the server disappears from Cmd+Tab / Dock
        NSApp.setActivationPolicy(.accessory)
        jlog("notify.panel.hide")
    }

    func toggle() {
        dispatchPrecondition(condition: .onQueue(.main))
        if isVisible { hide() } else { show() }
    }

    // MARK: - Window Access

    // Expose view model for refresh from command handler
    var currentViewModel: NotificationPanelViewModel? {
        return viewModel
    }

    // Expose window number for identification
    var windowNumber: Int? {
        return window?.windowNumber
    }

    // Expose window for cell assignment
    var panelWindow: NSWindow? {
        return window
    }
}
