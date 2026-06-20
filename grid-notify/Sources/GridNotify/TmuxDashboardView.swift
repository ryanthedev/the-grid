import SwiftUI

// MARK: - Spacing Scale

// Matches NotificationPanelViews spacing for visual consistency.
private enum DashSpace {
    static let xs: CGFloat = 4
    static let sm: CGFloat = 6
    static let md: CGFloat = 8
    static let lg: CGFloat = 12
    static let xl: CGFloat = 16
    static let xxl: CGFloat = 24
}

// MARK: - Type Scale

private enum DashTypeSize {
    static let title: CGFloat = 20
    static let body: CGFloat = 16
    static let meta: CGFloat = 12
}

// MARK: - Font Helper

// BerkeleyMono Nerd Font with system monospaced fallback.
private func dashboardMono(size: CGFloat, weight: Font.Weight = .regular) -> Font {
    if NSFont(name: "BerkeleyMono Nerd Font", size: size) != nil {
        return .custom("BerkeleyMono Nerd Font", size: size).weight(weight)
    }
    return .system(size: size, weight: weight, design: .monospaced)
}

// MARK: - TmuxDashboardContentView

// Top-level SwiftUI view for the tmux dashboard window.
// Switches between zero-state and the session list.
struct TmuxDashboardContentView: View {
    @ObservedObject var viewModel: TmuxDashboardViewModel

    var body: some View {
        VStack(spacing: 0) {
            TmuxDashboardHeaderView(viewModel: viewModel)

            if viewModel.sessions.isEmpty {
                TmuxDashboardEmptyView(theme: viewModel.theme)
            } else {
                TmuxDashboardSessionListView(viewModel: viewModel)
            }

            TmuxDashboardStatusBar(viewModel: viewModel)
        }
        .background(viewModel.theme.background)
    }
}

// MARK: - TmuxDashboardHeaderView

// Title bar with a Refresh button.
struct TmuxDashboardHeaderView: View {
    @ObservedObject var viewModel: TmuxDashboardViewModel

    var body: some View {
        HStack {
            Text("Tmux Sessions")
                .font(dashboardMono(size: DashTypeSize.title, weight: .bold))
                .foregroundColor(viewModel.theme.textPrimary)

            Spacer()

            Button(action: { viewModel.requestRefresh() }) {
                Text("Refresh")
                    .font(dashboardMono(size: DashTypeSize.meta, weight: .medium))
                    .foregroundColor(viewModel.theme.accent)
                    .padding(.horizontal, DashSpace.md)
                    .padding(.vertical, DashSpace.xs)
                    .overlay(
                        RoundedRectangle(cornerRadius: DashSpace.xs)
                            .stroke(viewModel.theme.accent, lineWidth: 1)
                    )
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, DashSpace.xl)
        .padding(.vertical, DashSpace.lg)
        .background(viewModel.theme.surface)
    }
}

// MARK: - TmuxDashboardSessionListView

// Scrollable list of sessions with collapsible window rows.
// Sessions are ranked newest-activity-first by the viewModel; this view applies the
// notifications-panel double-flip trick so the newest session renders at the bottom and
// the list auto-scrolls there on every refresh.
struct TmuxDashboardSessionListView: View {
    @ObservedObject var viewModel: TmuxDashboardViewModel

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(viewModel.sessions, id: \.name) { session in
                        TmuxDashboardSessionRow(session: session, viewModel: viewModel)
                            .id(session.name)
                            // Flip each session block back upright.
                            .scaleEffect(x: 1, y: -1, anchor: .center)
                    }
                }
            }
            // Flip the whole list — sessions now grow from the bottom, so the newest
            // (first in the activity-sorted array) lands at the bottom.
            .scaleEffect(x: 1, y: -1, anchor: .center)
            // Snap to the newest session on every load (loadGeneration bumps each time);
            // generatedAt is AI-written and unreliable as a change signal.
            .onChange(of: viewModel.loadGeneration) { _ in
                guard let newest = viewModel.sessions.first else { return }
                withAnimation(.easeInOut(duration: 0.2)) {
                    // .top in flipped space is the bottom visually.
                    proxy.scrollTo(newest.name, anchor: .top)
                }
            }
        }
    }
}

// MARK: - TmuxDashboardSessionRow

// Single session header row with a disclosure triangle.
// Tapping toggles the session's collapsed state.
struct TmuxDashboardSessionRow: View {
    let session: TmuxSession
    @ObservedObject var viewModel: TmuxDashboardViewModel

    private var isCollapsed: Bool {
        viewModel.isCollapsed(session.name)
    }

