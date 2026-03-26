import SwiftUI
import AppKit

// MARK: - NotificationPanelMode

// Keyboard interaction mode for the notification panel.
// Normal: vim navigation. Filter: typing search text. VisualSelect: bulk operations.
enum NotificationPanelMode {
    case normal
    case filter
    case visualSelect
}

// MARK: - NotificationPanelAction

// Actions the view model can tell the window to perform after handling a key.
enum NotificationPanelAction {
    case none
    case executeAction(GridNotificationAction)
    case enterFilterMode
    case exitFilterMode
}

// MARK: - NotificationPanelViewModel

// Bridges NotificationStore (actor) to SwiftUI views. Holds all UI state
// (selection, mode, filter text, visual selection range) and dispatches
// vim key actions. SwiftUI views bind to @Published properties and render
// declaratively; the window's keyDown delegates to handleKeyDown.
@MainActor
class NotificationPanelViewModel: ObservableObject {

    // Published properties for SwiftUI binding
    @Published var notifications: [GridNotification] = []
    @Published var selectedIndex: Int = 0
    @Published var mode: NotificationPanelMode = .normal
    @Published var filterText: String = ""
    // Set when V is pressed to start visual selection
    @Published var visualSelectionStart: Int? = nil
    // Bottom status bar text (count summary, mode hints)
    @Published var statusText: String = ""

    // Theme (passed at init, can be replaced for hot-reload)
    var theme: NotificationPanelTheme

    // Reference to the store (actor, called with await)
    private let store: NotificationStore

    // Callback when notifications refresh (used by window to update title bar)
    var onRefresh: ((_ unreadCount: Int) -> Void)?

    // Tracks the in-flight refresh so concurrent calls can cancel the previous one
    private var refreshTask: Task<Void, Never>?

    init(store: NotificationStore, theme: NotificationPanelTheme = .default) {
        self.store = store
        self.theme = theme
    }

    // MARK: - Data Loading

    // Re-queries the store with the current filter and updates published state.
    // Called after every mutation and on panel show.
    func refreshNotifications() {
        refreshTask?.cancel()
        let filter = buildFilter()
        refreshTask = Task {
            let results = await store.notifications(filter: filter)
            guard !Task.isCancelled else { return }
            self.notifications = results
            self.selectedIndex = min(self.selectedIndex, max(0, results.count - 1))
            self.updateStatusText()
            let unread = results.filter { !$0.isRead }.count
            self.onRefresh?(unread)
        }
    }

    private func buildFilter() -> GridNotificationFilter {
        var filter = GridNotificationFilter.active
        if !filterText.isEmpty {
            filter.searchText = filterText
        }
        return filter
    }

    private func updateStatusText() {
        switch mode {
        case .normal:
            let total = notifications.count
            let pinnedCount = notifications.filter { $0.isPinned }.count
            var parts: [String] = ["\(total) notification\(total == 1 ? "" : "s")"]
            if pinnedCount > 0 {
                parts.append("\(pinnedCount) pinned")
            }
            if !filterText.isEmpty {
                parts.append("filter: \(filterText)")
            }
            statusText = parts.joined(separator: " | ")

        case .filter:
            statusText = "type to filter, Enter to apply, Esc to cancel"

        case .visualSelect:
            if let range = visualSelectedRange {
                let count = range.count
                statusText = "VISUAL: \(count) selected | d to dismiss, p to pin"
            } else {
                statusText = "VISUAL: move j/k to select range"
            }
        }
    }

    // MARK: - Navigation

    func selectNext() {
        guard !notifications.isEmpty else { return }
        selectedIndex = min(selectedIndex + 1, notifications.count - 1)
    }

    func selectPrevious() {
        guard !notifications.isEmpty else { return }
        selectedIndex = max(selectedIndex - 1, 0)
    }

    func selectFirst() {
        selectedIndex = 0
    }

    func selectLast() {
        guard !notifications.isEmpty else { return }
        selectedIndex = notifications.count - 1
    }

    // MARK: - Actions

    func dismissSelected() {
        guard let notification = currentNotification else { return }
        Task {
            await store.dismiss(id: notification.id)
            refreshNotifications()
        }
    }

    func togglePinSelected() {
        guard let notification = currentNotification else { return }
        if notification.isPinned {
            Task {
                await store.unpin(id: notification.id)
                refreshNotifications()
            }
        } else {
            Task {
                await store.pin(id: notification.id)
                refreshNotifications()
            }
        }
    }

    func increasePriority() {
        guard let notification = currentNotification else { return }
        let nextPriority = priorityAbove(notification.priority)
        if nextPriority != notification.priority {
            Task {
                await store.setPriority(id: notification.id, priority: nextPriority)
                refreshNotifications()
            }
        }
    }

    func decreasePriority() {
        guard let notification = currentNotification else { return }
        let nextPriority = priorityBelow(notification.priority)
        if nextPriority != notification.priority {
            Task {
                await store.setPriority(id: notification.id, priority: nextPriority)
                refreshNotifications()
            }
        }
    }

