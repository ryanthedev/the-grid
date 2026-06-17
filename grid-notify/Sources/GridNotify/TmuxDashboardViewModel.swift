import AppKit
import Foundation

// MARK: - TmuxDashboardViewModel

// Bridges TmuxStatusData to SwiftUI views for the tmux dashboard.
// Holds presentation state: sessions list, generatedAt timestamp,
// and per-session collapsed state. The Refresh button calls onRefreshRequested;
// the driver (P4) handles the actual refresh. Mirrors NotificationPanelViewModel.
@MainActor
class TmuxDashboardViewModel: ObservableObject {

    // Published list of sessions from the last loaded status data.
    @Published var sessions: [TmuxSession] = []

    // Timestamp of the last loaded status file. Nil until first load.
    @Published var generatedAt: Date? = nil

    // Sessions currently collapsed (showing only the session header, not windows).
    @Published var collapsedSessions: Set<String> = []

    // Currently selected window for Enter-to-detail. (session name, window index)
    @Published var selectedWindow: (sessionName: String, windowIndex: Int)? = nil

    // Theme used by the dashboard window and detail pop-out.
    let theme: NotificationPanelTheme

    // Called when the user taps the Refresh button.
    // The driver (P4) sets this to trigger an immediate run.
    var onRefreshRequested: (() -> Void)?

    init(theme: NotificationPanelTheme = .default) {
        self.theme = theme
    }

    // MARK: - Data Loading

    // Load new status data and update all published state.
    // Called by the watcher's onChange callback (P5).
    func load(_ data: TmuxStatusData) {
        sessions = data.sessions
        generatedAt = Date(timeIntervalSince1970: TimeInterval(data.generatedAt))
        jlog("tmux.dashboard.load", data: [
            "sessions": data.sessions.count,
            "generatedAt": data.generatedAt,
        ])
    }

    // MARK: - Collapse / Expand

    // Toggle the collapsed state of a session by name.
    func toggleCollapsed(_ sessionName: String) {
        if collapsedSessions.contains(sessionName) {
            collapsedSessions.remove(sessionName)
        } else {
            collapsedSessions.insert(sessionName)
        }
    }

    func isCollapsed(_ sessionName: String) -> Bool {
        collapsedSessions.contains(sessionName)
    }

    // MARK: - Refresh

    // Called by the Refresh button. Delegates to the driver via the callback.
    func requestRefresh() {
        onRefreshRequested?()
        jlog("tmux.dashboard.refresh.requested")
    }

    // MARK: - Detail

    // Build the tmux capture-pane command for a window's active pane.
    // Pure function — no I/O, fully unit-testable.
    func openDetailCommand(for window: TmuxWindow) -> String {
        "tmux capture-pane -pt \(window.target) -S -200 ; tmux save-buffer -"
    }

    // Select a window row (for keyboard navigation from the window's keyDown).
    func selectWindow(sessionName: String, windowIndex: Int) {
        selectedWindow = (sessionName: sessionName, windowIndex: windowIndex)
    }

    // Return the TmuxWindow for the currently selected row, if any.
    var currentWindow: TmuxWindow? {
        guard let sel = selectedWindow else { return nil }
        return sessions.first(where: { $0.name == sel.sessionName })?
            .windows.first(where: { $0.index == sel.windowIndex })
    }

    // Summary text for the status bar at the bottom of the window.
    var statusText: String {
        guard !sessions.isEmpty else { return "no tmux sessions" }
        let windowCount = sessions.reduce(0) { $0 + $1.windows.count }
        if let date = generatedAt {
            let formatter = RelativeDateTimeFormatter()
            formatter.unitsStyle = .abbreviated
            let rel = formatter.localizedString(for: date, relativeTo: Date())
            return "\(sessions.count) sessions · \(windowCount) windows · updated \(rel)"
        }
        return "\(sessions.count) sessions · \(windowCount) windows"
    }
}