    var body: some View {
        VStack(spacing: 0) {
            // Session header
            Button(action: { viewModel.toggleCollapsed(session.name) }) {
                HStack(spacing: DashSpace.sm) {
                    Image(systemName: isCollapsed ? "chevron.right" : "chevron.down")
                        .font(.system(size: DashTypeSize.meta, weight: .medium))
                        .foregroundColor(viewModel.theme.textTertiary)
                        .frame(width: DashSpace.xl)

                    Text(session.name)
                        .font(dashboardMono(size: DashTypeSize.body, weight: .bold))
                        .foregroundColor(viewModel.theme.textPrimary)

                    if session.attached {
                        Text("attached")
                            .font(dashboardMono(size: DashTypeSize.meta))
                            .foregroundColor(viewModel.theme.background)
                            .padding(.horizontal, DashSpace.sm)
                            .padding(.vertical, 2)
                            .background(viewModel.theme.accent)
                            .clipShape(Capsule())
                    }

                    Spacer()

                    Text("\(session.windows.count)w")
                        .font(dashboardMono(size: DashTypeSize.meta))
                        .foregroundColor(viewModel.theme.textTertiary)
                }
                .padding(.horizontal, DashSpace.xl)
                .padding(.vertical, DashSpace.md)
                .background(viewModel.theme.surface)
            }
            .buttonStyle(.plain)

            Divider()
                .background(viewModel.theme.border)

            // Window rows (shown when not collapsed)
            if !isCollapsed {
                ForEach(session.windows, id: \.index) { window in
                    TmuxDashboardWindowRow(
                        window: window,
                        sessionName: session.name,
                        viewModel: viewModel
                    )
                }
            }
        }
    }
}

// MARK: - TmuxDashboardWindowRow

// Single window row showing the statusKind glyph + name + summary.
// Clicking selects the row; the window's keyDown handles Enter-to-detail.
struct TmuxDashboardWindowRow: View {
    let window: TmuxWindow
    let sessionName: String
    @ObservedObject var viewModel: TmuxDashboardViewModel

    private var isSelected: Bool {
        viewModel.selectedWindow?.sessionName == sessionName
            && viewModel.selectedWindow?.windowIndex == window.index
    }

    // Display summary: fall back to the command name if summary is empty.
    private var displaySummary: String {
        let trimmed = window.summary.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return window.command }
        // Cap at maxSummaryLength to defend against over-long AI output.
        let capped = String(trimmed.prefix(TmuxWindow.maxSummaryLength))
        return capped
    }

    var body: some View {
        Button(action: {
            viewModel.selectWindow(sessionName: sessionName, windowIndex: window.index)
        }) {
            HStack(alignment: .top, spacing: DashSpace.md) {
                // StatusKind glyph
                Text(window.statusKind.glyph)
                    .font(dashboardMono(size: DashTypeSize.body, weight: .bold))
                    .foregroundColor(Color(window.statusKind.color))
                    .frame(width: DashSpace.xl)

                VStack(alignment: .leading, spacing: DashSpace.xs) {
                    // Window name + index
                    HStack(spacing: DashSpace.xs) {
                        Text("\(window.index): \(window.name)")
                            .font(dashboardMono(size: DashTypeSize.body, weight: .medium))
                            .foregroundColor(isSelected ? viewModel.theme.textPrimary : viewModel.theme.textSecondary)
                            .lineLimit(1)

                        if window.active {
                            Text("*")
                                .font(dashboardMono(size: DashTypeSize.meta, weight: .bold))
                                .foregroundColor(viewModel.theme.accent)
                        }

                        Spacer()
                    }

                    // AI summary
                    Text(displaySummary)
                        .font(dashboardMono(size: DashTypeSize.meta))
                        .foregroundColor(viewModel.theme.textTertiary)
                        .lineLimit(2)
                }
            }
            .padding(.leading, DashSpace.xxl)
            .padding(.trailing, DashSpace.lg)
            .padding(.vertical, DashSpace.md)
            .background(isSelected ? viewModel.theme.surfaceSelected : Color.clear)
        }
        .buttonStyle(.plain)

        Divider()
            .background(viewModel.theme.border)
            .padding(.leading, DashSpace.xxl)
    }
}

// MARK: - TmuxDashboardEmptyView

// Zero-state shown when there are no tmux sessions.
struct TmuxDashboardEmptyView: View {
    let theme: NotificationPanelTheme

    var body: some View {
        VStack(spacing: DashSpace.md) {
            Text("No tmux sessions")
                .font(dashboardMono(size: DashTypeSize.title))
                .foregroundColor(theme.textTertiary)
            Text("Start a tmux session, then refresh")
                .font(dashboardMono(size: DashTypeSize.body))
                .foregroundColor(theme.textTertiary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(DashSpace.xxl)
    }
}

// MARK: - TmuxDashboardStatusBar

// Bottom status bar showing session/window counts and last update time.
struct TmuxDashboardStatusBar: View {
    @ObservedObject var viewModel: TmuxDashboardViewModel

    var body: some View {
        HStack {
            Text(viewModel.statusText)
                .font(dashboardMono(size: DashTypeSize.meta))
                .foregroundColor(viewModel.theme.textTertiary)
                .lineLimit(1)

            Spacer()
        }
        .padding(.horizontal, DashSpace.xl)
        .padding(.vertical, DashSpace.sm)
        .background(viewModel.theme.surface)
    }
}
