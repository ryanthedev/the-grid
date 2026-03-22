import SwiftUI

// MARK: - Spacing Scale

// Base unit 4px, ×1.5 progression: 4, 6, 8, 12, 16, 24
private enum Space {
    static let xs: CGFloat = 4
    static let sm: CGFloat = 6
    static let md: CGFloat = 8
    static let lg: CGFloat = 12
    static let xl: CGFloat = 16
    static let xxl: CGFloat = 24
}

// MARK: - Type Scale

// 3:4 ratio (×0.75): 16, 13, 10. Three tiers, clear jumps.
private enum TypeSize {
    static let title: CGFloat = 16
    static let body: CGFloat = 13
    static let meta: CGFloat = 10
}

// MARK: - Main Content View

struct NotificationPanelContentView: View {
    @ObservedObject var viewModel: NotificationPanelViewModel

    var body: some View {
        VStack(spacing: 0) {
            NotificationHeaderView(viewModel: viewModel)

            if viewModel.mode == .filter {
                NotificationFilterBar(viewModel: viewModel)
            }

            if viewModel.notifications.isEmpty {
                NotificationEmptyView(theme: viewModel.theme)
            } else {
                NotificationListView(viewModel: viewModel)
            }

            NotificationStatusBar(viewModel: viewModel)
        }
        .background(viewModel.theme.background)
        .onAppear {
            viewModel.refreshNotifications()
        }
    }
}

// MARK: - Header View

struct NotificationHeaderView: View {
    @ObservedObject var viewModel: NotificationPanelViewModel

    var body: some View {
        HStack {
            Text("Notifications")
                .font(berkeleyMono(size: TypeSize.title, weight: .bold))
                .foregroundColor(viewModel.theme.textPrimary)

            Spacer()

            if unreadCount > 0 {
                Text("\(unreadCount)")
                    .font(berkeleyMono(size: TypeSize.meta, weight: .bold))
                    .foregroundColor(viewModel.theme.background)
                    .padding(.horizontal, Space.sm)
                    .padding(.vertical, 2)
                    .background(viewModel.theme.accent)
                    .clipShape(Capsule())
            }
        }
        .padding(.horizontal, Space.xl)
        .padding(.vertical, Space.lg)
        .background(viewModel.theme.surface)
    }

    private var unreadCount: Int {
        viewModel.notifications.filter { !$0.isRead }.count
    }
}

// MARK: - Filter Bar

struct NotificationFilterBar: View {
    @ObservedObject var viewModel: NotificationPanelViewModel

    var body: some View {
        HStack(spacing: Space.md) {
            Text("/")
                .font(berkeleyMono(size: TypeSize.body))
                .foregroundColor(viewModel.theme.accent)

            TextField("filter...", text: filterTextBinding)
                .textFieldStyle(.plain)
                .font(berkeleyMono(size: TypeSize.body))
                .foregroundColor(viewModel.theme.textPrimary)
                .onSubmit {
                    viewModel.exitFilterMode()
                }
                .onExitCommand {
                    viewModel.clearFilter()
                    viewModel.exitFilterMode()
                }
        }
        .padding(.horizontal, Space.xl)
        .padding(.vertical, Space.md)
        .background(viewModel.theme.filterBackground)
    }

    private var filterTextBinding: Binding<String> {
        Binding(
            get: { viewModel.filterText },
            set: { viewModel.updateFilter($0) }
        )
    }
}

// MARK: - Notification List

struct NotificationListView: View {
    @ObservedObject var viewModel: NotificationPanelViewModel

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(
                        Array(viewModel.notifications.enumerated()),
                        id: \.element.id
                    ) { index, notification in
                        NotificationItemView(
                            notification: notification,
                            isSelected: index == viewModel.selectedIndex,
                            isVisualSelected: viewModel.visualSelectedRange?.contains(index) ?? false,
                            theme: viewModel.theme
                        )
                        .id(notification.id)
                    }
                }
            }
            .onChange(of: viewModel.selectedIndex) { _ in
                if let notification = viewModel.currentNotification {
                    withAnimation(.easeInOut(duration: 0.1)) {
                        proxy.scrollTo(notification.id, anchor: .center)
                    }
                }
            }
        }
    }
}

// MARK: - Single Notification Item

struct NotificationItemView: View {
    let notification: GridNotification
    let isSelected: Bool
    let isVisualSelected: Bool
    let theme: NotificationPanelTheme

