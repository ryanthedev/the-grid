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

    // Monotonic counter bumped on every load(). The view watches this (not generatedAt)
    // to auto-scroll to the newest session — generatedAt is AI-written and may repeat or
    // stall, so it is not a reliable "new data arrived" signal.
    @Published var loadGeneration: Int = 0

    // Sessions currently collapsed (showing only the session header, not windows).
    @Published var collapsedSessions: Set<String> = []

    // Currently selected window for Enter-to-detail. (session name, window index)
    @Published var selectedWindow: (sessionName: String, windowIndex: Int)? = nil

    // Theme used by the dashboard window and detail pop-out.
    let theme: NotificationPanelTheme

    // Called when the user taps the Refresh button.
    // The driver (P4) sets this to trigger an immediate run.
    var onRefreshRequested: (() -> Void)?

    // Invoked from load(_:) when one or more windows transition INTO .waiting on
    // a non-baseline load. AppDelegate wires this to post a GridNotification per
    // window. Injectable so emission is testable off the store/AppKit boundary.
    var onWaitingEntered: (([TmuxWindow]) -> Void)?

    // Targets that were .waiting on the previous load. The dedupe/re-arm anchor:
    // a target already here is not re-notified; a target that leaves drops out
    // and re-arms. Long-lived (window-bound viewModel) so it persists across loads.
    private var previousWaiting: Set<String> = []

    // Whether the first load has occurred. The first load seeds previousWaiting
    // without notifying (baseline), so a restart with already-waiting windows
    // does not dump a notification per window.
    private var didBaseline = false

    init(theme: NotificationPanelTheme = .default) {
        self.theme = theme
    }

    // MARK: - Data Loading

    // Load new status data and update all published state.
    // Called by the watcher's onChange callback (P5).
    // Sessions are ranked newest-activity-first; the view flips the list so the
    // most recently active session renders at the bottom (mirrors the notifications panel).
    // Stable sort: equal-activity sessions (including back-compat files where every
    // activity is 0) keep the skill's original emission order via the index tiebreaker.
    func load(_ data: TmuxStatusData) {
        sessions = data.sessions.enumerated()
            .sorted {
                $0.element.activity != $1.element.activity
                    ? $0.element.activity > $1.element.activity
                    : $0.offset < $1.offset
            }
            .map(\.element)
        generatedAt = Date(timeIntervalSince1970: TimeInterval(data.generatedAt))
        loadGeneration &+= 1
        jlog("tmux.dashboard.load", data: [
            "sessions": data.sessions.count,
            "generatedAt": data.generatedAt,
        ])

        detectWaitingTransitions(in: data)
    }

    // MARK: - Waiting transitions

    // Diff this load's waiting set against the prior one and surface windows that
    // newly entered .waiting. The very first load only seeds the baseline so a
    // restart with already-waiting windows does not spam; subsequent loads emit.
    // previousWaiting is always advanced to the current waiting set (so vanished
    // targets re-arm).
    private func detectWaitingTransitions(in data: TmuxStatusData) {
        let allWindows = data.sessions.flatMap(\.windows)
        let result = TmuxWaitingPolicy.diff(previousWaiting: previousWaiting, windows: allWindows)
        previousWaiting = result.waitingNow

        guard didBaseline else {
            didBaseline = true
            jlog("tmux.waiting.baseline", data: ["waiting": result.waitingNow.count])
            return
        }

        guard !result.newlyWaiting.isEmpty else { return }

        jlog("tmux.waiting.entered", data: ["count": result.newlyWaiting.count])
        onWaitingEntered?(result.newlyWaiting)
    }

    // Number of windows currently in .waiting across all loaded sessions.
    // Computed from @Published sessions so SwiftUI re-renders the Phase-2 badge
    // reactively when sessions changes; no separate @Published storage needed.
    var waitingCount: Int {
        sessions.reduce(0) { count, session in
            count + session.windows.filter { $0.statusKind == .waiting }.count
        }
    }

    // Build the notification for a window that entered .waiting. Pure/static so
    // DW-1.5 can assert title/body/detailCmd without crossing the actor boundary.
    // A fresh id per call keeps each waiting episode distinct, so NotificationStore.add
    // (idempotent by id) never silently drops a re-entry post.
    static func makeWaitingNotification(for window: TmuxWindow) -> GridNotification {
        GridNotification(
            id: "tmux-waiting-\(window.target)-\(UUID().uuidString)",
            source: "tmux",
            title: "\(window.target) needs input",
            body: window.summary,
            detailCmd: "tmux capture-pane -pt \(window.target) -S -200"
        )
    }

    // MARK: - Dashboard indicator (Phase 2)

    // Header badge label for the "needs input" count. Pure/static so DW-2.1 can
    // assert the label and the 0-case without touching SwiftUI. Returns nil when
    // there is nothing waiting, which the view uses to hide the badge entirely.
    static func badgeText(waitingCount: Int) -> String? {
        guard waitingCount > 0 else { return nil }
        return "\(waitingCount) need input"
    }

    // Row-highlight decision for a window. Pure/static so DW-2.2 can assert the
    // predicate over a mix of waiting and non-waiting windows. The view uses this
    // to apply the yellow tint + left accent bar.
    static func isWaitingHighlight(_ window: TmuxWindow) -> Bool {
        window.statusKind == .waiting
    }

    // Relative last-activity age for a window row. Pure/static and now-injected so
    // DW-2.2 can assert every bucket deterministically.
    //
    // activity is external input (AI-written status file); the decode barricade
    // normalizes a missing field to the sentinel 0, and 0 means "unknown" → nil so
    // the row shows no age rather than a bogus epoch-derived span.
    //
    // A negative diff (writer clock ahead of reader — anticipated runtime skew, not a
    // programmer bug, so it is handled, not asserted) collapses into the "now" bucket.
    static func relativeAge(activity: Int, now: Date) -> String? {
        guard activity != 0 else { return nil }
        let seconds = Int(now.timeIntervalSince1970) - activity
        switch seconds {
        case ..<60: return "now"
        case ..<3600: return "\(seconds / 60)m"
        case ..<86400: return "\(seconds / 3600)h"
        default: return "\(seconds / 86400)d"
        }
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