    func executeSelectedAction() -> NotificationPanelAction {
        guard let notification = currentNotification else { return .none }
        // Mark as read
        Task { await store.markRead(id: notification.id) }
        if let action = notification.action {
            return .executeAction(action)
        }
        return .none
    }

    var currentNotification: GridNotification? {
        guard selectedIndex >= 0, selectedIndex < notifications.count else { return nil }
        return notifications[selectedIndex]
    }

    // MARK: - Visual Select Mode

    func enterVisualSelect() {
        mode = .visualSelect
        visualSelectionStart = selectedIndex
        updateStatusText()
    }

    func exitVisualSelect() {
        mode = .normal
        visualSelectionStart = nil
        updateStatusText()
    }

    // The range of indices currently selected in visual mode.
    // Covers from the start anchor to the current selectedIndex.
    var visualSelectedRange: ClosedRange<Int>? {
        guard let start = visualSelectionStart else { return nil }
        let end = selectedIndex
        return min(start, end)...max(start, end)
    }

    func bulkDismissVisualSelection() {
        guard let range = visualSelectedRange else { return }
        let idsToDismiss = notifications[range].map { $0.id }
        Task {
            for id in idsToDismiss {
                await store.dismiss(id: id)
            }
            // Exit visual select mode before refresh so mode change and
            // subsequent UI update are sequenced atomically from the UI's perspective.
            exitVisualSelect()
            refreshNotifications()
        }
    }

    func bulkPinVisualSelection() {
        guard let range = visualSelectedRange else { return }
        let idsToPin = notifications[range].map { $0.id }
        Task {
            for id in idsToPin {
                await store.pin(id: id)
            }
            // Exit visual select mode before refresh so mode change and
            // subsequent UI update are sequenced atomically from the UI's perspective.
            exitVisualSelect()
            refreshNotifications()
        }
    }

    // MARK: - Filter Mode

    func enterFilterMode() {
        mode = .filter
        updateStatusText()
    }

    func exitFilterMode() {
        mode = .normal
        updateStatusText()
    }

    func updateFilter(_ text: String) {
        filterText = text
        refreshNotifications()
    }

    func clearFilter() {
        filterText = ""
        refreshNotifications()
    }

    // MARK: - Key Handling

    // Called by the NSWindow's keyDown. Returns an action for the window to execute.
    func handleKeyDown(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) -> NotificationPanelAction {
        let hasShift = modifiers.contains(.shift)

        switch mode {
        case .normal:
            switch keyCode {
            // j - select next
            case 38:
                selectNext()
                return .none
            // k - select previous
            case 40:
                selectPrevious()
                return .none
            // d - dismiss selected
            case 2:
                dismissSelected()
                return .none
            // x - dismiss selected
            case 7:
                dismissSelected()
                return .none
            // Return - execute action
            case 36:
                return executeSelectedAction()
            // / - enter filter mode
            case 44:
                enterFilterMode()
                return .enterFilterMode
            // p - toggle pin
            case 35:
                togglePinSelected()
                return .none
            // + (= key with shift) - increase priority
            // Bare = (without shift) is intentionally ignored: no binding defined for it.
            case 24:
                if hasShift {
                    increasePriority()
                }
                return .none
            // - (without shift) - decrease priority
            // shift+- produces _ (underscore) which is intentionally ignored: no binding defined for it.
            case 27:
                if !hasShift {
                    decreasePriority()
                }
                return .none
            // V (v key with shift) - enter visual select
            case 9:
                if hasShift {
                    enterVisualSelect()
                }
                return .none
            // g - selectFirst; G (shift+g) - selectLast
            case 5:
                if hasShift {
                    selectLast()
                } else {
                    selectFirst()
                }
                return .none
            // Escape - no-op in normal mode
            case 53:
                return .none
            default:
                return .none
            }

        case .filter:
            // Filter mode keys are handled by the SwiftUI text field.
            // Only Escape reaches the window (to exit filter mode).
            switch keyCode {
            // Escape - exit filter mode
            case 53:
                exitFilterMode()
                return .exitFilterMode
            default:
                return .none
            }

        case .visualSelect:
            switch keyCode {
            // j - extend selection down
            case 38:
                selectNext()
                updateStatusText()
                return .none
            // k - extend selection up
            case 40:
                selectPrevious()
                updateStatusText()
                return .none
            // d - bulk dismiss selection
            case 2:
                bulkDismissVisualSelection()
                return .none
            // p - bulk pin selection
            case 35:
                bulkPinVisualSelection()
                return .none
            // Escape - exit visual select
            case 53:
                exitVisualSelect()
                return .none
            default:
                return .none
            }
        }
    }

    // MARK: - Priority Helpers

    private func priorityAbove(_ p: GridNotificationPriority) -> GridNotificationPriority {
        switch p {
        case .low: return .normal
        case .normal: return .high
        case .high: return .urgent
        case .urgent: return .urgent
        }
    }

    private func priorityBelow(_ p: GridNotificationPriority) -> GridNotificationPriority {
        switch p {
        case .urgent: return .high
        case .high: return .normal
        case .normal: return .low
        case .low: return .low
        }
    }
}