    var body: some View {
        HStack(alignment: .top, spacing: Space.md) {
            // Priority: 2px left-edge bar (full item height) + symbol
            priorityEdge

            VStack(alignment: .leading, spacing: Space.xs) {
                // Title row
                HStack(spacing: Space.xs) {
                    if notification.isPinned {
                        Text("+")
                            .font(berkeleyMono(size: TypeSize.body, weight: .bold))
                            .foregroundColor(theme.pinned)
                    }

                    Text(notification.title)
                        .font(berkeleyMono(size: TypeSize.body))
                        .foregroundColor(notification.isRead ? theme.textSecondary : theme.textPrimary)
                        .lineLimit(1)

                    Spacer()

                    Text(notification.source)
                        .font(berkeleyMono(size: TypeSize.meta))
                        .foregroundColor(theme.textTertiary)
                }

                if !notification.body.isEmpty {
                    Text(notification.body)
                        .font(berkeleyMono(size: TypeSize.body))
                        .foregroundColor(theme.textSecondary)
                        .lineLimit(2)
                }

                // Metadata row
                HStack {
                    Text(relativeTime(notification.timestamp))
                        .font(berkeleyMono(size: TypeSize.meta))
                        .foregroundColor(theme.textTertiary)

                    if notification.action != nil {
                        Spacer()
                        // Simple text hint, no border ornamentation
                        Text("→")
                            .font(berkeleyMono(size: TypeSize.meta))
                            .foregroundColor(theme.accentDim)
                    }
                }
            }
        }
        .padding(.leading, 0)
        .padding(.trailing, Space.lg)
        .padding(.vertical, Space.md)
        .background(backgroundColor)
    }

    private var backgroundColor: Color {
        if isSelected {
            return theme.surfaceSelected
        }
        if isVisualSelected {
            return theme.surface
        }
        return Color.clear
    }

    // Left-edge colored bar: 2px wide, full item height.
    // Creates compositional dominance for urgent items without adding noise to normal ones.
    @ViewBuilder
    private var priorityEdge: some View {
        let (color, symbol) = priorityVisuals(notification.priority)
        VStack(spacing: 2) {
            Text(symbol)
                .font(berkeleyMono(size: TypeSize.meta, weight: .bold))
                .foregroundColor(color)
        }
        .frame(width: Space.xl)
        .frame(maxHeight: .infinity, alignment: .top)
        .overlay(alignment: .leading) {
            // Colored left bar — visible for urgent/high, invisible for normal/low
            Rectangle()
                .fill(color)
                .frame(width: 2)
                .opacity(notification.priority >= .high ? 1.0 : 0.0)
        }
    }

    private func priorityVisuals(_ priority: GridNotificationPriority) -> (Color, String) {
        switch priority {
        case .urgent: return (theme.urgent, "!")
        case .high:   return (theme.accent, "^")
        case .normal: return (.clear, " ")
        case .low:    return (theme.textTertiary, "·")
        }
    }

    private func relativeTime(_ date: Date) -> String {
        let interval = Date().timeIntervalSince(date)
        if interval < 60 { return "now" }
        if interval < 3600 { return "\(Int(interval / 60))m" }
        if interval < 86400 { return "\(Int(interval / 3600))h" }
        return "\(Int(interval / 86400))d"
    }
}

// MARK: - Empty State

struct NotificationEmptyView: View {
    let theme: NotificationPanelTheme

    var body: some View {
        VStack(spacing: Space.md) {
            Text("No notifications")
                .font(berkeleyMono(size: TypeSize.title))
                .foregroundColor(theme.textTertiary)
            Text("Notifications from CLI, events, and file watchers appear here")
                .font(berkeleyMono(size: TypeSize.body))
                .foregroundColor(theme.textTertiary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(Space.xxl)
    }
}

// MARK: - Status Bar

struct NotificationStatusBar: View {
    @ObservedObject var viewModel: NotificationPanelViewModel

    var body: some View {
        HStack {
            Text(viewModel.statusText)
                .font(berkeleyMono(size: TypeSize.meta))
                .foregroundColor(viewModel.theme.textTertiary)
                .lineLimit(1)

            Spacer()

            // Mode indicator — accent color only when mode is active
            switch viewModel.mode {
            case .normal:
                Text("NORMAL")
                    .font(berkeleyMono(size: TypeSize.meta, weight: .medium))
                    .foregroundColor(viewModel.theme.textTertiary)
            case .filter:
                Text("FILTER")
                    .font(berkeleyMono(size: TypeSize.meta, weight: .medium))
                    .foregroundColor(viewModel.theme.accent)
            case .visualSelect:
                Text("VISUAL")
                    .font(berkeleyMono(size: TypeSize.meta, weight: .medium))
                    .foregroundColor(viewModel.theme.accent)
            }
        }
        .padding(.horizontal, Space.xl)
        .padding(.vertical, Space.sm)
        .background(viewModel.theme.surface)
    }
}

// MARK: - Font Helper

// BerkeleyMono Nerd Font with system monospaced fallback.
// Used for ALL text in the panel — no mixing.
private func berkeleyMono(size: CGFloat, weight: Font.Weight = .regular) -> Font {
    if NSFont(name: "BerkeleyMono Nerd Font", size: size) != nil {
        return .custom("BerkeleyMono Nerd Font", size: size).weight(weight)
    }
    return .system(size: size, weight: weight, design: .monospaced)
}
