import SwiftUI

// MARK: - Main Content View

// Root SwiftUI view for the notification panel. Composed of header, optional
// filter bar, scrollable notification list (or empty state), and status bar.
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
                .font(berkeleyMono(size: 15, weight: .bold))
                .foregroundColor(viewModel.theme.textPrimary)

            Spacer()

            // Unread count badge
            if unreadCount > 0 {
                Text("\(unreadCount)")
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundColor(viewModel.theme.background)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(viewModel.theme.accent)
                    .clipShape(Capsule())
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
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
        HStack(spacing: 8) {
            Text("/")
                .font(.system(size: 14, design: .monospaced))
                .foregroundColor(viewModel.theme.accent)

            TextField("filter...", text: filterTextBinding)
                .textFieldStyle(.plain)
                .font(.system(size: 14, design: .monospaced))
                .foregroundColor(viewModel.theme.textPrimary)
                .onSubmit {
                    // Enter pressed: exit filter mode, keep filter applied
                    viewModel.exitFilterMode()
                }
                .onExitCommand {
                    // Escape pressed: exit filter mode, clear filter
                    viewModel.clearFilter()
                    viewModel.exitFilterMode()
                }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
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
                LazyVStack(spacing: 2) {
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
                // Scroll to keep selected item visible
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
        HStack(alignment: .top, spacing: 10) {
            // Priority indicator (left edge)
            priorityIndicator

            // Content
            VStack(alignment: .leading, spacing: 3) {
                // Title row
                HStack {
                    // Pin indicator
                    if notification.isPinned {
                        Text(pinSymbol)
                            .font(.system(size: 12))
                            .foregroundColor(theme.pinned)
                    }

                    Text(notification.title)
                        .font(berkeleyMono(size: 14))
                        .foregroundColor(notification.isRead ? theme.textSecondary : theme.textPrimary)
                        .lineLimit(1)

                    Spacer()

                    // Source tag
                    Text(notification.source)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(theme.textTertiary)
                }

                // Body (if present)
                if !notification.body.isEmpty {
                    Text(notification.body)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundColor(theme.textSecondary)
                        .lineLimit(2)
                }

                // Bottom row: timestamp + action indicator
                HStack {
                    Text(relativeTime(notification.timestamp))
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(theme.textTertiary)

                    if notification.action != nil {
                        Spacer()
                        Text("Enter")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(theme.accentDim)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .overlay(
                                RoundedRectangle(cornerRadius: 3)
                                    .stroke(theme.accentDim, lineWidth: 0.5)
                            )
                    }
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(backgroundColor)
        .cornerRadius(4)
    }

    // Background color based on selection state
    private var backgroundColor: Color {
        if isSelected {
            return theme.surfaceSelected
        }
        if isVisualSelected {
            return theme.surface.opacity(0.8)
        }
        return Color.clear
    }

    // Priority indicator: symbol with color on the left edge
    @ViewBuilder
    private var priorityIndicator: some View {
        let (color, symbol) = priorityVisuals(notification.priority)
        VStack {
            Text(symbol)
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(color)
        }
        .frame(width: 14)
    }

    private func priorityVisuals(_ priority: GridNotificationPriority) -> (Color, String) {
        switch priority {
        case .urgent: return (theme.urgent, "!")
        case .high:   return (theme.accent, "^")
        case .normal: return (.clear, " ")
        case .low:    return (theme.textTertiary, ".")
        }
    }

    // Simple text-based pin indicator
    private var pinSymbol: String {
        return "+"
    }

    // Relative time formatting
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
        VStack(spacing: 8) {
            Text("No notifications")
                .font(.system(size: 15, design: .monospaced))
                .foregroundColor(theme.textTertiary)
            Text("Notifications from CLI, events, and file watchers appear here")
                .font(.system(size: 12, design: .monospaced))
                .foregroundColor(theme.textTertiary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }
}

// MARK: - Status Bar

struct NotificationStatusBar: View {
    @ObservedObject var viewModel: NotificationPanelViewModel

    var body: some View {
        HStack {
            Text(viewModel.statusText)
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(viewModel.theme.textTertiary)
                .lineLimit(1)

            Spacer()

            // Mode indicator
            switch viewModel.mode {
            case .normal:
                Text("NORMAL")
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundColor(viewModel.theme.textTertiary)
            case .filter:
                Text("FILTER")
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundColor(viewModel.theme.accent)
            case .visualSelect:
                Text("VISUAL")
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundColor(viewModel.theme.pinned)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .background(viewModel.theme.surface)
    }
}

// MARK: - Font Helper

// Returns BerkeleyMono Nerd Font if available, otherwise system monospaced.
private func berkeleyMono(size: CGFloat, weight: Font.Weight = .regular) -> Font {
    // Try the custom font; fall back to system monospaced
    if NSFont(name: "BerkeleyMono Nerd Font", size: size) != nil {
        return .custom("BerkeleyMono Nerd Font", size: size).weight(weight)
    }
    return .system(size: size, weight: weight, design: .monospaced)
}
