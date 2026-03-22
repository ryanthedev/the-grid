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
    private var isVisible = false

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
        isVisible = true

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

        // Activate and show
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        jlog("notify.panel.show")
    }

    func hide() {
        dispatchPrecondition(condition: .onQueue(.main))

        guard isVisible else { return }
        isVisible = false

        window?.orderOut(nil)
        jlog("notify.panel.hide")
    }

    func toggle() {
        dispatchPrecondition(condition: .onQueue(.main))
        if isVisible { hide() } else { show() }
    }

    // MARK: - Window Access

    // Expose window number for Phase 3 blacklisting
    var windowNumber: Int? {
        return window?.windowNumber
    }

    // Expose window for Phase 3 cell assignment
    var panelWindow: NSWindow? {
        return window
    }
}
